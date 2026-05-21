# =============================================================================
# OntologyMapper - Maps OpenNebula XML to Confirmate ontology JSON
# =============================================================================
# Transforms OpenNebula resource representations (XML from hook $TEMPLATE)
# into Confirmate's ontology-based evidence format for the Evidence Store.
#
# Supported resource types (confirmate.ontology.v1):
#   - VirtualMachine  (from ONE VM XML)
#   - NetworkInterface (from NIC elements within VM XML)
#   - VMImage         (from ONE Image XML)
#   - VirtualNetwork  (from ONE Virtual Network XML)
#
# Part of addon-confirmate-evidence (EMERALD project)
# =============================================================================

require 'rexml/document'
require 'time'
require 'digest'
require 'securerandom'
require 'json'

# Maps OpenNebula resource XML documents to Confirmate ontology JSON structures.
#
# Uses deterministic UUID v5 generation so that the same resource at the same
# timestamp always produces the same evidence ID (idempotency).
class OntologyMapper
  # UUID namespace for generating deterministic evidence IDs (UUID v5)
  NAMESPACE_UUID = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'

  # @param config [Hash] parsed YAML configuration
  def initialize(config)
    @config = config
    @tool_id = config.dig('evidence', 'tool_id') || 'opennebula-addon-confirmate-evidence'
    # In Confirmate the evidence field is `target_of_evaluation_id`. Accept the
    # old `cloud_service_id` key only as a transient back-compat read so an
    # operator who upgrades the addon before editing the config still gets a
    # working install (with a warning); shape changes happen in the wrap.
    @target_of_evaluation_id = config.dig('evidence', 'target_of_evaluation_id') \
      || config.dig('evidence', 'cloud_service_id') \
      || '00000000-0000-0000-0000-000000000000'
    @default_region = config.dig('evidence', 'default_region') || 'eu-south-1'
  end

  # Maps a full ONE VM XML document to a VirtualMachine evidence payload.
  #
  # @param xml_str [String] OpenNebula VM XML (decoded from Base64)
  # @return [Hash] evidence payload ready for ClouditorClient#store_evidence
  def map_vm(xml_str)
    doc = REXML::Document.new(xml_str)
    vm = doc.root

    vm_id = text(vm, 'ID')
    vm_name = text(vm, 'NAME')
    stime = text(vm, 'STIME')
    creation_time = epoch_to_rfc3339(stime)

    # Collect NIC references
    nic_ids = []
    nics = collect_elements(vm, 'TEMPLATE/NIC')
    nics.each do |nic|
      nic_id = text(nic, 'NIC_ID') || '0'
      nic_ids << "one-nic-#{vm_id}-#{nic_id}"
    end

    # Collect disk/block storage references
    disk_ids = []
    disks = collect_elements(vm, 'TEMPLATE/DISK')
    disks.each do |disk|
      disk_id = text(disk, 'DISK_ID') || '0'
      disk_ids << "one-disk-#{vm_id}-#{disk_id}"
    end

    # Determine at-rest encryption from disks
    encryption = extract_encryption(disks)

    # Check for public IP exposure
    has_public_ip = nics.any? { |nic| public_nic?(nic) }

    # Build ontology resource
    resource = {
      'virtualMachine' => {
        'id' => "one-vm-#{vm_id}",
        'name' => vm_name,
        'creationTime' => creation_time,
        'geoLocation' => {
          'region' => @default_region
        },
        'networkInterfaces' => nic_ids,
        'blockStorage' => disk_ids,
        'atRestEncryption' => encryption,
        'bootLogging' => {
          'enabled' => logging_enabled?(vm)
        },
        'osLogging' => {
          'enabled' => logging_enabled?(vm)
        },
        'autoUpdates' => {
          'enabled' => false
        },
        'publicIp' => has_public_ip
      }
    }

    wrap_evidence("vm-#{vm_id}", resource, xml_str)
  end

  # Maps NIC elements from a VM XML to NetworkInterface evidence payloads.
  #
  # @param xml_str [String] OpenNebula VM XML (decoded from Base64)
  # @return [Array<Hash>] list of evidence payloads, one per NIC
  def map_nics(xml_str)
    doc = REXML::Document.new(xml_str)
    vm = doc.root

    vm_id = text(vm, 'ID')
    nics = collect_elements(vm, 'TEMPLATE/NIC')

    nics.map do |nic|
      nic_id = text(nic, 'NIC_ID') || '0'
      ip = text(nic, 'IP') || ''
      network_name = text(nic, 'NETWORK') || ''

      resource = {
        'networkInterface' => {
          'id' => "one-nic-#{vm_id}-#{nic_id}",
          'name' => "#{network_name}/nic#{nic_id}",
          'ip' => [ip],
          'accessRestriction' => extract_nic_access(nic)
        }
      }

      wrap_evidence("nic-#{vm_id}-#{nic_id}", resource, xml_str)
    end
  end

  # Maps an ONE Image XML document to a VMImage evidence payload.
  #
  # @param xml_str [String] OpenNebula Image XML (decoded from Base64)
  # @return [Hash] evidence payload
  def map_image(xml_str)
    doc = REXML::Document.new(xml_str)
    img = doc.root

    img_id = text(img, 'ID')
    img_name = text(img, 'NAME')
    regtime = text(img, 'REGTIME')
    creation_time = epoch_to_rfc3339(regtime)

    # Check if image is public
    permissions = img.elements['PERMISSIONS']
    public_access = false
    if permissions
      other_use = text(permissions, 'OTHER_U')
      public_access = (other_use == '1')
    end

    resource = {
      'vmImage' => {
        'id' => "one-image-#{img_id}",
        'name' => img_name,
        'creationTime' => creation_time,
        'publicAccess' => public_access
      }
    }

    wrap_evidence("image-#{img_id}", resource, xml_str)
  end

  # Maps an ONE Virtual Network XML document to a VirtualNetwork evidence payload.
  #
  # @param xml_str [String] OpenNebula VNet XML (decoded from Base64)
  # @return [Hash] evidence payload
  def map_network(xml_str)
    doc = REXML::Document.new(xml_str)
    vnet = doc.root

    vnet_id = text(vnet, 'ID')
    vnet_name = text(vnet, 'NAME')

    resource = {
      'virtualNetwork' => {
        'id' => "one-vnet-#{vnet_id}",
        'name' => vnet_name,
        'geoLocation' => {
          'region' => @default_region
        }
      }
    }

    wrap_evidence("vnet-#{vnet_id}", resource, xml_str)
  end

  # Maps Security Group rules to a NetworkSecurityGroup evidence payload.
  #
  # @param sg_id [String] Security Group ID
  # @param sg_name [String] Security Group name
  # @param rules [Array<Hash>] parsed security group rules
  # @return [Hash] evidence payload
  def map_security_group(sg_id, sg_name, rules)
    inbound_rules = rules.select { |r| r['type'] == 'inbound' }.map do |rule|
      {
        'portRange' => rule['range'] || "#{rule['port']}-#{rule['port']}",
        'protocol' => rule['protocol'] || 'TCP',
        'cidr' => rule['network'] || '0.0.0.0/0'
      }
    end

    resource = {
      'networkSecurityGroup' => {
        'id' => "one-sg-#{sg_id}",
        'name' => sg_name,
        'inboundRules' => inbound_rules
      }
    }

    wrap_evidence("sg-#{sg_id}", resource, nil)
  end

  private

  # Wraps a mapped ontology resource into a complete evidence payload.
  #
  # @param resource_key [String] unique key for deterministic UUID generation
  # @param resource [Hash] ontology resource object
  # @param raw_xml [String, nil] original XML for the raw field
  # @return [Hash] complete evidence payload
  def wrap_evidence(resource_key, resource, raw_xml)
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    evidence_id = generate_uuid(resource_key, timestamp)

    evidence = {
      'evidence' => {
        'id' => evidence_id,
        'timestamp' => timestamp,
        'cloudServiceId' => @target_of_evaluation_id,
        'toolId' => @tool_id,
        'resource' => resource
      }
    }

    if raw_xml
      evidence['evidence']['raw'] = raw_xml.length > 10_000 ? raw_xml[0..9999] : raw_xml
    end

    evidence
  end

  # Generates a deterministic UUID v5 from a resource key and timestamp.
  # Ensures idempotency: same resource + same second = same evidence ID.
  #
  # @param resource_key [String] e.g., "vm-42"
  # @param timestamp [String] RFC 3339 timestamp
  # @return [String] UUID string
  def generate_uuid(resource_key, timestamp)
    name = "#{resource_key}:#{timestamp}"
    Digest::UUID.uuid_v5(NAMESPACE_UUID, name)
  rescue NoMethodError
    # Fallback: manual UUID v5 using SHA1
    sha1 = Digest::SHA1.hexdigest("#{NAMESPACE_UUID}:#{name}")
    [
      sha1[0..7],
      sha1[8..11],
      '5' + sha1[13..15],  # Version 5
      ((sha1[16..17].to_i(16) & 0x3F) | 0x80).to_s(16).rjust(2, '0') + sha1[18..19],
      sha1[20..31]
    ].join('-')
  end

  # Extracts at-rest encryption info from VM disk elements.
  #
  # @param disks [Array<REXML::Element>] disk elements
  # @return [Hash] encryption ontology object
  def extract_encryption(disks)
    encrypted_disk = disks.find { |d| text(d, 'ENCRYPT')&.upcase == 'YES' }

    if encrypted_disk
      algorithm = text(encrypted_disk, 'CIPHER') || 'AES256'
      {
        'managedKeyEncryption' => {
          'algorithm' => algorithm,
          'enabled' => true
        }
      }
    else
      {
        'managedKeyEncryption' => {
          'algorithm' => 'none',
          'enabled' => false
        }
      }
    end
  end

  # Checks if a NIC has a public (non-RFC1918) IP address.
  #
  # @param nic [REXML::Element] NIC element
  # @return [Boolean] true if NIC has a public IP
  def public_nic?(nic)
    return true if text(nic, 'EXTERNAL')&.upcase == 'YES'

    ip = text(nic, 'IP')
    return false if ip.nil? || ip.empty?

    !private_ip?(ip)
  end

  # Determines whether an IP address is in RFC 1918 private ranges.
  #
  # @param ip [String] IPv4 address
  # @return [Boolean] true if private
  def private_ip?(ip)
    octets = ip.split('.').map(&:to_i)
    return true if octets.length != 4

    # 10.0.0.0/8
    return true if octets[0] == 10
    # 172.16.0.0/12
    return true if octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31
    # 192.168.0.0/16
    return true if octets[0] == 192 && octets[1] == 168
    # Loopback
    return true if octets[0] == 127

    false
  end

  # Extracts access restriction info from a NIC element.
  # In a full deployment, this would query Security Groups via the ONE API.
  #
  # @param nic [REXML::Element] NIC element
  # @return [Hash] access restriction info
  def extract_nic_access(nic)
    sg_ids = text(nic, 'SECURITY_GROUPS')
    if sg_ids && !sg_ids.empty?
      {
        'securityGroups' => sg_ids.split(',').map { |id| "one-sg-#{id.strip}" }
      }
    else
      {
        'securityGroups' => []
      }
    end
  end

  # Checks if VM has logging enabled (heuristic based on template attributes).
  #
  # @param vm [REXML::Element] VM root element
  # @return [Boolean]
  def logging_enabled?(vm)
    # Check for LOG section in USER_TEMPLATE or TEMPLATE
    log_elem = vm.elements['USER_TEMPLATE/LOG'] || vm.elements['TEMPLATE/LOG']
    return true if log_elem

    # Check for monitoring enabled
    monitoring = vm.elements['MONITORING']
    return true if monitoring && monitoring.elements.size > 0

    false
  end

  # Extracts text content from an XML element by XPath.
  #
  # @param element [REXML::Element] parent element
  # @param xpath [String] XPath expression
  # @return [String, nil] text content or nil
  def text(element, xpath)
    el = element.elements[xpath]
    el&.text
  end

  # Collects all matching elements (handles single element or array in ONE XML).
  # OpenNebula XML may have a single <NIC> or multiple <NIC> elements.
  #
  # @param element [REXML::Element] parent element
  # @param xpath [String] XPath to match
  # @return [Array<REXML::Element>] list of matching elements
  def collect_elements(element, xpath)
    results = []
    element.each_element(xpath) { |el| results << el }
    results
  end
end
