#!/usr/bin/ruby
# =============================================================================
# confirmate_nic_evidence.rb - NIC attach/detach evidence hook
# =============================================================================
# OpenNebula API hook triggered on one.vm.attachnic and one.vm.detachnic calls.
# Extracts NIC data from the API hook template and sends NetworkInterface
# evidence to Confirmate's Evidence Store.
#
# Usage (via hook template):
#   COMMAND = "confirmate_nic_evidence.rb"
#   ARGUMENTS = "$API"
#   ARGUMENTS_STDIN = "YES"
#   CALL = "one.vm.attachnic"
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
    $stderr.puts 'confirmate_nic_evidence: no API data received'
    exit 1
  end

  # Decode Base64-encoded API hook XML
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

  logger.info('NIC evidence hook triggered')

  # API hooks wrap content in <HOOK_MESSAGE>. Extract the relevant parameters.
  # The API hook XML contains:
  #   <HOOK_MESSAGE>
  #     <CALL_INFO>...</CALL_INFO>
  #     <PARAMETERS>
  #       <PARAMETER>
  #         <POSITION>N</POSITION>
  #         <TYPE>IN/OUT</TYPE>
  #         <VALUE>Base64-encoded value</VALUE>
  #       </PARAMETER>
  #     </PARAMETERS>
  #   </HOOK_MESSAGE>
  doc = REXML::Document.new(api_xml)

  # For attachnic, parameter 1 is the VM ID, parameter 2 is the NIC template
  # After the API call succeeds, we need the VM data to send full evidence
  # Try to extract the VM ID and use ONE API to get the full VM XML
  vm_id = nil
  doc.each_element('HOOK_MESSAGE/PARAMETERS/PARAMETER') do |param|
    pos = param.elements['POSITION']&.text
    if pos == '1'
      vm_id = param.elements['VALUE']&.text
      break
    end
  end

  if vm_id
    logger.info("NIC change detected for VM #{vm_id}")

    # Use OpenNebula Ruby bindings to fetch full VM data
    begin
      require 'opennebula'

      client = OpenNebula::Client.new
      vm = OpenNebula::VirtualMachine.new_with_id(vm_id.to_i, client)
      rc = vm.info

      if OpenNebula.is_error?(rc)
        logger.error("Failed to fetch VM #{vm_id}: #{rc.message}")
        exit 0
      end

      vm_xml = vm.to_xml

      # Map and send NIC evidence
      mapper = OntologyMapper.new(config)
      nic_evidences = mapper.map_nics(vm_xml)
      client = ConfirmateClient.new(config, logger)

      nic_evidences.each do |nic_ev|
        begin
          client.store_evidence(nic_ev)
        rescue StandardError => e
          logger.warn("Failed to send NIC evidence: #{e.message}")
        end
      end

      # Also send updated VM evidence (NIC list changed)
      vm_evidence = mapper.map_vm(vm_xml)
      client.store_evidence(vm_evidence)

    rescue LoadError => e
      logger.warn("OpenNebula Ruby bindings not available: #{e.message}")
      logger.warn('NIC evidence will be sent on next VM state change')
    end
  else
    logger.warn('Could not extract VM ID from API hook data')
  end

  logger.info('NIC evidence hook completed')

rescue StandardError => e
  msg = "confirmate_nic_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback
  end
  exit 0
end
