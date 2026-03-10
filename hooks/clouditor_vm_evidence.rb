#!/usr/bin/ruby
# =============================================================================
# clouditor_vm_evidence.rb - VM state change evidence hook
# =============================================================================
# OpenNebula hook script triggered on VM state changes (RUNNING, POWEROFF, DONE).
# Extracts VM data from the hook template, maps it to Clouditor's ontology,
# and sends evidence to the Evidence Store.
#
# Usage (via hook template):
#   COMMAND = "clouditor_vm_evidence.rb"
#   ARGUMENTS = "$TEMPLATE"
#   ARGUMENTS_STDIN = "YES"
#
# Part of addon-clouditor-evidence (EMERALD project)
# =============================================================================

ONE_LOCATION = ENV['ONE_LOCATION']

if !ONE_LOCATION
  RUBY_LIB_LOCATION = '/usr/lib/one/ruby'
  GEMS_LOCATION     = '/usr/share/one/gems'
  ETC_LOCATION      = '/etc/one'
  HOOKS_LIB         = '/var/lib/one/remotes/hooks/clouditor-evidence/lib'
else
  RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby'
  GEMS_LOCATION     = ONE_LOCATION + '/share/gems'
  ETC_LOCATION      = ONE_LOCATION + '/etc'
  HOOKS_LIB         = ONE_LOCATION + '/var/remotes/hooks/clouditor-evidence/lib'
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
require 'clouditor_client'
require 'ontology_mapper'

begin
  # Read template from STDIN (ARGUMENTS_STDIN = YES) or from ARGV
  if !$stdin.tty? && !$stdin.closed?
    raw_input = $stdin.read
  else
    raw_input = ARGV[0]
  end

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'clouditor_vm_evidence: no template data received'
    exit 1
  end

  # Decode Base64-encoded XML template
  template_xml = Base64.decode64(raw_input)

  # Load configuration
  config_path = File.join(ETC_LOCATION, 'clouditor-evidence.conf')
  config = YAML.load_file(config_path)

  # Set up logging
  log_file = config.dig('logging', 'file') || '/var/log/one/clouditor-evidence.log'
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

  # Map VM XML to Clouditor ontology
  mapper = OntologyMapper.new(config)
  vm_evidence = mapper.map_vm(template_xml)

  # Also extract and send NIC evidence for each network interface
  nic_evidences = mapper.map_nics(template_xml)

  # Send VM evidence to Clouditor
  client = ClouditorClient.new(config, logger)
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
  msg = "clouditor_vm_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  # Log to file if possible
  begin
    File.open('/var/log/one/clouditor-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback - never crash the hook
  end
  # Exit 0 to avoid blocking OpenNebula operations
  exit 0
end
