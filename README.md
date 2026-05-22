# addon-confirmate-evidence

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-%E2%89%A5%206.x-brightgreen)](https://opennebula.io)
[![EMERALD](https://img.shields.io/badge/EU-EMERALD%20Horizon%20Europe-yellow)](https://emerald-he.eu)

**Evidence Collection Gateway** for integrating [OpenNebula](https://opennebula.io)
with [Confirmate](https://github.com/confirmate/confirmate) (Fraunhofer AISEC)
toward continuous **EUCS** (EU Cybersecurity Certification Scheme for Cloud
Services) certification.

> Confirmate is the successor to Clouditor. Everything in this repo
> (hooks, library, config) talks to Confirmate.
>
> **Looking to install and use this?** Start with [TUTORIAL.md](TUTORIAL.md)
> — a step-by-step walkthrough from zero to live evidence flowing.

Part of the **EMERALD** project (Evidence Management for Continuous
Certification as a Service in the Cloud), **Pilot 4**: hybrid cloud-edge
certification for the financial sector.

---

## Overview

OpenNebula manages cloud infrastructure (VMs, networks, images, security
groups). Confirmate is a tool by Fraunhofer AISEC that evaluates whether
cloud resources comply with security requirements (EUCS, BSI C5, CSA CCM).

**The problem**: Confirmate has no native OpenNebula discovery.

**The solution**: This addon uses OpenNebula's **Hook subsystem** to detect
state changes in cloud resources, maps them to the `confirmate.ontology.v1`
data model, and POSTs evidence to Confirmate's **Evidence Store** at
`POST /v1/evidence_store/evidence`. Confirmate then evaluates the evidence
against EUCS controls and surfaces results in the EMERALD UI.

```
                         addon-confirmate-evidence
                         =========================

  OpenNebula                                              Confirmate
  ==========                                              ==========

  VM Created ----+
  VM Running ----|     +-------------------+
  VM Deleted ----|---->| Hook Scripts      |     +------------------+
  NIC Attached --|     |  - Decode XML     |     | Evidence Store   |
  NIC Detached --|     |  - Map ontology   |---->|   (REST)         |
  Image Ready ---|     |  - POST evidence  |     +--------+---------+
  Net Created ---+     +-------------------+              |
                                                          v
                                                 +------------------+
                                                 | Assessment       |
                                                 | Engine           |
                                                 +--------+---------+
                                                          |
                                                          v
                                                 +------------------+
                                                 | EMERALD UI       |
                                                 +------------------+
```

Each piece of evidence is tagged with a **Target of Evaluation (ToE)** UUID
that is created (once) in the EMERALD UI; paste that UUID into the addon
config and every subsequent evidence POST carries it.

## Prerequisites

- **OpenNebula** ≥ 6.x (Front-End node)
- A reachable **Confirmate** orchestrator
- **Ruby** 2.6+ (pre-installed on the ONE Front-End)
- No external Ruby gems required (stdlib only)

## Quick Start (local Confirmate, no auth)

The simplest path: run Confirmate's orchestrator in memory with auth off,
which makes evidence submission a plain HTTP POST.

```bash
# 1) Start Confirmate orchestrator (in another terminal)
git clone https://github.com/confirmate/confirmate
cd confirmate/core
go run ./cmd/orchestrator -- --db-in-memory \
                             --create-default-target-of-evaluation
#  listens on http://localhost:8080  (auth-enabled defaults to false)

# 2) Install this addon
sudo ./install.sh

# 3) Configure: edit /etc/one/confirmate-evidence.conf and set
#    target_of_evaluation_id to the UUID from the EMERALD UI (or, for
#    the default ToE created in step 1, fetch it via:
#      curl -s http://localhost:8080/v1/orchestrator/targets_of_evaluation
#    )

# 4) Verify with the smoke test
CONFIRMATE_URL=http://localhost:8080 \
TOE_ID=<uuid-from-step-3>            \
  ruby tests/smoke.rb
```

## Production setup (auth on)

When the orchestrator runs with `--auth-enabled=true`, this addon obtains a
JWT via the OAuth 2.0 **client_credentials** grant against the orchestrator's
embedded OAuth server at `/v1/auth/token`. Set in
`/etc/one/confirmate-evidence.conf`:

```yaml
confirmate:
  endpoint: "http://<orchestrator-host>:8080"
  auth:
    enabled: true
    token_url: "http://<orchestrator-host>:8080/v1/auth/token"
    client_id: "<your-client-id>"
    client_secret: "<your-client-secret>"

evidence:
  tool_id: "opennebula-addon-confirmate-evidence"
  target_of_evaluation_id: "<uuid-from-emerald-ui>"
```

Confirmate's defaults for its built-in service client are
`client_id=confirmate`, `client_secret=confirmate` (see
`core/server/oauth_server.go:39-40`). Override for any deployment beyond
local testing.

## Configuration Reference

| Parameter | Description | Default |
|---|---|---|
| `confirmate.endpoint` | Confirmate orchestrator REST URL | `http://localhost:8080` |
| `confirmate.auth.enabled` | Send `Authorization: Bearer …` | `false` |
| `confirmate.auth.token_url` | OAuth2 token endpoint | `http://localhost:8080/v1/auth/token` |
| `confirmate.auth.client_id` | OAuth2 client ID | `confirmate` |
| `confirmate.auth.client_secret` | OAuth2 client secret | `confirmate` |
| `confirmate.auth.static_token` | Pre-issued bearer token (bypass OAuth) | _(empty)_ |
| `evidence.tool_id` | Tool identifier in every evidence | `opennebula-addon-confirmate-evidence` |
| `evidence.target_of_evaluation_id` | ToE UUID created in EMERALD UI | _(placeholder)_ |
| `evidence.default_region` | Geo-location label | `eu-south-1` |
| `logging.level` | Log verbosity: debug, info, warn, error | `info` |
| `logging.file` | Log file path | `/var/log/one/confirmate-evidence.log` |

The previous `clouditor.*` and `evidence.cloud_service_id` keys are no
longer used; `cloud_service_id` is still read as a transient back-compat
fallback (mapped to `target_of_evaluation_id`) but will be removed in a
future release.

## Hooks Registered

| Hook | Type | Trigger | Evidence Type |
|---|---|---|---|
| `hook-confirmate-vm-running` | State | VM reaches RUNNING | VirtualMachine |
| `hook-confirmate-vm-poweroff` | State | VM reaches POWEROFF | VirtualMachine |
| `hook-confirmate-vm-done` | State | VM is terminated | VirtualMachine |
| `hook-confirmate-nic-attach` | API | `one.vm.attachnic` | NetworkInterface + VM |
| `hook-confirmate-nic-detach` | API | `one.vm.detachnic` | NetworkInterface + VM |
| `hook-confirmate-image-ready` | State | Image reaches READY | VMImage |
| `hook-confirmate-net-create` | API | `one.vn.allocate` | VirtualNetwork |

## Resource Mapping (`confirmate.ontology.v1`)

### OpenNebula VM → VirtualMachine

| ONE XML Field | Ontology Field | Notes |
|---|---|---|
| `<ID>` | `id` | `"one-vm-{id}"` |
| `<NAME>` | `name` | |
| `<STIME>` | `creationTime` | Unix epoch → RFC 3339 |
| `<NIC>` (all) | `networkInterfaceIds` | IDs only; full NIC data is its own evidence |
| `<DISK>` (all) | `blockStorageIds` | IDs only |
| `<NIC><EXTERNAL>` or non-RFC1918 IP | `internetAccessibleEndpoint` | bool |
| `<MONITORING>` | `bootLogging.enabled`, `osLogging.enabled` | heuristic |
| — | `automaticUpdates.enabled` | always `false` (no ONE source) |
| `<DISK><ENCRYPT>` / `<CIPHER>` | _(in `raw` XML only)_ | Confirmate's ontology no longer carries at-rest-encryption on the VM level; the algorithm + enabled flag remain available in the attached `raw` XML. |

### OpenNebula NIC → NetworkInterface

| ONE XML Field | Ontology Field |
|---|---|
| `<NIC_ID>` | `id` (`"one-nic-{vm_id}-{nic_id}"`) |
| `<NETWORK>` | `name` |
| `<EXTERNAL>` or non-RFC1918 IP | `internetAccessibleEndpoint` |
| `<IP>` | `labels.ip` |
| `<NETWORK>` | `labels.network` |
| `<SECURITY_GROUPS>` | `labels.securityGroupIds` |

`confirmate.ontology.v1.NetworkInterface` does not have first-class fields
for IP address or security-group membership; both are carried in `labels`
(a `map<string,string>`) so they remain queryable by Confirmate policies.

### OpenNebula Image → VMImage

| ONE XML Field | Ontology Field |
|---|---|
| `<ID>` | `id` (`"one-image-{id}"`) |
| `<NAME>` | `name` |
| `<REGTIME>` | `creationTime` |
| `<PERMISSIONS><OTHER_U>` | `publicAccess` |

## EUCS Controls

This addon supplies evidence for the following CIS-based controls
defined in the EMERALD Pilot 4 (CaixaBank) audit scope. Note that the
encryption-related controls (CIS 4.3 / 4.4) currently rely on the
attached `raw` XML rather than a typed at-rest-encryption ontology
field; Confirmate's ontology dropped the typed at-rest-encryption field
on `VirtualMachine`.

| Control | Description | Evidence Source |
|---|---|---|
| CIS 4.3 | VM Disk Encryption with CSEK | `DISK/ENCRYPT` + `DISK/CIPHER` (raw) |
| CIS 4.4 | No Public IP on Compute Instances | `NIC/EXTERNAL`, IP-range check → `internetAccessibleEndpoint` |
| CIS 8.3 | Storage Not Publicly Accessible | `IMAGE/PERMISSIONS/OTHER_U` |
| CIS 8.5 | Cloud Asset Inventory Enabled | Continuous evidence collection |
| CIS 8.6 | Cloud Audit Logging Configured | `MONITORING` presence |
| CIS 9.2 | SSH Access Restricted | `NIC/SECURITY_GROUPS` |
| CIS 9.3 | RDP Access Restricted | `NIC/SECURITY_GROUPS` |

## Running tests

```bash
ruby tests/test_ontology_mapper.rb   # unit tests for the XML → JSON mapping
ruby tests/test_token_manager.rb     # unit tests for the OAuth2 flow
ruby tests/smoke.rb                  # end-to-end POST to a live Confirmate
```

The smoke test skips cleanly if no orchestrator is reachable at
`CONFIRMATE_URL`.

## Troubleshooting

### 401 Unauthorized
Either `confirmate.auth.enabled` is on but the credentials are wrong, or
the orchestrator has rotated its signing keys (token cache invalid). The
addon refreshes its token automatically on 401 — repeated 401s indicate a
credential / JWKS mismatch.

### Hook not triggering
1. `onehook list` — hook is registered?
2. `onehook show <id>` — state OK?
3. `onehook log <id>` — script ran?
4. `ls -la /var/lib/one/remotes/hooks/confirmate_*.rb` — scripts executable?

### Evidence not appearing
1. `tail -f /var/log/one/confirmate-evidence.log`
2. `curl -s http://<orchestrator>:8080/v1/evidence_store/evidences | head` —
   does Confirmate see anything for this tool?
3. Confirm `target_of_evaluation_id` matches a real ToE in Confirmate.

## Project Structure

```
addon-clouditor-evidence/  (historical name; everything inside is Confirmate)
├── etc/
│   └── confirmate-evidence.conf      # Configuration (YAML)
├── lib/
│   ├── confirmate_client.rb          # HTTP client for Evidence Store
│   ├── ontology_mapper.rb            # ONE XML → confirmate.ontology.v1
│   └── token_manager.rb              # OAuth2 client_credentials
├── hooks/
│   ├── confirmate_vm_evidence.rb     # VM state change hook
│   ├── confirmate_nic_evidence.rb    # NIC attach/detach hook
│   ├── confirmate_image_evidence.rb  # Image state hook
│   └── confirmate_net_evidence.rb    # Network creation hook
├── templates/                        # OpenNebula hook registration templates
├── demo/                             # (historical) Clouditor-era demo — see CHANGELOG
├── tests/                            # Unit tests + smoke test
├── examples/                         # Sample evidence JSON payloads
├── install.sh / uninstall.sh         # Lifecycle scripts
└── TUTORIAL.md                       # Step-by-step install + use guide
```

The `demo/` directory still contains the Clouditor-era Docker setup. It has
not been migrated yet — use the Quick Start above against an upstream
Confirmate checkout instead.

## Acknowledgments

<img src="https://emerald-he.eu/wp-content/uploads/2023/09/eu-flag.png" alt="EU Flag" width="50" align="left" style="margin-right: 10px;">

This project has received funding from the European Union's Horizon Europe
research and innovation programme under grant agreement No. **101120688**
([EMERALD](https://emerald-he.eu)).

**Partners:**
- [Fraunhofer AISEC](https://www.aisec.fraunhofer.de/) — Confirmate development and EUCS expertise
- [OpenNebula Systems](https://opennebula.io) — Cloud management platform and addon development
- [CaixaBank](https://www.caixabank.com) — Pilot 4 validation (financial sector)

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
