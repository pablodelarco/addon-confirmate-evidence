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
  $stderr.puts "confirmate_net_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_net_evidence') do |api_xml, mapper, client, logger|
  vnet_xml, vnet_id = HookCommon.extra_resource(api_xml, 'VNET')
  if vnet_xml.nil?
    logger.warn('No VNET element in API hook payload, skipping')
    next
  end

  logger.info("Network creation detected: VNet #{vnet_id}")
  client.store_evidence(mapper.map_network(vnet_xml))
end
