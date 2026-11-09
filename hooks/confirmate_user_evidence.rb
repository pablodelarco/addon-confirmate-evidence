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
HOOKS_LIB = if ONE_LOCATION
              ONE_LOCATION + '/var/remotes/hooks/confirmate-evidence/lib'
            else
              '/var/lib/one/remotes/hooks/confirmate-evidence/lib'
            end
$LOAD_PATH << HOOKS_LIB

# Never block OpenNebula: if the add-on can't be loaded, log and exit 0.
begin
  require 'hook_common'
rescue ScriptError, StandardError => e
  $stderr.puts "confirmate_user_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_user_evidence') do |api_xml, mapper, client, logger|
  # one.user.update posts only the call parameters, with no <USER>, so a 2FA
  # change would go unreported. Read the user back by id in that case.
  user_xml, user_id = HookCommon.extra_resource(api_xml, 'USER') \
                      || HookCommon.read_back(api_xml, 'oneuser', logger)
  next if user_xml.nil?

  logger.info("User change detected: user #{user_id}")
  evidence = mapper.map_identity(user_xml)

  # nil means a service account (server_cipher). Reporting it would show a
  # privileged human without MFA that doesn't exist.
  if evidence.nil?
    logger.info("User #{user_id} is a service account, no Identity evidence sent")
    next
  end

  client.store_evidence(evidence)
end
