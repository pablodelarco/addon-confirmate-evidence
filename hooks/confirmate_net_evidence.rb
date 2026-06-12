#!/usr/bin/ruby
# =============================================================================
# confirmate_net_evidence.rb - Virtual Network creation evidence hook
# =============================================================================
# OpenNebula API hook triggered on one.vn.allocate calls.
# Sends VirtualNetwork evidence to Confirmate's Evidence Store.
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
  $stderr.puts "confirmate_net_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

begin
  # Read API hook data from STDIN, falling back to ARGV when stdin is
  # absent OR empty (an empty pipe must not lose the ARGV data).
  raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
  raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_net_evidence: no API data received'
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

  logger.info('Network evidence hook triggered')

  # OpenNebula 7.2 API-hook payload (POST-hook) shape:
  #   <CALL_INFO>
  #     <RESULT>...</RESULT>
  #     <PARAMETERS>...IN+OUT...</PARAMETERS>
  #     <EXTRA><VNET>...full resource XML...</VNET></EXTRA>
  #   </CALL_INFO>
  # The EXTRA section already contains the resource — no XML-RPC fetch needed.
  doc = REXML::Document.new(api_xml)

  vnet_elem = doc.elements['CALL_INFO/EXTRA/VNET'] \
           || doc.elements['HOOK_MESSAGE/EXTRA/VNET'] # legacy fallback

  if vnet_elem.nil?
    logger.warn('No VNET element in API hook payload — skipping')
    exit 0
  end

  # Serialize the <VNET> subtree to a string. OntologyMapper#map_network
  # expects a root XML document whose root is the resource, matching
  # `onevnet show -x` output. Build a fresh document around it.
  vnet_doc = REXML::Document.new
  vnet_doc << vnet_elem.deep_clone
  vnet_xml = String.new
  vnet_doc.write(vnet_xml)

  vnet_id = vnet_elem.elements['ID']&.text
  logger.info("Network creation detected: VNet #{vnet_id}")

  mapper = OntologyMapper.new(config)
  evidence = mapper.map_network(vnet_xml)

  client = ConfirmateClient.new(config, logger)
  client.store_evidence(evidence)

  logger.info('Network evidence hook completed')

rescue StandardError => e
  msg = "confirmate_net_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback
  end
  exit 0
end
