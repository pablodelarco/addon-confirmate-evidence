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

require 'base64'
require 'yaml'
require 'logger'
require 'rexml/document'
require 'confirmate_client'
require 'ontology_mapper'

begin
  # Read API hook data from STDIN or ARGV
  if !$stdin.tty? && !$stdin.closed?
    raw_input = $stdin.read
  else
    raw_input = ARGV[0]
  end

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_net_evidence: no API data received'
    exit 1
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

  # For API hooks, extract the VNet ID from the API call result
  # and fetch the full VNet XML via ONE API
  doc = REXML::Document.new(api_xml)

  # Extract the VNet ID from API response (output parameter)
  vnet_id = nil
  doc.each_element('HOOK_MESSAGE/PARAMETERS/PARAMETER') do |param|
    type = param.elements['TYPE']&.text
    if type == 'OUT'
      # The OUT parameter contains the result (VNet ID on success)
      value = param.elements['VALUE']&.text
      # Parse the XML-RPC response to get the VNet ID
      begin
        result_doc = REXML::Document.new(value)
        vnet_id = result_doc.elements['methodResponse/params/param/value/array/data/value[2]/i4']&.text
      rescue StandardError
        vnet_id = value
      end
      break
    end
  end

  if vnet_id
    logger.info("Network creation detected: VNet #{vnet_id}")

    begin
      require 'opennebula'

      client = OpenNebula::Client.new
      vnet = OpenNebula::VirtualNetwork.new_with_id(vnet_id.to_i, client)
      rc = vnet.info

      if OpenNebula.is_error?(rc)
        logger.error("Failed to fetch VNet #{vnet_id}: #{rc.message}")
        exit 0
      end

      vnet_xml = vnet.to_xml

      mapper = OntologyMapper.new(config)
      evidence = mapper.map_network(vnet_xml)

      client = ConfirmateClient.new(config, logger)
      client.store_evidence(evidence)

    rescue LoadError => e
      logger.warn("OpenNebula Ruby bindings not available: #{e.message}")
    end
  else
    logger.warn('Could not extract VNet ID from API hook data')
  end

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
