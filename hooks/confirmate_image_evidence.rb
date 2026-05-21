#!/usr/bin/ruby
# =============================================================================
# confirmate_image_evidence.rb - Image state change evidence hook
# =============================================================================
# OpenNebula hook triggered when an Image reaches READY state.
# Sends VMImage evidence to Confirmate's Evidence Store.
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
require 'confirmate_client'
require 'ontology_mapper'

begin
  # Read template from STDIN or ARGV
  if !$stdin.tty? && !$stdin.closed?
    raw_input = $stdin.read
  else
    raw_input = ARGV[0]
  end

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_image_evidence: no template data received'
    exit 1
  end

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

  logger.info('Image evidence hook triggered')

  # Map Image XML to Confirmate ontology
  mapper = OntologyMapper.new(config)
  evidence = mapper.map_image(template_xml)

  # Send to Confirmate
  client = ConfirmateClient.new(config, logger)
  client.store_evidence(evidence)

  logger.info('Image evidence hook completed successfully')

rescue StandardError => e
  msg = "confirmate_image_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback
  end
  exit 0
end
