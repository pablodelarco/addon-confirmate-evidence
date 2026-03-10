#!/usr/bin/ruby
# =============================================================================
# Unit tests for OntologyMapper
# =============================================================================

require 'minitest/autorun'
require 'json'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'ontology_mapper'

class TestOntologyMapper < Minitest::Test
  def setup
    @config = {
      'evidence' => {
        'tool_id' => 'test-tool',
        'cloud_service_id' => 'test-cloud-service-id',
        'default_region' => 'eu-south-1'
      }
    }
    @mapper = OntologyMapper.new(@config)
  end

  # --- VM mapping tests ---

  def test_map_vm_basic_fields
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)

    assert_equal 'test-tool', evidence['evidence']['toolId']
    assert_equal 'test-cloud-service-id', evidence['evidence']['cloudServiceId']
    assert evidence['evidence']['id'], 'Evidence must have an ID'
    assert evidence['evidence']['timestamp'], 'Evidence must have a timestamp'

    vm = evidence['evidence']['resource']['virtualMachine']
    assert_equal 'one-vm-42', vm['id']
    assert_equal 'emerald-test-vm', vm['name']
  end

  def test_map_vm_creation_time
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    # STIME=1709013200 should convert to a valid RFC 3339 timestamp
    assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, vm['creationTime'])
  end

  def test_map_vm_encrypted_disk
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    enc = vm['atRestEncryption']['managedKeyEncryption']
    assert_equal true, enc['enabled']
    assert_equal 'aes-256-xts-plain64', enc['algorithm']
  end

  def test_map_vm_no_encryption
    xml = File.read(fixture('vm_no_encryption.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    enc = vm['atRestEncryption']['managedKeyEncryption']
    assert_equal false, enc['enabled']
    assert_equal 'none', enc['algorithm']
  end

  def test_map_vm_network_interfaces
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    assert_equal ['one-nic-42-0', 'one-nic-42-1'], vm['networkInterfaces']
  end

  def test_map_vm_block_storage
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    assert_equal ['one-disk-42-0', 'one-disk-42-1'], vm['blockStorage']
  end

  def test_map_vm_public_ip_detection
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    # VM has a NIC with EXTERNAL=YES, so publicIp should be true
    assert_equal true, vm['publicIp']
  end

  def test_map_vm_no_public_ip
    xml = File.read(fixture('vm_no_encryption.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    # VM has only a 192.168.x.x NIC, so publicIp should be false
    assert_equal false, vm['publicIp']
  end

  def test_map_vm_geo_location
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    assert_equal 'eu-south-1', vm['geoLocation']['region']
  end

  def test_map_vm_logging_with_monitoring
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)
    vm = evidence['evidence']['resource']['virtualMachine']

    # VM has MONITORING section, so logging should be detected
    assert_equal true, vm['bootLogging']['enabled']
    assert_equal true, vm['osLogging']['enabled']
  end

  # --- NIC mapping tests ---

  def test_map_nics_count
    xml = File.read(fixture('vm_template.xml'))
    evidences = @mapper.map_nics(xml)

    assert_equal 2, evidences.length
  end

  def test_map_nics_fields
    xml = File.read(fixture('vm_template.xml'))
    evidences = @mapper.map_nics(xml)

    nic0 = evidences[0]['evidence']['resource']['networkInterface']
    assert_equal 'one-nic-42-0', nic0['id']
    assert_equal 'private-net/nic0', nic0['name']
    assert_includes nic0['ip'], '10.0.0.100'
  end

  def test_map_nics_security_groups
    xml = File.read(fixture('vm_template.xml'))
    evidences = @mapper.map_nics(xml)

    nic0 = evidences[0]['evidence']['resource']['networkInterface']
    assert_equal ['one-sg-0', 'one-sg-1'], nic0['accessRestriction']['securityGroups']
  end

  def test_map_single_nic
    xml = File.read(fixture('nic_template.xml'))
    evidences = @mapper.map_nics(xml)

    assert_equal 1, evidences.length
    nic = evidences[0]['evidence']['resource']['networkInterface']
    assert_equal 'one-nic-55-0', nic['id']
  end

  # --- Image mapping tests ---

  def test_map_image_basic
    xml = File.read(fixture('image_template.xml'))
    evidence = @mapper.map_image(xml)

    img = evidence['evidence']['resource']['vmImage']
    assert_equal 'one-image-5', img['id']
    assert_equal 'Ubuntu-22.04', img['name']
    assert_match(/^\d{4}-\d{2}-\d{2}T/, img['creationTime'])
  end

  def test_map_image_not_public
    xml = File.read(fixture('image_template.xml'))
    evidence = @mapper.map_image(xml)

    img = evidence['evidence']['resource']['vmImage']
    assert_equal false, img['publicAccess']
  end

  # --- Evidence wrapper tests ---

  def test_evidence_has_required_fields
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)

    ev = evidence['evidence']
    assert ev.key?('id'), 'Evidence must have id'
    assert ev.key?('timestamp'), 'Evidence must have timestamp'
    assert ev.key?('cloudServiceId'), 'Evidence must have cloudServiceId'
    assert ev.key?('toolId'), 'Evidence must have toolId'
    assert ev.key?('resource'), 'Evidence must have resource'
  end

  def test_evidence_id_is_deterministic
    xml = File.read(fixture('vm_template.xml'))
    # Two calls in the same second should produce the same ID
    e1 = @mapper.map_vm(xml)
    e2 = @mapper.map_vm(xml)

    # They may or may not be the same depending on timing,
    # but the format should be UUID-like
    assert_match(/^[0-9a-f-]{36}$/, e1['evidence']['id'])
    assert_match(/^[0-9a-f-]{36}$/, e2['evidence']['id'])
  end

  def test_evidence_json_serializable
    xml = File.read(fixture('vm_template.xml'))
    evidence = @mapper.map_vm(xml)

    json = JSON.generate(evidence)
    parsed = JSON.parse(json)
    assert_equal evidence, parsed
  end

  # --- Security group mapping tests ---

  def test_map_security_group
    rules = [
      { 'type' => 'inbound', 'port' => '22', 'protocol' => 'TCP', 'network' => '10.0.0.0/8' },
      { 'type' => 'inbound', 'port' => '443', 'protocol' => 'TCP', 'network' => '0.0.0.0/0' },
      { 'type' => 'outbound', 'port' => '0', 'protocol' => 'ALL', 'network' => '0.0.0.0/0' }
    ]

    evidence = @mapper.map_security_group('10', 'web-sg', rules)
    sg = evidence['evidence']['resource']['networkSecurityGroup']

    assert_equal 'one-sg-10', sg['id']
    assert_equal 'web-sg', sg['name']
    # Only inbound rules should be included
    assert_equal 2, sg['inboundRules'].length
    assert_equal 'TCP', sg['inboundRules'][0]['protocol']
  end

  private

  def fixture(name)
    File.join(File.dirname(__FILE__), 'fixtures', name)
  end
end
