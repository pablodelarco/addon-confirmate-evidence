#!/usr/bin/ruby
# =============================================================================
# confirmate_user_evidence.rb - Identity evidence hook
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
  $stderr.puts "confirmate_user_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

begin
  # Read API hook data from STDIN, falling back to ARGV when stdin is
  # absent OR empty (an empty pipe must not lose the ARGV data).
  raw_input = (!$stdin.tty? && !$stdin.closed? ? $stdin.read : nil)
  raw_input = ARGV[0] if raw_input.nil? || raw_input.strip.empty?

  if raw_input.nil? || raw_input.empty?
    $stderr.puts 'confirmate_user_evidence: no API data received'
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

  logger.info('Identity evidence hook triggered')

  # OpenNebula 7.2 API-hook payload (POST-hook) shape:
  #   <CALL_INFO>
  #     <RESULT>...</RESULT>
  #     <PARAMETERS>...IN+OUT...</PARAMETERS>
  #     <EXTRA><USER>...full resource XML...</USER></EXTRA>
  #   </CALL_INFO>
  # The EXTRA section already contains the resource — no XML-RPC fetch needed.
  doc = REXML::Document.new(api_xml)

  user_elem = doc.elements['CALL_INFO/EXTRA/USER'] \
           || doc.elements['HOOK_MESSAGE/EXTRA/USER'] # legacy fallback

  if user_elem.nil?
    logger.warn('No USER element in API hook payload — skipping')
    exit 0
  end

  # Serialize the <USER> subtree. OntologyMapper#map_identity expects a root
  # document whose root is the resource, matching `oneuser show -x` output.
  user_doc = REXML::Document.new
  user_doc << user_elem.deep_clone
  user_xml = String.new
  user_doc.write(user_xml)

  user_id = user_elem.elements['ID']&.text
  logger.info("User change detected: user #{user_id}")

  mapper = OntologyMapper.new(config)
  evidence = mapper.map_identity(user_xml)

  # nil means a service account (server_cipher). Reporting it would surface a
  # privileged human without MFA that does not exist.
  if evidence.nil?
    logger.info("User #{user_id} is a service account — no Identity evidence sent")
    exit 0
  end

  client = ConfirmateClient.new(config, logger)
  client.store_evidence(evidence)

  logger.info('Identity evidence hook completed')

rescue StandardError => e
  msg = "confirmate_user_evidence: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
  $stderr.puts msg
  begin
    File.open('/var/log/one/confirmate-evidence.log', 'a') { |f| f.puts "[#{Time.now}] ERROR #{msg}" }
  rescue StandardError
    # Silent fallback
  end
  exit 0
end
