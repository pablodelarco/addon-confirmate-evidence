#!/usr/bin/ruby
# =============================================================================
# confirmate_datastore_evidence.rb - Datastore evidence hook
# =============================================================================
# OpenNebula API hook triggered on one.datastore.allocate, one.datastore.chmod
# and one.datastore.update. Sends ObjectStorage evidence to Confirmate's
# Evidence Store, so the ObjectStoragePublicAccessDisabled metric can assess
# whether a datastore is open to other users.
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
  $stderr.puts "confirmate_datastore_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_datastore_evidence') do |api_xml, mapper, client, logger|
  # one.datastore.chmod changes OTHER_U, the bit the metric reads, but its
  # payload carries no <DATASTORE>. Reading the datastore back by id keeps a
  # permission change from going unreported.
  ds_xml, ds_id = HookCommon.extra_resource(api_xml, 'DATASTORE') \
                  || HookCommon.read_back(api_xml, 'onedatastore', logger)
  next if ds_xml.nil?

  logger.info("Datastore change detected: datastore #{ds_id}")
  client.store_evidence(mapper.map_datastore(ds_xml))
end
