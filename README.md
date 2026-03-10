# addon-clouditor-evidence

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-%E2%89%A5%206.x-brightgreen)](https://opennebula.io)
[![EMERALD](https://img.shields.io/badge/EU-EMERALD%20Horizon%20Europe-yellow)](https://emerald-he.eu)

**Evidence Collection Gateway** for integrating [OpenNebula](https://opennebula.io) with [Clouditor](https://github.com/clouditor/clouditor) (Fraunhofer AISEC) toward continuous **EUCS** (EU Cybersecurity Certification Scheme for Cloud Services) certification.

Part of the **EMERALD** project (Evidence Management for Continuous Certification as a Service in the Cloud), **Pilot 4**: hybrid cloud-edge certification for the financial sector.

---

## Overview

OpenNebula manages cloud infrastructure (VMs, networks, images, security groups). Clouditor is a tool by Fraunhofer AISEC that evaluates whether cloud resources comply with security requirements (EUCS, BSI C5, CSA CCM).

**The problem**: Clouditor natively supports AWS, Azure, and GCP for resource discovery. It does not natively support OpenNebula.

**The solution**: This addon uses OpenNebula's **Hook subsystem** to detect state changes in cloud resources and push **evidence** to Clouditor's **Evidence Store** via its REST API. Clouditor then evaluates this evidence against EUCS controls and produces compliance assessment results.

```
                         addon-clouditor-evidence
                         ========================

  OpenNebula                                              Clouditor
  ==========                                              =========

  VM Created ----+
  VM Running ----|     +-------------------+
  VM Deleted ----|---->| Hook Scripts      |     +------------------+
  NIC Attached --|     |  - Decode XML     |     | Evidence Store   |
  NIC Detached --|     |  - Map ontology   |---->|   (REST API)     |
  Image Ready ---|     |  - POST evidence  |     +--------+---------+
  Net Created ---+     +-------------------+              |
                                                          v
                                                 +------------------+
                                                 | Assessment       |
                                                 | Engine           |
                                                 |  - Evaluate      |
                                                 |    metrics       |
                                                 |  - COMPLIANT /   |
                                                 |    NON_COMPLIANT |
                                                 +--------+---------+
                                                          |
                                                          v
                                                 +------------------+
                                                 | EMERALD UI       |
                                                 | Compliance       |
                                                 | Dashboard        |
                                                 +------------------+
```

## Prerequisites

- **OpenNebula** >= 6.x (Front-End node)
- **Clouditor** instance (local or remote), reachable from the ONE Front-End
- **Ruby** (pre-installed on ONE Front-End)
- No external gems required (uses Ruby stdlib only)

## Quick Start

### 1. Set up Clouditor (for testing)

```bash
cd demo/
./setup-clouditor-demo.sh
```

This starts a local Clouditor instance via Docker and configures it for the EMERALD Pilot 4 demo.

### 2. Install the addon

```bash
sudo ./install.sh
```

### 3. Configure

Edit `/etc/one/clouditor-evidence.conf`:

```yaml
clouditor:
  endpoint: "http://<clouditor-host>:8082"
  auth:
    token_url: "http://<clouditor-host>:8082/v1/auth/token"
    username: "clouditor"
    password: "clouditor"

evidence:
  tool_id: "opennebula-addon-clouditor-evidence"
  cloud_service_id: "<your-cloud-service-uuid>"
```

### 4. Test

Create a VM and check the log:

```bash
tail -f /var/log/one/clouditor-evidence.log
```

### 5. Run the demo

```bash
cd demo/
./run-demo.sh
```

Open the Clouditor UI at `http://localhost:3000` (credentials: `clouditor` / `clouditor`).

## Configuration Reference

| Parameter | Description | Default |
|---|---|---|
| `clouditor.endpoint` | Clouditor REST API URL | `http://localhost:8082` |
| `clouditor.auth.token_url` | OAuth2 token endpoint | `http://localhost:8082/v1/auth/token` |
| `clouditor.auth.username` | Clouditor username | `clouditor` |
| `clouditor.auth.password` | Clouditor password | `clouditor` |
| `clouditor.auth.static_token` | Pre-configured bearer token (bypasses OAuth2) | _(empty)_ |
| `evidence.tool_id` | Tool identifier in evidence payloads | `opennebula-addon-clouditor-evidence` |
| `evidence.cloud_service_id` | Target of Evaluation UUID in Clouditor | `00000000-...` |
| `evidence.default_region` | Geo-location for resources | `eu-south-1` |
| `logging.level` | Log verbosity: debug, info, warn, error | `info` |
| `logging.file` | Log file path | `/var/log/one/clouditor-evidence.log` |

## Hooks Registered

| Hook | Type | Trigger | Evidence Type |
|---|---|---|---|
| `hook-clouditor-vm-running` | State | VM reaches RUNNING | VirtualMachine |
| `hook-clouditor-vm-poweroff` | State | VM reaches POWEROFF | VirtualMachine |
| `hook-clouditor-vm-done` | State | VM is terminated | VirtualMachine |
| `hook-clouditor-nic-attach` | API | `one.vm.attachnic` | NetworkInterface + VM |
| `hook-clouditor-nic-detach` | API | `one.vm.detachnic` | NetworkInterface + VM |
| `hook-clouditor-image-ready` | API | Image reaches READY | VMImage |
| `hook-clouditor-net-create` | API | `one.vn.allocate` | VirtualNetwork |

## Resource Mapping Reference

### OpenNebula VM -> Clouditor VirtualMachine

| ONE XML Field | Ontology Field | Description |
|---|---|---|
| `<ID>` | `id` | `"one-vm-{id}"` |
| `<NAME>` | `name` | VM name |
| `<STIME>` | `creationTime` | Unix epoch -> RFC 3339 |
| `<DISK><ENCRYPT>` | `atRestEncryption.managedKeyEncryption.enabled` | Disk encryption status |
| `<DISK><CIPHER>` | `atRestEncryption.managedKeyEncryption.algorithm` | Encryption algorithm |
| `<NIC><EXTERNAL>` | `publicIp` | Whether VM has public IP |
| `<NIC>` (all) | `networkInterfaces` | List of NIC resource IDs |
| `<DISK>` (all) | `blockStorage` | List of disk resource IDs |
| `<MONITORING>` | `bootLogging.enabled`, `osLogging.enabled` | Logging status heuristic |

### OpenNebula NIC -> Clouditor NetworkInterface

| ONE XML Field | Ontology Field |
|---|---|
| `<NIC_ID>` | `id` (`"one-nic-{vm_id}-{nic_id}"`) |
| `<NETWORK>` | `name` |
| `<IP>` | `ip` |
| `<SECURITY_GROUPS>` | `accessRestriction.securityGroups` |

### OpenNebula Image -> Clouditor VMImage

| ONE XML Field | Ontology Field |
|---|---|
| `<ID>` | `id` (`"one-image-{id}"`) |
| `<NAME>` | `name` |
| `<REGTIME>` | `creationTime` |
| `<PERMISSIONS><OTHER_U>` | `publicAccess` |

## EUCS Controls Covered

This addon provides evidence for the following CIS-based controls from the EMERALD Pilot 4 (CaixaBank) audit scope:

| Control | Description | Evidence Source |
|---|---|---|
| **CIS 4.3** | VM Disk Encryption with CSEK | `DISK/ENCRYPT` + `DISK/CIPHER` |
| **CIS 4.4** | No Public IP on Compute Instances | `NIC/EXTERNAL` + IP range check |
| **CIS 8.3** | Storage Not Publicly Accessible | `IMAGE/PERMISSIONS/OTHER_U` |
| **CIS 8.5** | Cloud Asset Inventory Enabled | Continuous evidence collection |
| **CIS 8.6** | Cloud Audit Logging Configured | `MONITORING` presence |
| **CIS 9.2** | SSH Access Restricted | Security Group port 22 rules |
| **CIS 9.3** | RDP Access Restricted | Security Group port 3389 rules |

## Running Tests

```bash
cd tests/
ruby test_ontology_mapper.rb
ruby test_token_manager.rb
```

## Troubleshooting

### Token expired / 401 Unauthorized
The addon automatically refreshes OAuth2 tokens. If using a `static_token`, ensure it hasn't expired. Regenerate with:
```bash
curl -X POST http://<clouditor>:8082/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"clouditor","password":"clouditor"}'
```

### Hook not triggering
1. Check hook is registered: `onehook list`
2. Check hook status: `onehook show <id>`
3. Check hook execution log: `onehook log <id>`
4. Verify hook script is executable: `ls -la /var/lib/one/remotes/hooks/clouditor_*.rb`

### Evidence not appearing in Clouditor
1. Check the addon log: `tail -f /var/log/one/clouditor-evidence.log`
2. Verify network connectivity: `curl -s http://<clouditor>:8082/v1/orchestrator/cloud_services`
3. Ensure `cloud_service_id` in config matches the ID in Clouditor

### Clouditor not evaluating evidence
Evidence must match a resource type that has active metrics. Check available metrics:
```bash
curl -H "Authorization: Bearer $TOKEN" http://<clouditor>:8082/v1/orchestrator/metrics
```

## Project Structure

```
addon-clouditor-evidence/
├── etc/
│   └── clouditor-evidence.conf      # Configuration (YAML)
├── lib/
│   ├── clouditor_client.rb          # HTTP client for Evidence Store
│   ├── ontology_mapper.rb           # ONE XML -> Clouditor ontology
│   └── token_manager.rb            # OAuth2 token management
├── hooks/
│   ├── clouditor_vm_evidence.rb     # VM state change hook
│   ├── clouditor_nic_evidence.rb    # NIC attach/detach hook
│   ├── clouditor_image_evidence.rb  # Image state hook
│   └── clouditor_net_evidence.rb    # Network creation hook
├── templates/                       # OpenNebula hook registration templates
├── demo/                            # Demo environment (Docker + scripts)
├── tests/                           # Unit tests (minitest)
├── examples/                        # Sample evidence JSON payloads
├── install.sh                       # Automated installer
└── uninstall.sh                     # Clean uninstaller
```

## Contributing

Contributions are welcome. Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes with tests
4. Submit a Pull Request

## Acknowledgments

<img src="https://emerald-he.eu/wp-content/uploads/2023/09/eu-flag.png" alt="EU Flag" width="50" align="left" style="margin-right: 10px;">

This project has received funding from the European Union's Horizon Europe research and innovation programme under grant agreement No. **101120688** ([EMERALD](https://emerald-he.eu)).

**Partners:**
- [Fraunhofer AISEC](https://www.aisec.fraunhofer.de/) - Clouditor development and EUCS expertise
- [OpenNebula Systems](https://opennebula.io) - Cloud management platform and addon development
- [CaixaBank](https://www.caixabank.com) - Pilot 4 validation (financial sector use case)

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
