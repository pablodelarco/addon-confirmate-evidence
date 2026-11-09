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
  $stderr.puts "confirmate_vm_evidence: failed to load dependencies: #{e.message}"
  exit 0
end

HookCommon.run('confirmate_vm_evidence') do |vm_xml, mapper, client, logger|
  # The security group rules let the mapper compute SSH/RDP exposure (CIS 9.2,
  # 9.3) on the VM and accessRestriction.l3Firewall (RestrictSSH) on each NIC.
  # On a partial fetch the mapper omits those labels instead of claiming
  # compliance.
  sg_xml_by_id = OntologyMapper.fetch_sg_xml_by_id(vm_xml)

  client.store_evidence(mapper.map_vm(vm_xml, sg_xml_by_id: sg_xml_by_id))
  HookCommon.store_each(client, mapper.map_nics(vm_xml, sg_xml_by_id: sg_xml_by_id), logger, 'NIC')

  # One BlockStorage per disk. The VM evidence lists these ids in
  # blockStorageIds. Without them Confirmate can't resolve the VM's `related`
  # array, and VirtualMachineDiskEncryptionEnabled (CIS 4.3) never evaluates.
  HookCommon.store_each(client, mapper.map_block_storages(vm_xml), logger, 'disk')
end
