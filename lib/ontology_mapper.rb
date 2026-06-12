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
require 'json'

# Maps OpenNebula resource XML documents to Confirmate ontology JSON structures.
#
# Uses deterministic UUID v5 generation so that the same resource at the same
# timestamp always produces the same evidence ID (idempotency).
class OntologyMapper
  # UUID namespace for generating deterministic evidence IDs (UUID v5)
  NAMESPACE_UUID = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'

  # All-zeros ToE: a placeholder the orchestrator rejects with
  # "target of evaluation not found". Must never be sent.
  PLACEHOLDER_TOE = '00000000-0000-0000-0000-000000000000'

  # RFC 4122 canonical UUID shape (any version)
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # @param config [Hash] parsed YAML configuration
  def initialize(config)
    @config = config
    @tool_id = config.dig('evidence', 'tool_id') || 'opennebula-addon-confirmate-evidence'
    # In Confirmate the evidence field is `target_of_evaluation_id`. Accept the
    # old `cloud_service_id` key only as a transient back-compat read so an
    # operator who upgrades the addon before editing the config still gets a
    # working install; shape changes happen in the wrap.
    @target_of_evaluation_id = config.dig('evidence', 'target_of_evaluation_id') \
      || config.dig('evidence', 'cloud_service_id')
    # Coerce non-String YAML values (numbers, hashes from typos) so the guard
    # below reports the curated message instead of a NoMethodError.
    @target_of_evaluation_id = @target_of_evaluation_id.to_s unless @target_of_evaluation_id.nil?

    # Fail fast on a missing or malformed ToE: those can never be accepted by
    # any orchestrator. Without this the addon would POST evidence that is
    # silently rejected, and because each hook swallows errors and exits 0 the
    # operator would never see why.
    if @target_of_evaluation_id.nil? || @target_of_evaluation_id.empty? \
       || !@target_of_evaluation_id.match?(UUID_FORMAT)
      raise "evidence.target_of_evaluation_id is unset or not a UUID " \
            "(#{@target_of_evaluation_id.inspect}). Paste the real ToE UUID " \
            "from the EMERALD UI into confirmate-evidence.conf."
    end

    # The all-zeros UUID is the shipped placeholder. It is a *valid* ToE only
    # against a local orchestrator started with --create-default-target-of-
    # evaluation; against any real deployment the orchestrator rejects it. Warn
    # loudly (stderr is captured into the hook log) so an operator who forgot to
    # set it understands why every evidence is being rejected.
    if @target_of_evaluation_id == PLACEHOLDER_TOE
      warn 'confirmate-evidence: WARNING evidence.target_of_evaluation_id is the ' \
           'all-zeros placeholder; this only works against a local default ' \
           'orchestrator. Set the real ToE UUID for any real deployment.'
    end

    @default_region = config.dig('evidence', 'default_region') || 'eu-south-1'
  end

  # Maps a full ONE VM XML document to a VirtualMachine evidence payload.
  #
  # Field mapping vs confirmate.ontology.v1.VirtualMachine:
  #   - networkInterfaceIds: array of NIC IDs (was networkInterfaces objects)
  #   - blockStorageIds: array of disk IDs (was blockStorage objects)
  #   - automaticUpdates: renamed from autoUpdates
  #   - internetAccessibleEndpoint: renamed from publicIp
  #   - atRestEncryption: removed (no longer a VM-level field in
  #     confirmate.ontology.v1); the algorithm and enabled flag remain
  #     available in the attached raw XML.
  #
  # @param xml_str [String] OpenNebula VM XML (decoded from Base64)
  # @param sg_xml_by_id [Hash] optional {sgId => `onesecgroup show -x` XML} so
  #   the mapper can compute SSH/RDP exposure (CIS 9.2/9.3). When empty, the
  #   sshRestricted/rdpRestricted labels are omitted.
  # @return [Hash] evidence payload ready for ConfirmateClient#store_evidence
  def map_vm(xml_str, sg_xml_by_id: {})
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

    # CXB OpenNebula custom controls (CIS). Computed booleans are emitted as
    # labels so the custom metrics can evaluate them; the raw XML stays attached
    # for ground-truth audit.
    labels = {
      'diskEncryption' => disk_encrypted?(vm).to_s,  # CIS 4.3 vmdisk_encryption
      'publicIp' => has_public_ip.to_s               # CIS 4.4 public_ip_adress
    }
    unless sg_xml_by_id.nil? || sg_xml_by_id.empty?
      # Only emit the ssh/rdp labels when EVERY security group referenced by the
      # VM's NICs was fetched and parsed. With partial coverage the missing
      # group could contain the very rule that exposes the port, so claiming
      # "restricted" would be a false compliance statement; omitting the labels
      # is the honest answer (same as when no SG data is supplied at all).
      expected = nic_security_group_ids(vm)
      parsed = expected.map { |id| [id, parse_inbound_rules(sg_xml_by_id[id])] }.to_h
      if !expected.empty? && parsed.values.none?(&:nil?)
        inbound = parsed.values.flatten
        labels['sshRestricted'] = (!port_open_from_internet?(inbound, 22)).to_s    # CIS 9.2
        labels['rdpRestricted'] = (!port_open_from_internet?(inbound, 3389)).to_s  # CIS 9.3
      else
        warn "confirmate-evidence: security groups #{expected - parsed.reject { |_, v| v.nil? }.keys} " \
             'could not be read; omitting sshRestricted/rdpRestricted labels for ' \
             "one-vm-#{vm_id} rather than risking a false compliance claim"
      end
    end

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
        'internetAccessibleEndpoint' => has_public_ip,
        'labels' => labels
      }
    }

    wrap_evidence("vm-#{vm_id}", resource, xml_str)
  end

  # Returns the unique Security Group IDs referenced by a VM's NICs. The VM hook
  # uses this to know which security groups to fetch (`onesecgroup show -x`) and
  # pass back via map_vm's sg_xml_by_id, so SSH/RDP exposure can be computed.
  #
  # @param vm_xml_str [String] OpenNebula VM XML
  # @return [Array<String>] unique SG id strings
  def self.security_group_ids(vm_xml_str)
    doc = REXML::Document.new(vm_xml_str)
    ids = []
    doc.root.each_element('TEMPLATE/NIC') do |nic|
      sg = nic.elements['SECURITY_GROUPS']&.text
      next if sg.nil? || sg.empty?

      sg.split(',').each { |s| ids << s.strip }
    end
    ids.reject(&:empty?).uniq
  rescue StandardError
    []
  end

  # Best-effort fetch of the security groups referenced by a VM's NICs, shared
  # by the VM and NIC hooks so both submit identical sshRestricted/rdpRestricted
  # labels. SG ids are coerced to Integer before shelling out (no injection).
  # Any failure simply yields a smaller map; map_vm's coverage check then omits
  # the ssh/rdp labels instead of claiming false compliance.
  #
  # @param vm_xml_str [String] OpenNebula VM XML
  # @return [Hash] { sgId => `onesecgroup show -x` XML }
  def self.fetch_sg_xml_by_id(vm_xml_str)
    sg_xml_by_id = {}
    security_group_ids(vm_xml_str).each do |sgid|
      out = `onesecgroup show #{sgid.to_i} -x 2>/dev/null`
      sg_xml_by_id[sgid] = out if out && !out.strip.empty?
    end
    sg_xml_by_id
  rescue StandardError
    sg_xml_by_id || {}
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
  # @param xml_str [String] OpenNebula VM XML (decoded from Base64)
  # @param sg_xml_by_id [Hash] optional {sgId => `onesecgroup show -x` XML}.
  #   When the rules of EVERY security group of a NIC are readable, the NIC
  #   carries `accessRestriction.l3Firewall` with `restrictedPorts` — the field
  #   the EMERALD `RestrictSSH` metric evaluates (`== "22"`). Omitted on
  #   partial/no coverage (same integrity rule as the VM ssh/rdp labels).
  def map_nics(xml_str, sg_xml_by_id: {})
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

      nic_resource = {
        'id' => "one-nic-#{vm_id}-#{nic_id}",
        'name' => "#{network_name}/nic#{nic_id}",
        'labels' => labels,
        'internetAccessibleEndpoint' => public_nic?(nic)
      }

      restriction = nic_access_restriction(sg_ids, sg_xml_by_id)
      nic_resource['accessRestriction'] = restriction if restriction

      wrap_evidence("nic-#{vm_id}-#{nic_id}", { 'networkInterface' => nic_resource }, xml_str)
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

    # OpenNebula marks an image usable by other users via PERMISSIONS/OTHER_U.
    # confirmate.ontology.v1.VMImage has no `publicAccess` field (that lives on
    # FileStorage/ObjectStorage), so emit it as a label: queryable, and never an
    # unknown field the Evidence Store could reject.
    permissions = img.elements['PERMISSIONS']
    public_access = permissions ? (text(permissions, 'OTHER_U') == '1') : false

    resource = {
      'vmImage' => {
        'id' => "one-image-#{img_id}",
        'name' => img_name,
        'creationTime' => creation_time,
        'labels' => { 'publicAccess' => public_access.to_s }
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

  # Generates a deterministic UUID v5 (RFC 4122 §4.3) from a resource key and
  # timestamp. Ensures idempotency: same resource + same second = same evidence
  # ID, on every host. Implemented with stdlib SHA1 only — Digest::UUID is an
  # ActiveSupport extension absent from stock Ruby, and depending on it made
  # the generated IDs differ between hosts with and without it.
  #
  # @param resource_key [String] e.g., "vm-42"
  # @param timestamp [String] RFC 3339 timestamp
  # @return [String] UUID v5 string
  def generate_uuid(resource_key, timestamp)
    name = "#{resource_key}:#{timestamp}"
    ns_bytes = [NAMESPACE_UUID.delete('-')].pack('H*')
    bytes = Digest::SHA1.digest(ns_bytes + name).bytes[0, 16]
    bytes[6] = (bytes[6] & 0x0F) | 0x50 # version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80 # RFC 4122 variant
    hex = bytes.map { |b| format('%02x', b) }.join
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
  end

  # Checks if a NIC has a public (non-RFC1918) IP address.
  #
  # @param nic [REXML::Element] NIC element
  # @return [Boolean] true if NIC has a public IP
  def public_nic?(nic)
    return true if text(nic, 'EXTERNAL')&.upcase == 'YES'

    # A global-unicast IPv6 address is internet-reachable by definition
    # (OpenNebula exposes it separately from link-local/ULA addresses).
    ip6_global = text(nic, 'IP6_GLOBAL')
    return true if ip6_global && !ip6_global.empty?

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

  # Unique Security Group IDs referenced by this VM's NICs.
  def nic_security_group_ids(vm)
    ids = []
    collect_elements(vm, 'TEMPLATE/NIC').each do |nic|
      sg = text(nic, 'SECURITY_GROUPS')
      next if sg.nil? || sg.empty?

      sg.split(',').each { |s| ids << s.strip }
    end
    ids.reject(&:empty?).uniq
  end

  # True if the VM has at least one disk and every disk is encrypted (CIS 4.3).
  # The exact OpenNebula attribute can vary by setup; a non-empty, non-negative
  # ENCRYPTION (or ENCRYPT) value counts as encrypted. The raw XML is attached
  # so an assessor can verify the ground truth regardless.
  def disk_encrypted?(vm)
    disks = collect_elements(vm, 'TEMPLATE/DISK')
    return false if disks.empty?

    disks.all? do |d|
      v = (text(d, 'ENCRYPTION') || text(d, 'ENCRYPT') || '').strip.downcase
      !v.empty? && !%w[no none 0 false].include?(v)
    end
  end

  # Builds the NetworkInterface `accessRestriction.l3Firewall` object from the
  # NIC's security groups, or nil when the rules are unknown (no SGs listed, no
  # SG data supplied, or any referenced group unreadable — never guess).
  #
  # `restrictedPorts` is scoped to SSH for now: the EMERALD `RestrictSSH`
  # metric checks strict equality `restrictedPorts == "22"`, so emitting a
  # broader list (e.g. "22,3389") would fail a genuinely compliant NIC. The
  # RDP state stays available in the VM's `labels.rdpRestricted`.
  def nic_access_restriction(sg_ids_csv, sg_xml_by_id)
    return nil if sg_xml_by_id.nil? || sg_xml_by_id.empty?

    ids = sg_ids_csv.to_s.split(',').map(&:strip).reject(&:empty?)
    return nil if ids.empty?

    parsed = ids.map { |id| parse_inbound_rules(sg_xml_by_id[id]) }
    return nil if parsed.any?(&:nil?) # partial coverage -> unknown, omit

    inbound = parsed.flatten
    ssh_restricted = !port_open_from_internet?(inbound, 22)
    {
      'l3Firewall' => {
        'enabled' => true,
        'restrictedPorts' => ssh_restricted ? '22' : ''
      }
    }
  end

  # Parses the INBOUND rules from an `onesecgroup show -x` XML string into a list
  # of {protocol, range, restricted_source} hashes.
  #
  # Returns nil (NOT []) when the XML is missing or unparseable, so map_vm can
  # distinguish "this SG genuinely has no inbound rules" (=> most restrictive,
  # []) from "we could not read this SG" (=> unknown, labels must be omitted).
  def parse_inbound_rules(sg_xml)
    return nil if sg_xml.nil? || sg_xml.strip.empty?

    doc = REXML::Document.new(sg_xml)
    rules = []
    REXML::XPath.each(doc, '//RULE') do |r|
      next unless (text(r, 'RULE_TYPE') || '').upcase == 'INBOUND'

      restricted = !(text(r, 'NETWORK_ID').to_s.empty? && text(r, 'IP').to_s.empty?)
      rules << {
        'protocol' => (text(r, 'PROTOCOL') || 'ALL').upcase,
        'range' => text(r, 'RANGE'),
        'restricted_source' => restricted
      }
    end
    rules
  rescue StandardError
    nil
  end

  # True if any inbound rule exposes `port` to an unrestricted source (internet):
  # protocol ALL or TCP, the port within RANGE (empty RANGE = all ports), and no
  # source network/IP restriction.
  def port_open_from_internet?(rules, port)
    rules.any? do |r|
      next false if r['restricted_source']
      next false unless %w[ALL TCP].include?(r['protocol'])

      range_includes?(r['range'], port)
    end
  end

  # OpenNebula RANGE is e.g. "22", "22,53,80", "1000:2000", or empty (all ports).
  def range_includes?(range, port)
    return true if range.nil? || range.strip.empty?

    range.split(',').any? do |part|
      part = part.strip
      if part.include?(':')
        lo, hi = part.split(':', 2).map(&:to_i)
        port >= lo && port <= hi
      else
        part.to_i == port
      end
    end
  end
end
