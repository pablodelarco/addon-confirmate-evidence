#!/usr/bin/ruby
# =============================================================================
# Unit tests for OntologyMapper (Confirmate evidence shape)
# =============================================================================

require 'minitest/autorun'
require 'json'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'ontology_mapper'

class TestOntologyMapper < Minitest::Test
  TOE_UUID = '11111111-2222-3333-4444-555555555555'

  def setup
    @config = {
      'evidence' => {
        'tool_id' => 'test-tool',
        'target_of_evaluation_id' => TOE_UUID,
        'default_region' => 'eu-south-1'
      }
    }
    @mapper = OntologyMapper.new(@config)
  end

  # --- Evidence envelope (Confirmate shape) ---

  def test_evidence_top_level_has_no_outer_wrapper
    # Confirmate's StoreEvidence REST endpoint takes the Evidence message as
    # the HTTP body directly (proto: option (google.api.http) body: "evidence").
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    refute evidence.key?('evidence'),
           'Evidence must not be wrapped in {"evidence": ...} — that is the old Clouditor shape'
  end

  def test_evidence_has_required_top_level_fields
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    assert evidence.key?('id'),                   'must have id'
    assert evidence.key?('timestamp'),            'must have timestamp'
    assert evidence.key?('targetOfEvaluationId'), 'must have targetOfEvaluationId (Confirmate field)'
    assert evidence.key?('toolId'),               'must have toolId'
    assert evidence.key?('resource'),             'must have resource'
    refute evidence.key?('cloudServiceId'),       'cloudServiceId is the old Clouditor name'
  end

  def test_target_of_evaluation_id_from_new_config_key
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    assert_equal TOE_UUID, evidence['targetOfEvaluationId']
  end

  def test_target_of_evaluation_id_back_compat_with_old_key
    legacy_uuid = 'aaaaaaaa-1111-4222-8333-444444444444'
    config = {
      'evidence' => { 'tool_id' => 't', 'cloud_service_id' => legacy_uuid }
    }
    mapper = OntologyMapper.new(config)
    evidence = mapper.map_vm(File.read(fixture('vm_template.xml')))
    assert_equal legacy_uuid, evidence['targetOfEvaluationId'],
                 'Operator who upgrades the addon before editing the config should still get a working install'
  end

  def test_placeholder_target_of_evaluation_id_is_allowed_with_warning
    # The all-zeros UUID is a valid ToE against a local default orchestrator, so
    # it must NOT hard-fail; it only warns.
    mapper = nil
    _out, err = capture_io do
      mapper = OntologyMapper.new('evidence' => { 'target_of_evaluation_id' => '00000000-0000-0000-0000-000000000000' })
    end
    refute_nil mapper
    assert_match(/placeholder/i, err)
  end

  def test_missing_target_of_evaluation_id_is_rejected
    assert_raises(RuntimeError) do
      OntologyMapper.new('evidence' => { 'tool_id' => 't' })
    end
  end

  def test_malformed_target_of_evaluation_id_is_rejected
    # A non-UUID value can never be accepted by any orchestrator -> fail fast.
    assert_raises(RuntimeError) do
      OntologyMapper.new('evidence' => { 'target_of_evaluation_id' => 'not-a-uuid' })
    end
  end

  # --- VM mapping ---

  def test_map_vm_basic_fields
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    assert_equal 'test-tool', evidence['toolId']
    vm = evidence['resource']['virtualMachine']
    assert_equal 'one-vm-42', vm['id']
    assert_equal 'emerald-test-vm', vm['name']
  end

  def test_map_vm_creation_time
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, vm['creationTime'])
  end

  def test_map_vm_network_interface_ids
    # NICs are IDs only in the new ontology; full NIC evidence is submitted
    # separately via map_nics.
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_equal ['one-nic-42-0', 'one-nic-42-1'], vm['networkInterfaceIds']
    refute vm.key?('networkInterfaces'), 'old field name must be gone'
  end

  def test_map_vm_block_storage_ids
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_equal ['one-disk-42-0', 'one-disk-42-1'], vm['blockStorageIds']
    refute vm.key?('blockStorage'), 'old field name must be gone'
  end

  def test_map_vm_internet_accessible_endpoint
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    # vm_template.xml has a NIC with EXTERNAL=YES
    assert_equal true, vm['internetAccessibleEndpoint']
    refute vm.key?('publicIp'), 'old field name must be gone'
  end

  def test_map_vm_no_public_endpoint
    evidence = @mapper.map_vm(File.read(fixture('vm_no_encryption.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_equal false, vm['internetAccessibleEndpoint']
  end

  def test_map_vm_automatic_updates_renamed
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert vm.key?('automaticUpdates'), 'autoUpdates was renamed to automaticUpdates'
    refute vm.key?('autoUpdates')
  end

  def test_map_vm_geo_location
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_equal 'eu-south-1', vm['geoLocation']['region']
  end

  def test_map_vm_logging
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    assert_equal true, vm['bootLogging']['enabled']
    assert_equal true, vm['osLogging']['enabled']
  end

  def test_map_vm_at_rest_encryption_dropped_from_vm
    # at_rest_encryption is no longer a VM-level field in
    # confirmate.ontology.v1. The XML disk-level encryption data is
    # preserved inside `raw` instead.
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    vm = evidence['resource']['virtualMachine']
    refute vm.key?('atRestEncryption')
    assert vm['raw'].include?('ENCRYPT'), 'encryption metadata is preserved in the raw XML'
  end

  def test_raw_is_on_resource_not_on_evidence
    # In Confirmate the `raw` field belongs to each ontology message,
    # not to the Evidence envelope.
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    refute evidence.key?('raw'),                              'raw must not be on Evidence'
    assert evidence['resource']['virtualMachine']['raw'],     'raw must be on the ontology resource'
  end

  # --- CXB OpenNebula custom-control labels (CIS 4.3/4.4/9.2/9.3) ---

  def test_map_vm_has_disk_and_public_ip_labels
    vm = @mapper.map_vm(File.read(fixture('vm_template.xml')))['resource']['virtualMachine']
    # Mixed disks: only DISK 0 has ENCRYPT=YES, so the all-disks check is false.
    assert_equal 'false', vm['labels']['diskEncryption'], 'CIS 4.3: ALL disks must be encrypted'
    # publicIp mirrors internetAccessibleEndpoint (true: NIC 1 is EXTERNAL)
    assert_equal 'true', vm['labels']['publicIp']
    assert_equal vm['internetAccessibleEndpoint'].to_s, vm['labels']['publicIp']
    # ssh/rdp labels are omitted unless security-group data is supplied
    refute vm['labels'].key?('sshRestricted')
    refute vm['labels'].key?('rdpRestricted')
  end

  def test_disk_encryption_label_true_when_all_disks_encrypted
    xml = <<~XML
      <VM>
        <ID>77</ID><NAME>enc-vm</NAME><STIME>1709013200</STIME>
        <TEMPLATE>
          <DISK><DISK_ID>0</DISK_ID><ENCRYPTION>luks</ENCRYPTION></DISK>
          <DISK><DISK_ID>1</DISK_ID><ENCRYPT>YES</ENCRYPT></DISK>
        </TEMPLATE>
      </VM>
    XML
    vm = @mapper.map_vm(xml)['resource']['virtualMachine']
    assert_equal 'true', vm['labels']['diskEncryption'], 'every disk carries an encryption attribute'
  end

  def test_ssh_rdp_labels_omitted_on_partial_security_group_coverage
    # vm_template.xml references SGs 0 and 1; supplying only SG 0 means the
    # rules of SG 1 are unknown -> claiming "restricted" would be a false
    # compliance statement, so the labels must be omitted.
    https_only = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                 '<RANGE>443</RANGE><RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'
    vm = nil
    _out, err = capture_io do
      vm = @mapper.map_vm(File.read(fixture('vm_template.xml')),
                          sg_xml_by_id: { '0' => https_only })['resource']['virtualMachine']
    end
    refute vm['labels'].key?('sshRestricted'), 'partial SG coverage must omit the label'
    refute vm['labels'].key?('rdpRestricted')
    assert_match(/could not be read/, err)
  end

  def test_ssh_rdp_labels_omitted_on_malformed_security_group_xml
    ids = OntologyMapper.security_group_ids(File.read(fixture('vm_template.xml')))
    sg_map = ids.each_with_object({}) { |i, h| h[i] = '<not-xml' }
    vm = nil
    capture_io do
      vm = @mapper.map_vm(File.read(fixture('vm_template.xml')),
                          sg_xml_by_id: sg_map)['resource']['virtualMachine']
    end
    refute vm['labels'].key?('sshRestricted'), 'unreadable SG rules must omit the label'
  end

  def test_security_group_ids_extracted_from_vm
    ids = OntologyMapper.security_group_ids(File.read(fixture('vm_template.xml')))
    # vm_template.xml NIC carries SECURITY_GROUPS "0,1"
    assert_includes ids, '0'
    assert_includes ids, '1'
  end

  def test_ssh_rdp_not_restricted_when_sg_allows_all_inbound
    open_sg = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>ALL</PROTOCOL>' \
              '<RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'
    ids = OntologyMapper.security_group_ids(File.read(fixture('vm_template.xml')))
    sg_map = ids.each_with_object({}) { |i, h| h[i] = open_sg }
    vm = @mapper.map_vm(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)['resource']['virtualMachine']
    assert_equal 'false', vm['labels']['sshRestricted'], 'all-inbound SG exposes SSH'
    assert_equal 'false', vm['labels']['rdpRestricted'], 'all-inbound SG exposes RDP'
  end

  def test_ssh_rdp_restricted_when_only_https_open
    https_only = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                 '<RANGE>443</RANGE><RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'
    ids = OntologyMapper.security_group_ids(File.read(fixture('vm_template.xml')))
    sg_map = ids.each_with_object({}) { |i, h| h[i] = https_only }
    vm = @mapper.map_vm(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)['resource']['virtualMachine']
    assert_equal 'true', vm['labels']['sshRestricted'], 'only 443 open -> SSH restricted'
    assert_equal 'true', vm['labels']['rdpRestricted'], 'only 443 open -> RDP restricted'
  end

  def test_ssh_open_but_from_restricted_source_is_still_restricted
    # An inbound SSH rule limited to a specific NETWORK_ID is not "from internet".
    restricted = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                 '<RANGE>22</RANGE><RULE_TYPE>INBOUND</RULE_TYPE><NETWORK_ID>3</NETWORK_ID>' \
                 '</RULE></TEMPLATE></SECURITY_GROUP>'
    ids = OntologyMapper.security_group_ids(File.read(fixture('vm_template.xml')))
    sg_map = ids.each_with_object({}) { |i, h| h[i] = restricted }
    vm = @mapper.map_vm(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)['resource']['virtualMachine']
    assert_equal 'true', vm['labels']['sshRestricted'], 'SSH limited to a network is restricted'
  end

  # --- NIC mapping ---

  def test_map_nics_count
    evidences = @mapper.map_nics(File.read(fixture('vm_template.xml')))
    assert_equal 2, evidences.length
  end

  def test_map_nic_internet_accessible_endpoint
    evidences = @mapper.map_nics(File.read(fixture('vm_template.xml')))
    nic0 = evidences[0]['resource']['networkInterface']
    nic1 = evidences[1]['resource']['networkInterface']
    # NIC 0 (10.0.0.100, RFC1918 private, no EXTERNAL) -> false;
    # NIC 1 (203.0.113.50, EXTERNAL=YES) -> true.
    assert_equal false, nic0['internetAccessibleEndpoint']
    assert_equal true,  nic1['internetAccessibleEndpoint']
  end

  def test_map_nic_labels_carry_ip_and_security_groups
    evidences = @mapper.map_nics(File.read(fixture('vm_template.xml')))
    nic0 = evidences[0]['resource']['networkInterface']
    # IP and security group references moved to labels (no first-class
    # field for either in confirmate.ontology.v1.NetworkInterface).
    assert nic0['labels'].is_a?(Hash)
    assert_equal '10.0.0.100', nic0['labels']['ip']
    assert_equal '0,1',        nic0['labels']['securityGroupIds']
    refute nic0.key?('ip'),               'old ip[] field must be gone'
    refute nic0.key?('accessRestriction'), 'old accessRestriction field must be gone'
  end

  # --- NIC accessRestriction.l3Firewall (EMERALD RestrictSSH metric) ---

  HTTPS_ONLY_SG = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                  '<RANGE>443</RANGE><RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'
  OPEN_SG = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>ALL</PROTOCOL>' \
            '<RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'

  def test_nic_l3firewall_restricted_ports_22_when_ssh_blocked
    # RestrictSSH evaluates isIn ["22"] against the restrictedPorts list
    sg_map = { '0' => HTTPS_ONLY_SG, '1' => HTTPS_ONLY_SG }
    nic = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                 .first['resource']['networkInterface']
    assert_includes nic.dig('accessRestriction', 'l3Firewall', 'restrictedPorts'), '22'
    assert_equal true, nic.dig('accessRestriction', 'l3Firewall', 'enabled')
  end

  def test_nic_l3firewall_empty_restricted_ports_when_ssh_open
    sg_map = { '0' => OPEN_SG, '1' => OPEN_SG }
    nic = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                 .first['resource']['networkInterface']
    assert_equal [], nic.dig('accessRestriction', 'l3Firewall', 'restrictedPorts'),
                 'open SG must not satisfy RestrictSSH (== "22")'
  end

  def test_nic_access_restriction_omitted_without_sg_data
    nic = @mapper.map_nics(File.read(fixture('vm_template.xml')))
                 .first['resource']['networkInterface']
    refute nic.key?('accessRestriction'), 'unknown rules must not claim a firewall state'
  end

  def test_nic_access_restriction_omitted_on_partial_sg_coverage
    # NIC references SGs 0 and 1; only SG 0 supplied -> unknown -> omit.
    nic = @mapper.map_nics(File.read(fixture('vm_template.xml')),
                           sg_xml_by_id: { '0' => HTTPS_ONLY_SG })
                 .first['resource']['networkInterface']
    refute nic.key?('accessRestriction')
  end

  BASTION_SSH_SG = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                   '<RANGE>22</RANGE><IP>10.8.0.0</IP><SIZE>256</SIZE>' \
                   '<RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'
  VNET_RDP_SG = '<SECURITY_GROUP><TEMPLATE><RULE><PROTOCOL>TCP</PROTOCOL>' \
                '<RANGE>3389</RANGE><NETWORK_ID>7</NETWORK_ID>' \
                '<RULE_TYPE>INBOUND</RULE_TYPE></RULE></TEMPLATE></SECURITY_GROUP>'

  def test_nic_allowed_sources_lists_bastion_cidr_for_ssh_rule
    sg_map = { '0' => BASTION_SSH_SG, '1' => HTTPS_ONLY_SG }
    fw = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                .first['resource']['networkInterface'].dig('accessRestriction', 'l3Firewall')
    assert_equal ['10.8.0.0/256'], fw['allowedSources'],
                 'only the rule covering a management port feeds allowedSources'
  end

  def test_nic_allowed_sources_marks_open_rule_as_any
    sg_map = { '0' => OPEN_SG, '1' => HTTPS_ONLY_SG }
    fw = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                .first['resource']['networkInterface'].dig('accessRestriction', 'l3Firewall')
    assert_equal ['0.0.0.0/0'], fw['allowedSources']
  end

  def test_nic_allowed_sources_vnet_scoped_rule
    sg_map = { '0' => VNET_RDP_SG, '1' => HTTPS_ONLY_SG }
    fw = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                .first['resource']['networkInterface'].dig('accessRestriction', 'l3Firewall')
    assert_equal ['vnet:7'], fw['allowedSources']
  end

  def test_nic_allowed_sources_empty_when_no_rule_touches_management_ports
    sg_map = { '0' => HTTPS_ONLY_SG, '1' => HTTPS_ONLY_SG }
    fw = @mapper.map_nics(File.read(fixture('vm_template.xml')), sg_xml_by_id: sg_map)
                .first['resource']['networkInterface'].dig('accessRestriction', 'l3Firewall')
    assert_equal [], fw['allowedSources']
  end

  def test_nic_without_security_groups_reports_firewall_disabled
    # No SECURITY_GROUPS at all is the worst case, not "does not apply":
    # emit enabled=false so the metric fails the interface honestly.
    xml = File.read(fixture('vm_template.xml'))
            .sub(%r{<SECURITY_GROUPS>[^<]*</SECURITY_GROUPS>}, '')
    nic = @mapper.map_nics(xml).first['resource']['networkInterface']
    fw = nic.fetch('accessRestriction').fetch('l3Firewall')
    assert_equal false, fw['enabled']
    assert_equal [], fw['restrictedPorts']
  end

  # --- Image mapping ---

  def test_map_image_basic
    evidence = @mapper.map_image(File.read(fixture('image_template.xml')))
    img = evidence['resource']['vmImage']
    assert_equal 'one-image-5', img['id']
    assert_equal 'Ubuntu-22.04', img['name']
    assert_match(/^\d{4}-\d{2}-\d{2}T/, img['creationTime'])
  end

  def test_map_image_public_access_is_a_label_not_a_typed_field
    # confirmate.ontology.v1.VMImage has no `publicAccess` field; it is emitted
    # as a label so the Evidence Store never sees an unknown field.
    evidence = @mapper.map_image(File.read(fixture('image_template.xml')))
    img = evidence['resource']['vmImage']
    refute img.key?('publicAccess'), 'publicAccess is not a VMImage ontology field'
    assert_equal 'false', img['labels']['publicAccess']
  end

  # --- VirtualNetwork mapping ---

  def test_map_network_basic
    xml = '<VNET><ID>9</ID><NAME>backbone</NAME></VNET>'
    evidence = @mapper.map_network(xml)
    vnet = evidence['resource']['virtualNetwork']
    assert_equal 'one-vnet-9', vnet['id']
    assert_equal 'backbone', vnet['name']
    assert_equal 'eu-south-1', vnet['geoLocation']['region']
    assert_equal TOE_UUID, evidence['targetOfEvaluationId']
  end

  # --- Determinism and serialization ---

  def test_evidence_id_is_strict_rfc4122_uuid_v5
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    # version nibble must be 5, variant must be RFC 4122 (8/9/a/b)
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
                 evidence['id'])
  end

  def test_evidence_id_is_deterministic_for_same_key_and_timestamp
    a = @mapper.send(:generate_uuid, 'vm-42', '2026-01-01T00:00:00Z')
    b = @mapper.send(:generate_uuid, 'vm-42', '2026-01-01T00:00:00Z')
    c = @mapper.send(:generate_uuid, 'vm-42', '2026-01-01T00:00:01Z')
    assert_equal a, b, 'same resource + same second => same evidence id'
    refute_equal a, c, 'different timestamp => different evidence id'
  end

  def test_raw_xml_is_truncated_to_10k_chars
    big = File.read(fixture('vm_template.xml')).sub('</VM>', "<PAD>#{'x' * 20_000}</PAD></VM>")
    evidence = @mapper.map_vm(big)
    assert_equal 10_000, evidence['resource']['virtualMachine']['raw'].length
  end

  def test_evidence_is_json_serializable
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    json = JSON.generate(evidence)
    assert_equal evidence, JSON.parse(json)
  end

  # --- Identity (AdminMFAEnabled, CIS 4.5 / AIM-02) ---

  def test_identity_admin_with_second_factor_is_privileged_and_enforces_mfa
    ev = @mapper.map_identity(File.read(fixture('user_admin_mfa.xml')))
    id = ev['resource']['identity']
    assert_equal 'one-user-2', id['id']
    assert_equal true, id['privileged'],  'membership of GID 0 (oneadmin) means privileged'
    assert_equal true, id['enforceMfa'],  'a FIREEDGE TWO_FACTOR_AUTH_SECRET means a second factor is enrolled'
    assert_equal true, id['activated']
  end

  def test_identity_admin_without_second_factor_reports_false_not_missing
    ev = @mapper.map_identity(File.read(fixture('user_admin_no_mfa.xml')))
    id = ev['resource']['identity']
    assert_equal true,  id['privileged']
    assert_equal false, id['enforceMfa'],
                 'absent secret must be an explicit false, so the metric can fail it'
  end

  def test_identity_field_is_enforceMfa_as_the_ontology_serialises_it
    ev = @mapper.map_identity(File.read(fixture('user_admin_mfa.xml')))
    id = ev['resource']['identity']
    assert id.key?('enforceMfa'), 'Identity.enforce_mfa has json_name=enforceMfa'
    refute id.key?('enforceMFA'), 'enforceMFA is not an ontology field name'
  end

  def test_identity_skips_the_serveradmin_service_account
    assert_nil @mapper.map_identity(File.read(fixture('user_serveradmin.xml'))),
               'server_cipher is OpenNebula internal auth, not a human administrator'
  end

  def test_identity_labels_carry_the_auth_driver_for_federation
    ev = @mapper.map_identity(File.read(fixture('user_admin_mfa.xml')))
    labels = ev['resource']['identity']['labels']
    assert_equal 'core',  labels['authDriver']
    assert_equal 'false', labels['federated'], 'core is a local account, not federated'
  end

  def test_identity_evidence_uses_the_standard_envelope
    ev = @mapper.map_identity(File.read(fixture('user_admin_mfa.xml')))
    assert_equal TOE_UUID, ev['targetOfEvaluationId']
    assert ev['resource']['identity'].key?('raw'), 'raw XML must be attached'
  end

  # --- BlockStorage (VirtualMachineDiskEncryptionEnabled, CIS 4.3) ---

  def test_block_storage_ids_match_the_ones_the_vm_advertises
    vm_xml = File.read(fixture('vm_template.xml'))
    vm_ids = @mapper.map_vm(vm_xml)['resource']['virtualMachine']['blockStorageIds']
    disk_ids = @mapper.map_block_storages(vm_xml).map { |e| e['resource']['blockStorage']['id'] }
    assert_equal vm_ids.sort, disk_ids.sort,
                 'Confirmate resolves vm.related through these ids; they must line up exactly'
  end

  def test_block_storage_reports_customer_key_encryption
    ev = @mapper.map_block_storages(File.read(fixture('vm_template.xml'))).first
    enc = ev['resource']['blockStorage']['atRestEncryption']
    assert enc.key?('customerKeyEncryption'),
           'the metric reads atRestEncryption.customerKeyEncryption.enabled'
    assert [true, false].include?(enc['customerKeyEncryption']['enabled'])
  end

  def test_block_storage_of_an_unencrypted_vm_is_explicitly_false
    ev = @mapper.map_block_storages(File.read(fixture('vm_no_encryption.xml'))).first
    refute_nil ev, 'a VM with disks must still produce BlockStorage evidence'
    assert_equal false, ev['resource']['blockStorage']['atRestEncryption']['customerKeyEncryption']['enabled']
  end

  def test_block_storage_points_back_at_its_vm
    ev = @mapper.map_block_storages(File.read(fixture('vm_template.xml'))).first
    assert_match(/\Aone-vm-/, ev['resource']['blockStorage']['parentId'])
  end



  # --- Datastore (ObjectStorage) --------------------------------------------

  def test_map_datastore_reports_private_when_other_u_is_zero
    evidence = @mapper.map_datastore(File.read(fixture('datastore_private.xml')))
    storage  = evidence['resource']['objectStorage']

    assert_equal false, storage['publicAccess']
    assert_equal 'one-datastore-1', storage['id']
    assert_equal 'default', storage['name']
  end

  def test_map_datastore_reports_public_when_other_u_is_set
    evidence = @mapper.map_datastore(File.read(fixture('datastore_public.xml')))

    assert_equal true, evidence['resource']['objectStorage']['publicAccess']
  end

  def test_map_datastore_carries_remaining_permission_bits_as_labels
    evidence = @mapper.map_datastore(File.read(fixture('datastore_private.xml')))
    labels   = evidence['resource']['objectStorage']['labels']

    assert_equal '0', labels['otherManage']
    assert_equal '0', labels['otherAdmin']
  end

  # --- BlockStorage backups -------------------------------------------------

  def test_block_storage_reports_no_backup_when_the_backups_block_is_empty
    evidence = @mapper.map_block_storages(File.read(fixture('vm_no_backup.xml')))

    assert_equal [{ 'enabled' => false }], evidence.first['resource']['blockStorage']['backups']
  end

  def test_block_storage_backup_config_alone_does_not_count
    # Strict reading: a policy that never ran protects nothing. The fixture
    # has BACKUP_CONFIG populated and BACKUP_IDS empty.
    evidence = @mapper.map_block_storages(File.read(fixture('vm_with_backup.xml')))
    assert_equal [{ 'enabled' => false }], evidence.first['resource']['blockStorage']['backups']
  end

  def test_block_storage_reports_a_backup_when_one_has_run
    xml = File.read(fixture('vm_with_backup.xml'))
            .sub('<BACKUP_IDS/>', '<BACKUP_IDS><ID>42</ID></BACKUP_IDS>')
    evidence = @mapper.map_block_storages(xml)

    assert_equal [{ 'enabled' => true }], evidence.first['resource']['blockStorage']['backups']
  end


  private

  def fixture(name)
    File.join(File.dirname(__FILE__), 'fixtures', name)
  end
end
