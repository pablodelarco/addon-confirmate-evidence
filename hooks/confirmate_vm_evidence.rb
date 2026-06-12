#!/usr/bin/ruby
# =============================================================================
# confirmate_vm_evidence.rb - VM state change evidence hook
# =============================================================================
# OpenNebula hook script triggered on VM state changes (RUNNING, POWEROFF, DONE).
# Extracts VM data from the hook template, maps it to Confirmate's ontology,
# and sends evidence to the Evidence Store.
#
# Usage (via hook template):
#   COMMAND = "confirmate_vm_evidence.rb"
#   ARGUMENTS = "$TEMPLATE"
#   ARGUMENTS_STDIN = "YES"
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
  require 'confirmate_client'
  require 'ontology_mapper'
rescue ScriptError, StandardError => e
  $stderr.puts "confirmate_vm_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

begin
  # Read template from STDIN (ARGUMENTS_STDIN = YES), falling back to ARGV
  # when stdin is absent OR empty (an empty pipe must not lose the ARGV data).
  raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
  raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_vm_evidence: no template data received'
    exit 0 # never block OpenNebula, even on misconfigured invocations
  end

  # Decode Base64-encoded XML template
  template_xml = Base64.decode64(raw_input)

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

  logger.info('VM evidence hook triggered')

  # Map VM XML to Confirmate ontology
  mapper = OntologyMapper.new(config)

  # Fetch the rules of the security groups referenced by the VM's NICs so the
  # mapper can compute SSH/RDP exposure (CIS 9.2/9.3). Best-effort: on partial
  # failure the mapper omits those labels rather than claiming false compliance.
  sg_xml_by_id = OntologyMapper.fetch_sg_xml_by_id(template_xml)

  vm_evidence = mapper.map_vm(template_xml, sg_xml_by_id: sg_xml_by_id)

  # Also extract and send NIC evidence for each network interface. The SG data
  # lets each NIC carry accessRestriction.l3Firewall (RestrictSSH metric).
  nic_evidences = mapper.map_nics(template_xml, sg_xml_by_id: sg_xml_by_id)

  # Send VM evidence to Confirmate
  client = ConfirmateClient.new(config, logger)
  client.store_evidence(vm_evidence)

  # Send NIC evidence for each interface
  nic_evidences.each do |nic_ev|
    begin
      client.store_evidence(nic_ev)
    rescue StandardError => e
      logger.warn("Failed to send NIC evidence: #{e.message}")
    end
  end

  logger.info('VM evidence hook completed successfully')

rescue StandardError => e
  msg = "confirmate_vm_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  # Log to file if possible
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback - never crash the hook
  end
  # Exit 0 to avoid blocking OpenNebula operations
  exit 0
end
