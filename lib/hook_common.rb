# =============================================================================
# HookCommon - Code shared by the six hook scripts in hooks/
# =============================================================================
# Each hook script only adds this library to $LOAD_PATH and calls
# HookCommon.run with the code that maps its resource. This file does the rest:
# it reads the payload, loads the configuration, creates the logger, and
# catches every error, so that a hook never blocks an OpenNebula operation.
#
# Part of addon-confirmate-evidence (EMERALD project)
# =============================================================================

ONE_LOCATION = ENV['ONE_LOCATION'] unless defined?(ONE_LOCATION)
ETC_LOCATION = ONE_LOCATION ? ONE_LOCATION + '/etc' : '/etc/one'

# Ruby standard library only, so the hooks need no OpenNebula gems or Ruby
# libraries on the load path.
require 'base64'
require 'yaml'
require 'logger'
require 'rexml/document'
require 'confirmate_client'
require 'ontology_mapper'

module HookCommon
  LOG_FILE = '/var/log/one/confirmate-evidence.log'

  LOG_LEVELS = {
    'debug' => Logger::DEBUG,
    'info'  => Logger::INFO,
    'warn'  => Logger::WARN,
    'error' => Logger::ERROR
  }.freeze

  # Runs one hook. Yields the decoded payload XML, a mapper, a client and the
  # logger. Any error is written to stderr and to the log file, and the hook
  # exits 0, because a failed hook must never block OpenNebula.
  #
  # @param name [String] hook name, for example 'confirmate_vm_evidence'
  def self.run(name)
    # The hook template sets ARGUMENTS_STDIN = YES. Fall back to ARGV when
    # stdin is absent or empty, so an empty pipe doesn't lose the ARGV data.
    raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
    raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

    if raw_input.nil? || raw_input.empty?
      $stderr.puts "#{name}: no data received"
      exit 0
    end

    xml = Base64.decode64(raw_input)
    config = YAML.load_file(File.join(ETC_LOCATION, 'confirmate-evidence.conf'))
    logger = create_logger(config)

    logger.info("#{name} triggered")
    yield xml, OntologyMapper.new(config), ConfirmateClient.new(config, logger), logger
    logger.info("#{name} completed")
  rescue StandardError => e
    msg = "#{name}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    $stderr.puts msg
    begin
      File.open(LOG_FILE, 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
    rescue StandardError
      # Never crash the hook because the log file can't be written
    end
    exit 0
  end

  # Returns the resource XML that an API hook payload carries in
  # <CALL_INFO><EXTRA><TAG>, as a document whose root is the resource (the
  # shape of `one<resource> show -x`), together with its id. Returns nil when
  # the payload has no such element.
  #
  # @param api_xml [String] decoded API hook payload
  # @param tag [String] resource element, for example 'VNET'
  # @return [Array(String, String), nil] [resource_xml, resource_id]
  def self.extra_resource(api_xml, tag)
    doc = REXML::Document.new(api_xml)
    elem = doc.elements["CALL_INFO/EXTRA/#{tag}"] || doc.elements["HOOK_MESSAGE/EXTRA/#{tag}"]
    return nil if elem.nil?

    resource_doc = REXML::Document.new
    resource_doc << elem.deep_clone
    resource_xml = String.new
    resource_doc.write(resource_xml)
    [resource_xml, elem.elements['ID']&.text]
  end

  # Some API calls (one.datastore.chmod, one.user.update) post only the call
  # parameters and no EXTRA resource. This reads the resource back from
  # OpenNebula with `<command> show -x <id>`, where the id is the second IN
  # parameter of the call. Returns nil, and logs why, when that fails.
  #
  # @param api_xml [String] decoded API hook payload
  # @param command [String] CLI command, for example 'oneuser'
  # @param logger [Logger]
  # @return [Array(String, String), nil] [resource_xml, resource_id]
  def self.read_back(api_xml, command, logger)
    doc = REXML::Document.new(api_xml)
    id_param = REXML::XPath.first(doc, "CALL_INFO/PARAMETERS/PARAMETER[TYPE='IN'][POSITION='2']/VALUE")
    id = id_param&.text.to_s.strip

    unless id.match?(/\A\d+\z/)
      logger.info("No resource and no usable id in the payload, nothing to send")
      return nil
    end

    logger.info("No resource in the payload, reading #{id} back with #{command}")
    resource_xml = `#{command} show -x #{id} 2>/dev/null`
    if resource_xml.to_s.strip.empty?
      logger.warn("Could not read #{id} with #{command}, nothing to send")
      return nil
    end

    [resource_xml, id]
  end

  # Sends each evidence and logs a failure instead of raising it, so that one
  # rejected NIC or disk doesn't stop the others.
  def self.store_each(client, evidences, logger, kind)
    evidences.each do |evidence|
      begin
        client.store_evidence(evidence)
      rescue StandardError => e
        logger.warn("Failed to send #{kind} evidence: #{e.message}")
      end
    end
  end

  def self.create_logger(config)
    log_file = config.dig('logging', 'file') || LOG_FILE
    log_level = (config.dig('logging', 'level') || 'info').downcase
    logger = Logger.new(log_file, 10, 1_048_576) rescue Logger.new($stderr)
    logger.level = LOG_LEVELS.fetch(log_level, Logger::INFO)
    logger
  end
end
