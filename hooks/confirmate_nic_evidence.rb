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
  $stderr.puts "confirmate_nic_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_nic_evidence') do |api_xml, mapper, client, logger|
  # For one.vm.attachnic and one.vm.detachnic the payload carries the VM XML
  # after the call.
  vm_xml, vm_id = HookCommon.extra_resource(api_xml, 'VM')
  if vm_xml.nil?
    logger.warn('No VM element in API hook payload, skipping')
    next
  end

  logger.info("NIC change detected for VM #{vm_id}")

  # One security group fetch serves the NIC evidence and the VM evidence.
  sg_xml_by_id = OntologyMapper.fetch_sg_xml_by_id(vm_xml)

  HookCommon.store_each(client, mapper.map_nics(vm_xml, sg_xml_by_id: sg_xml_by_id), logger, 'NIC')

  # Send the VM again, so networkInterfaceIds shows the new NIC list. It needs
  # the security group rules too, or the sshRestricted and rdpRestricted labels
  # disappear on every attach or detach.
  client.store_evidence(mapper.map_vm(vm_xml, sg_xml_by_id: sg_xml_by_id))
end
