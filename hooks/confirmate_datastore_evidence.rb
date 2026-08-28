#!/usr/bin/ruby
# =============================================================================
# confirmate_datastore_evidence.rb - Identity evidence hook
# =============================================================================
# OpenNebula API hook triggered on one.user.allocate and one.user.update.
# Sends Identity evidence to Confirmate's Evidence Store, so metrics such as
# AdminMFAEnabled (CIS 4.5) can assess whether privileged accounts have a
# second factor enrolled.
#
# one.user.update matters as much as allocate: FireEdge writes the enrolled
# TOTP secret into the user template, so enabling 2FA is an update, not a
# creation.
#
# Part of addon-confirmate-evidence (EMERALD project)
# =============================================================================

ONE_LOCATION = ENV['ONE_LOCATION']

if !ONE_LOCATION
  RUBY_LIB_LOCATION = '/usr/lib/one/ruby'
  GEMS_LOCATION     = '/usr/share/one/gems'
  ETC_LOCATION      = '/etc/one'
  HOOKS_LIB         = '/var/lib/one/remotes/hooks/confirmate-evidence/lib'
else
  RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby'
  GEMS_LOCATION     = ONE_LOCATION + '/share/gems'
  ETC_LOCATION      = ONE_LOCATION + '/etc'
  HOOKS_LIB         = ONE_LOCATION + '/var/remotes/hooks/confirmate-evidence/lib'
end

if File.directory?(GEMS_LOCATION)
  real_gems_path = File.realpath(GEMS_LOCATION)
  ENV['GEM_PATH'] = real_gems_path if !ENV['GEM_PATH']&.include?(real_gems_path)
  Gem.use_paths(real_gems_path)
end

$LOAD_PATH << RUBY_LIB_LOCATION
$LOAD_PATH << HOOKS_LIB

# Never block OpenNebula operations: if the addon's dependencies cannot
# be loaded (broken install, missing lib), log to stderr and exit 0.
begin
  require 'base64'
  require 'yaml'
  require 'logger'
  require 'rexml/document'
  require 'confirmate_client'
  require 'ontology_mapper'
rescue ScriptError, StandardError => e
  $stderr.puts "confirmate_datastore_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

begin
  # Read API hook data from STDIN, falling back to ARGV when stdin is
  # absent OR empty (an empty pipe must not lose the ARGV data).
  raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
  raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_datastore_evidence: no API data received'
    exit 0 # never block OpenNebula, even on misconfigured invocations
  end

  api_xml = Base64.decode64(raw_input)

  # Load configuration
  config_path = File.join(ETC_LOCATION, 'confirmate-evidence.conf')
  config = YAML.load_file(config_path)

  # Set up logging
  log_file = config.dig('logging', 'file') || '/var/log/one/confirmate-evidence.log'
  log_level = config.dig('logging', 'level') || 'info'
  logger = Logger.new(log_file, 10, 1_048_576) rescue Logger.new($stderr)
  logger.level = case log_level.downcase
                 when 'debug' then Logger::DEBUG
                 when 'info'  then Logger::INFO
                 when 'warn'  then Logger::WARN
                 when 'error' then Logger::ERROR
                 else Logger::INFO
                 end

  logger.info('Datastore evidence hook triggered')

  # OpenNebula API-hook payload (POST-hook) shape:
  #   <CALL_INFO><EXTRA><DATASTORE>...full resource XML...</DATASTORE></EXTRA></CALL_INFO>
  # allocate carries the new datastore, chmod and update the changed one.
  doc = REXML::Document.new(api_xml)

  ds_elem = doc.elements['CALL_INFO/EXTRA/DATASTORE'] || REXML::XPath.first(doc, '//DATASTORE')

  # one.datastore.chmod is the call that changes OTHER_U, the bit the
  # ObjectStoragePublicAccessDisabled metric reads, and it is also the one call
  # whose payload carries no <DATASTORE>. Falling back to reading the object by
  # id keeps a permission change from going unreported, which would leave a
  # datastore looking private after somebody opened it.
  if ds_elem.nil?
    id_param = REXML::XPath.first(doc, "CALL_INFO/PARAMETERS/PARAMETER[TYPE='IN'][POSITION='2']/VALUE")
    ds_id = id_param&.text.to_s.strip

    unless ds_id.match?(/\A\d+\z/)
      logger.info('No DATASTORE element and no usable datastore id in the payload, nothing to send')
      exit 0
    end

    logger.info("No DATASTORE element, reading datastore #{ds_id} back from OpenNebula")
    ds_xml = `onedatastore show -x #{ds_id} 2>/dev/null`
    if ds_xml.to_s.strip.empty?
      logger.warn("Could not read datastore #{ds_id}, nothing to send")
      exit 0
    end
  else
    ds_doc = REXML::Document.new
    ds_doc << ds_elem.deep_clone
    ds_xml = String.new
    ds_doc.write(ds_xml)
    ds_id = ds_elem.elements['ID']&.text
  end
  logger.info("Datastore change detected: datastore #{ds_id}")

  mapper = OntologyMapper.new(config)
  evidence = mapper.map_datastore(ds_xml)

  client = ConfirmateClient.new(config, logger)
  client.store_evidence(evidence)

  logger.info('Datastore evidence hook completed')

rescue StandardError => e
  msg = "confirmate_datastore_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
  end
  exit 0
end
