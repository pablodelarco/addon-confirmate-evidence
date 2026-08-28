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

  # The datastore XML arrives inside <EXTRA> for allocate, and as the updated
  # object for chmod/update. Take whichever is present.
  doc = REXML::Document.new(api_xml)
  ds_elem = REXML::XPath.first(doc, '//DATASTORE')

  if ds_elem.nil?
    logger.info('No DATASTORE element in the API payload, nothing to send')
    exit 0
  end

  ds_doc = REXML::Document.new
  ds_doc << ds_elem.deep_clone
  ds_xml = String.new
  ds_doc.write(ds_xml)

  ds_id = ds_elem.elements['ID']&.text
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
