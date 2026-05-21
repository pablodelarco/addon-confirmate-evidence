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
  # Field mapping vs confirmate.ontology.v1.VirtualMachine:
  #   - networkInterfaceIds: array of NIC IDs (was networkInterfaces objects)
  #   - blockStorageIds: array of disk IDs (was blockStorage objects)
  #   - automaticUpdates: renamed from autoUpdates
  #   - internetAccessibleEndpoint: renamed from publicIp
  #   - atRestEncryption: removed (no longer a VM-level field); the algorithm
  #     and enabled flag remain available in the raw XML, see MIGRATION.md OQ-2
  #
  # @param xml_str [String] OpenNebula VM XML (decoded from Base64)
  # @return [Hash] evidence payload ready for ConfirmateClient#store_evidence
  def map_vm(xml_str)
    doc = REXML::Document.new(xml_str)
    vm = doc.root

    vm_id = text(vm, 'ID')
    vm_name = text(vm, 'NAME')
    stime = text(vm, 'STIME')
    creation_time = epoch_to_rfc3339(stime)

    # Collect NIC references (IDs only — NICs are submitted as separate evidence)
    nic_ids = collect_elements(vm, 'TEMPLATE/NIC').map do |nic|
      "one-nic-#{vm_id}-#{text(nic, 'NIC_ID') || '0'}"
    end

    # Collect disk/block storage references (IDs only)
    disk_ids = collect_elements(vm, 'TEMPLATE/DISK').map do |disk|
      "one-disk-#{vm_id}-#{text(disk, 'DISK_ID') || '0'}"
    end

    # Internet-accessible if any NIC is reachable from outside (was publicIp)
    has_public_ip = collect_elements(vm, 'TEMPLATE/NIC').any? { |nic| public_nic?(nic) }

    resource = {
      'virtualMachine' => {
        'id' => "one-vm-#{vm_id}",
        'name' => vm_name,
        'creationTime' => creation_time,
        'geoLocation' => { 'region' => @default_region },
        'networkInterfaceIds' => nic_ids,
        'blockStorageIds' => disk_ids,
        'bootLogging' => { 'enabled' => logging_enabled?(vm) },
        'osLogging' => { 'enabled' => logging_enabled?(vm) },
        'automaticUpdates' => { 'enabled' => false },
        'internetAccessibleEndpoint' => has_public_ip
      }
    }

    wrap_evidence("vm-#{vm_id}", resource, xml_str)
  end

  # Maps NIC elements from a VM XML to NetworkInterface evidence payloads.
  #
  # confirmate.ontology.v1.NetworkInterface has no first-class fields for IP
  # address or security group membership; both are emitted as labels (a
  # map<string,string>) so they remain queryable. The boolean
  # `internetAccessibleEndpoint` replaces the previous publicIp/EXTERNAL check.
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
      sg_ids = text(nic, 'SECURITY_GROUPS') || ''

      labels = {}
      labels['ip'] = ip unless ip.empty?
      labels['network'] = network_name unless network_name.empty?
      labels['securityGroupIds'] = sg_ids unless sg_ids.empty?

      resource = {
        'networkInterface' => {
          'id' => "one-nic-#{vm_id}-#{nic_id}",
          'name' => "#{network_name}/nic#{nic_id}",
          'labels' => labels,
          'internetAccessibleEndpoint' => public_nic?(nic)
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

  # Wraps a mapped ontology resource into a complete Confirmate Evidence payload.
  #
  # On-the-wire shape (matches the StoreEvidence REST body annotation
  # `body: "evidence"` in evidence_store.proto:30-35):
  #
  #   {
  #     "id": "<uuid>",
  #     "timestamp": "<RFC3339>",
  #     "targetOfEvaluationId": "<uuid>",
  #     "toolId": "<string>",
  #     "resource": { "<lowerCamelOntologyType>": { ..., "raw": "<xml>" } }
  #   }
  #
  # In Confirmate, `raw` lives on each ontology message (e.g.
  # VirtualMachine.raw at proto field 14073), not on the Evidence itself.
  #
  # @param resource_key [String] unique key for deterministic UUID generation
  # @param resource [Hash] ontology resource object keyed by lowerCamel type
  # @param raw_xml [String, nil] original XML payload, attached to the resource
  # @return [Hash] complete Evidence payload (to be POSTed as the HTTP body)
  def wrap_evidence(resource_key, resource, raw_xml)
    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    evidence_id = generate_uuid(resource_key, timestamp)

    if raw_xml
      type_key = resource.keys.first
      truncated = raw_xml.length > 10_000 ? raw_xml[0..9999] : raw_xml
      resource[type_key]['raw'] = truncated
    end

    {
      'id' => evidence_id,
      'timestamp' => timestamp,
      'targetOfEvaluationId' => @target_of_evaluation_id,
      'toolId' => @tool_id,
      'resource' => resource
    }
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
  rescue NoMethodError, LoadError, NameError
    # Fallback when Digest::UUID is unavailable (e.g., stock Ruby 2.6):
    # manual UUID v5 using SHA1, per RFC 4122 §4.3.
    sha1 = Digest::SHA1.hexdigest("#{NAMESPACE_UUID}:#{name}")
    [
      sha1[0..7],
      sha1[8..11],
      '5' + sha1[13..15],  # Version 5
      ((sha1[16..17].to_i(16) & 0x3F) | 0x80).to_s(16).rjust(2, '0') + sha1[18..19],
      sha1[20..31]
    ].join('-')
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

  # Converts an OpenNebula epoch timestamp (seconds since 1970 as a string)
  # to an RFC 3339 UTC datetime. Returns nil on missing/zero/invalid input.
  #
  # @param epoch_str [String, nil] e.g. "1709013200"
  # @return [String, nil] RFC 3339 timestamp or nil
  def epoch_to_rfc3339(epoch_str)
    return nil if epoch_str.nil? || epoch_str.empty?

    secs = epoch_str.to_i
    return nil if secs <= 0

    Time.at(secs).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
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
