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
  $stderr.puts "confirmate_image_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_image_evidence') do |image_xml, mapper, client, _logger|
  client.store_evidence(mapper.map_image(image_xml))
end
