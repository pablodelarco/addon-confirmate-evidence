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

  # --- NIC mapping ---

  def test_map_nics_count
    evidences = @mapper.map_nics(File.read(fixture('vm_template.xml')))
    assert_equal 2, evidences.length
  end

  def test_map_nic_internet_accessible_endpoint
    evidences = @mapper.map_nics(File.read(fixture('vm_template.xml')))
    nic0 = evidences[0]['resource']['networkInterface']
    nic1 = evidences[1]['resource']['networkInterface']
    # The 10.0.0.100 NIC has EXTERNAL=YES; the 192.168.x one does not.
    assert_includes [true, false], nic0['internetAccessibleEndpoint']
    assert_includes [true, false], nic1['internetAccessibleEndpoint']
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

  # --- Determinism and serialization ---

  def test_evidence_id_is_uuid_v5_shape
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    assert_match(/^[0-9a-f-]{36}$/, evidence['id'])
  end

  def test_evidence_is_json_serializable
    evidence = @mapper.map_vm(File.read(fixture('vm_template.xml')))
    json = JSON.generate(evidence)
    assert_equal evidence, JSON.parse(json)
  end

  private

  def fixture(name)
    File.join(File.dirname(__FILE__), 'fixtures', name)
  end
end
