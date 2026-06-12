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
  $stderr.puts "confirmate_nic_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

begin
  # Read API hook data from STDIN, falling back to ARGV when stdin is
  # absent OR empty (an empty pipe must not lose the ARGV data).
  raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
  raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_nic_evidence: no API data received'
    exit 0 # never block OpenNebula, even on misconfigured invocations
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

  # OpenNebula 7.2 API-hook payload (POST-hook) shape:
  #   <CALL_INFO>
  #     <RESULT>...</RESULT>
  #     <PARAMETERS>...IN+OUT...</PARAMETERS>
  #     <EXTRA><VM>...full resource XML...</VM></EXTRA>
  #   </CALL_INFO>
  # For one.vm.attachnic / one.vm.detachnic the EXTRA carries the post-call
  # VM XML, so we can map directly without an XML-RPC round trip.
  doc = REXML::Document.new(api_xml)

  vm_elem = doc.elements['CALL_INFO/EXTRA/VM'] \
         || doc.elements['HOOK_MESSAGE/EXTRA/VM'] # legacy fallback

  if vm_elem.nil?
    logger.warn('No VM element in API hook payload — skipping')
    exit 0
  end

  vm_doc = REXML::Document.new
  vm_doc << vm_elem.deep_clone
  vm_xml = String.new
  vm_doc.write(vm_xml)

  vm_id = vm_elem.elements['ID']&.text
  logger.info("NIC change detected for VM #{vm_id}")

  mapper = OntologyMapper.new(config)
  client = ConfirmateClient.new(config, logger)

  # One SG fetch serves both the per-NIC accessRestriction.l3Firewall
  # (RestrictSSH metric) and the VM's ssh/rdp labels below.
  sg_xml_by_id = OntologyMapper.fetch_sg_xml_by_id(vm_xml)

  # Submit one NetworkInterface evidence per NIC, plus an updated VM evidence
  # so networkInterfaceIds reflects the new state.
  mapper.map_nics(vm_xml, sg_xml_by_id: sg_xml_by_id).each do |nic_ev|
    begin
      client.store_evidence(nic_ev)
    rescue StandardError => e
      logger.warn("Failed to send NIC evidence: #{e.message}")
    end
  end

  # Pass the security-group rules here too: this refreshed VM evidence is the
  # latest the orchestrator will assess, so omitting the SG data would silently
  # drop the sshRestricted/rdpRestricted labels on every NIC attach/detach.
  client.store_evidence(mapper.map_vm(vm_xml, sg_xml_by_id: sg_xml_by_id))

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
