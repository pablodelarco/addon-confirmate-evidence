# addon-confirmate-evidence

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-%E2%89%A5%206.x-brightgreen)](https://opennebula.io)
[![EMERALD](https://img.shields.io/badge/EU-EMERALD%20Horizon%20Europe-yellow)](https://emerald-he.eu)

**Evidence Collection Gateway** for [OpenNebula](https://opennebula.io)
→ [Confirmate](https://github.com/confirmate/confirmate) (Fraunhofer
AISEC). When a VM starts, a NIC is attached, an image is uploaded, or
a network is created in OpenNebula, this addon maps the resource to
Confirmate's ontology and POSTs it. Confirmate evaluates EUCS / CIS /
CSA CCM metrics against the evidence; verdicts surface in the EMERALD UI.

Part of the **EMERALD** project (EU Horizon Europe, grant 101120688),
Pilot 4 — hybrid cloud-edge certification for the financial sector.

```text
[OpenNebula]  -- hooks fire -->  [addon]  -- HTTP POST -->  [Confirmate]  -->  [EMERALD UI]
 (CaixaBank)                    (this repo)   evidence      (Fraunhofer)
```

---

## How it works

```text
┌────────────────────────────────────────────────────────────────────┐
│  🟢  OpenNebula Front-End                                          │
│                                                                    │
│  ┌─────────────┐     ┌──────────────┐     ┌──────────────────┐     │
│  │  onevm      │     │ hook-        │     │ OntologyMapper   │     │
│  │  create     │     │ confirmate-* │     │ ConfirmateClient │     │
│  │  nic-attach │ ──> │ scripts      │ ──> │ TokenManager     │     │
│  │  oneimage   │     │ fire         │     │                  │     │
│  │  onevnet    │     │ automatic.   │     │                  │     │
│  └─────────────┘     └──────────────┘     └──────────────────┘     │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  │  POST /v1/evidence_store/evidence
                                  │  OAuth2 Bearer JWT
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│  🔵  Confirmate                                                    │
│                                                                    │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐    │
│  │  Evidence    │     │  Assessment  │     │  Orchestrator    │    │
│  │  Store       │ ──> │  Engine      │ ──> │  + Verdict store │    │
│  │              │     │  (Rego)      │     │                  │    │
│  └──────────────┘     └──────────────┘     └──────────────────┘    │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  │  GET /v1/orchestrator/assessment_results
                                  ▼
                       ┌──────────────────────┐
                       │  ⬜  EMERALD UI       │
                       │      compliance      │
                       │      dashboard       │
                       └──────────────────────┘
```

---

## Quick start

~10 minutes. You need an OpenNebula Front-End (6.x+) and a reachable
Confirmate URL with OAuth client credentials.

> **No Confirmate yet?** Spin up a local test instance first —
> see [Appendix A](#appendix-a--local-confirmate-for-testing).

### 1. Install on the OpenNebula Front-End

```bash
cd /root
git clone https://github.com/pablodelarco/addon-confirmate-evidence
cd addon-confirmate-evidence
sudo ./install.sh
```

The installer copies the library under `/var/lib/one/remotes/hooks/`,
the config to `/etc/one/confirmate-evidence.conf`, and registers the
seven hooks. ✅ ends with `Installation complete!`.

### 2. Configure

Edit `/etc/one/confirmate-evidence.conf`. The shipped file has a **local-testing**
block (default) and a commented **production template** — pick one.

**Production (Keycloak-fronted EMERALD deployment).** In a real EMERALD pilot the
Evidence Store, the Orchestrator and Keycloak are separate hosts, and auth is
issued by **Keycloak**, not Confirmate's embedded OAuth. Ask the platform
operator for a dedicated service client (`client_id` + `client_secret`) in your
Keycloak realm, then:

```yaml
confirmate:
  endpoint: "https://<evidence-store-host>"               # 1) Evidence Store URL (HTTPS)
  auth:
    enabled: true                                         # 2) required in production
    token_url: "https://<keycloak-host>/realms/<realm>/protocol/openid-connect/token"
    client_id: "<keycloak-service-client-id>"             # 3) from the platform operator
    client_secret: "<keycloak-service-client-secret>"     #    (prefer a secret store)
  # tls:
  #   ca_file: "/etc/ssl/certs/emerald-ca.pem"            # only if your CA chain needs it

evidence:
  tool_id: "opennebula-addon-confirmate-evidence"
  target_of_evaluation_id: "PASTE-TOE-UUID-HERE"          # ToE "Target ID" from the EMERALD UI
  default_region: "eu-south-1"

logging:
  level: "info"
  file: "/var/log/one/confirmate-evidence.log"
```

The addon refuses to start when `target_of_evaluation_id` is missing or not a
UUID; the all-zeros placeholder is accepted with a loud warning (it only works
against a local default orchestrator). For local
testing values, see [Appendix A](#appendix-a--local-confirmate-for-testing).

```bash
sudo chown oneadmin:oneadmin /etc/one/confirmate-evidence.conf
sudo chmod 640 /etc/one/confirmate-evidence.conf
```

### 3. Verify hook registration

```bash
sudo -u oneadmin onehook list   # expect 7 hook-confirmate-* entries
```

If hooks are missing, register manually:

```bash
sudo cp /root/addon-confirmate-evidence/templates/*.tmpl /tmp/
sudo chmod 644 /tmp/hook-*.tmpl
sudo -u oneadmin sh -c 'for t in /tmp/hook-*.tmpl; do onehook create "$t"; done'
```

### 4. Send one evidence end-to-end

Create a throwaway VNet — `hook-confirmate-net-create` fires
automatically and ships evidence to Confirmate:

```bash
sudo truncate -s0 /var/log/one/confirmate-evidence.log

cat <<'EOF' | sudo tee /tmp/test-vnet.tmpl > /dev/null
NAME   = "confirmate-test"
VN_MAD = "dummy"
BRIDGE = "br-test"
AR = [ TYPE = "IP4", IP = "192.0.2.0", SIZE = "4" ]
EOF
sudo chmod 644 /tmp/test-vnet.tmpl

VNET_ID=$(sudo -u oneadmin onevnet create /tmp/test-vnet.tmpl | grep -oP 'ID: \K[0-9]+')
sleep 3
sudo tail -20 /var/log/one/confirmate-evidence.log
sudo -u oneadmin onevnet delete $VNET_ID   # cleanup
```

✅ Look for `Evidence ... stored successfully (HTTP 200)` in the
addon log. That's the moment your evidence reached Confirmate.

From here the addon reacts to events automatically — nothing else to run.

---

## What fires automatically

Hooks fire on **future** state transitions; existing VMs are not
re-scanned.

| OpenNebula action | Hook | Evidence sent |
|---|---|---|
| VM enters RUNNING | `hook-confirmate-vm-running` | VirtualMachine + each NetworkInterface |
| VM enters POWEROFF | `hook-confirmate-vm-poweroff` | updated VirtualMachine |
| VM is terminated | `hook-confirmate-vm-done` | final VirtualMachine state |
| `onevm nic-attach` / `nic-detach` | (vm-running re-fires) | updated VirtualMachine + NICs |
| Image reaches READY | `hook-confirmate-image-ready` | VMImage |
| `onevnet create` | `hook-confirmate-net-create` | VirtualNetwork |

Live log: `sudo tail -f /var/log/one/confirmate-evidence.log`

---

## See compliance verdicts

```bash
ACCESS=$(curl -sS -u <client-id>:<client-secret> \
  -d 'grant_type=client_credentials' \
  http://CONFIRMATE-HOST:8080/v1/auth/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

curl -sS -H "Authorization: Bearer $ACCESS" \
  http://CONFIRMATE-HOST:8080/v1/orchestrator/assessment_results \
  | python3 -m json.tool
```

Each result links back to the originating evidence by ID:

```json
{
  "metricId": "...",
  "compliant": true,
  "evidenceId": "...",
  "resourceId": "one-vm-42",
  "resourceTypes": ["VirtualMachine", "Compute", ...],
  "complianceComment": "...",
  "targetOfEvaluationId": "..."
}
```

> **If you get `{}`** despite evidence being in the log: this endpoint
> filters by user permission on the ToE. Service-account credentials
> (the ones the addon uses) typically can't read verdicts — query
> with the EMERALD UI account or an admin user instead. **Not a bug:**
> collectors push, the UI reads.

---

## Configuration reference

| Parameter | Description | Default |
|---|---|---|
| `confirmate.endpoint` | Confirmate orchestrator URL | `http://localhost:8080` |
| `confirmate.auth.enabled` | Send `Authorization: Bearer …` | `false` |
| `confirmate.auth.token_url` | OAuth2 token endpoint | `http://localhost:8080/v1/auth/token` |
| `confirmate.auth.client_id` / `client_secret` | OAuth2 credentials | `confirmate` / `confirmate` |
| `confirmate.auth.static_token` | Pre-issued bearer token (bypass OAuth) | _(empty)_ |
| `confirmate.tls.ca_file` | Extra CA bundle to trust _in addition_ to system roots (HTTPS); never weakens verification | _(empty)_ |
| `evidence.tool_id` | Tool identifier in every evidence | `opennebula-addon-confirmate-evidence` |
| `evidence.target_of_evaluation_id` | ToE UUID from EMERALD UI (missing/non-UUID rejected; all-zeros placeholder warns) | _(placeholder)_ |
| `evidence.default_region` | Geo-location label | `eu-south-1` |
| `logging.level` | debug / info / warn / error | `info` |
| `logging.file` | Log file path | `/var/log/one/confirmate-evidence.log` |

---

## Resource mapping (`confirmate.ontology.v1`)

### VM → VirtualMachine

| ONE XML | Ontology field | Notes |
|---|---|---|
| `<ID>` | `id` | `"one-vm-{id}"` |
| `<NAME>` | `name` | |
| `<STIME>` | `creationTime` | Unix epoch → RFC 3339 |
| `<NIC>` (all) | `networkInterfaceIds` | IDs only; full NIC data is separate evidence |
| `<DISK>` (all) | `blockStorageIds` | IDs only |
| `<NIC><EXTERNAL>` or non-RFC1918 IP | `internetAccessibleEndpoint` | bool |
| `<MONITORING>` | `bootLogging.enabled`, `osLogging.enabled` | heuristic |
| — | `automaticUpdates.enabled` | always `false` (no ONE source) |
| `<DISK><ENCRYPTION>` or `<ENCRYPT>` (all disks) | `labels.diskEncryption` | CIS 4.3, computed bool: `"true"` only when every disk carries an encryption attribute (`CIPHER` rides in `raw` only, not evaluated) |
| `<NIC><EXTERNAL>` or non-RFC1918 IP | `labels.publicIp` | CIS 4.4, mirrors `internetAccessibleEndpoint` |
| `<NIC><SECURITY_GROUPS>` inbound rules | `labels.sshRestricted`, `labels.rdpRestricted` | CIS 9.2 / 9.3: the VM/NIC hooks fetch the groups via `onesecgroup show -x`; the labels are emitted only when **every** referenced group could be read (a partial read could hide the exposing rule), and are `"true"` when access is restricted (port 22/3389 NOT reachable from an unrestricted source) |

### NIC → NetworkInterface

| ONE XML | Ontology field |
|---|---|
| `<NIC_ID>` | `id` (`"one-nic-{vm_id}-{nic_id}"`) |
| `<NETWORK>` | `name` |
| `<EXTERNAL>` or non-RFC1918 IP | `internetAccessibleEndpoint` |
| `<IP>` | `labels.ip` |
| `<NETWORK>` | `labels.network` |
| `<SECURITY_GROUPS>` | `labels.securityGroupIds` |
| `<SECURITY_GROUPS>` inbound rules | `accessRestriction.l3Firewall.restrictedPorts` (`"22"` when SSH is blocked from the internet; emitted only with full SG coverage) — the field the EMERALD `RestrictSSH` metric evaluates |

`NetworkInterface` has no first-class fields for IP or security groups;
they ride in `labels` (a `map<string,string>`), still queryable by
Confirmate policies.

### Image → VMImage

| ONE XML | Ontology field |
|---|---|
| `<ID>` | `id` (`"one-image-{id}"`) |
| `<NAME>` | `name` |
| `<REGTIME>` | `creationTime` |
| `<PERMISSIONS><OTHER_U>` | `labels.publicAccess` |

`VMImage` has no first-class `publicAccess` field in `confirmate.ontology.v1`
(it exists only on `FileStorage`/`ObjectStorage`), so it rides in `labels` —
still queryable, and a strict Evidence Store cannot reject the evidence for an
unknown field.

---

## EUCS / CIS controls covered

| Control | Description | Evidence source |
|---|---|---|
| CIS 4.3 | VM Disk Encryption | `DISK/ENCRYPTION`\|`ENCRYPT` (all disks) → `virtualMachine.labels.diskEncryption`; raw XML attached (`CIPHER` carried in raw only) |
| CIS 4.4 | No Public IP on Compute Instances | `NIC/EXTERNAL`, IP-range check → `internetAccessibleEndpoint` + `labels.publicIp` |
| CIS 8.3 | Storage Not Publicly Accessible | Approximation (not in the CXB OpenNebula metric set): `IMAGE/PERMISSIONS/OTHER_U` → `vmImage.labels.publicAccess` |
| CIS 8.5 | Cloud Asset Inventory Enabled | Partial: continuous per-resource evidence; full inventory needs a system-level collector |
| CIS 8.6 | Cloud Audit Logging Configured | Partial: `MONITORING` presence → `bootLogging`/`osLogging`; oned-level audit config needs a system-level collector |
| CIS 9.2 | SSH Access Restricted | `NIC/SECURITY_GROUPS` inbound rules (`onesecgroup show -x`) → `labels.sshRestricted` (VM) + `networkInterface.accessRestriction.l3Firewall.restrictedPorts` (EMERALD `RestrictSSH` metric) |
| CIS 9.3 | RDP Access Restricted | same mechanism, port 3389 → `labels.rdpRestricted` |

---

## Troubleshooting

**`command create: argument 0 must be one of file`** — the template
file isn't readable by `oneadmin` (mode 700 dirs like `/root/`). Stage
under `/tmp/` first:
```bash
sudo cp /root/addon-confirmate-evidence/templates/*.tmpl /tmp/
sudo chmod 644 /tmp/hook-*.tmpl
sudo -u oneadmin sh -c 'for t in /tmp/hook-*.tmpl; do onehook create "$t"; done'
```

**`HTTP 401 Unauthorized` in the addon log** — `client_id` / `client_secret`
mismatch, or `auth.enabled` doesn't match Confirmate's `--auth-enabled`
flag. Reconcile both ends.

**`HTTP 400` with a field validation message** — usually
`target_of_evaluation_id` is invalid (placeholder UUID, or not a real
ToE). Paste the real ToE UUID from the EMERALD UI.

**Hook fires but no `Evidence stored successfully` follows** — POST
failed silently. Check reachability:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://CONFIRMATE-HOST:8080/v1/auth/certs
```
Not `200` = network / DNS / firewall issue. If `200`, set
`logging.level: debug` to see the exact HTTP response.

**Confirmate log: `Stream restarted ... err="EOF"`** — long-running
Confirmate processes degrade their internal bidi streams. Verdicts
may stop persisting even though ingestion still works. Restart
Confirmate (`tmux kill-session -t confirmate` then re-run the start
command from Appendix A). Use a Postgres backend in production so
data survives the restart.

**`assessment_results` returns `{}`** — permission filter (see the
note in [See compliance verdicts](#see-compliance-verdicts)). Query
with the EMERALD UI account or an admin user.

**`nic-attach` / `nic-detach` API hooks silent** — on ONE 7.2 the
hook validator and API dispatcher use different method names for
these calls, so the dedicated hooks never fire. No data lost: the
VM transitions back to RUNNING after the hot-plug and the state hook
re-emits the VM + NIC evidence.

---

## Maintenance

```bash
# Is the addon healthy?
sudo tail -20 /var/log/one/confirmate-evidence.log

# Which hooks fired recently, and did they succeed?
sudo -u oneadmin onehook log --since $(date -d '1 hour ago' +%m/%d) | head -30

# Is Confirmate reachable from the OpenNebula Front-End?
curl -sS -o /dev/null -w "%{http_code}\n" http://CONFIRMATE-HOST:8080/v1/auth/certs   # → 200

# Tests
ruby tests/test_ontology_mapper.rb   # 40 unit tests
ruby tests/test_token_manager.rb     #  6 unit tests
ruby tests/test_confirmate_client.rb #  7 unit tests (retry/status contract, no network)
ruby tests/smoke.rb                  # end-to-end POST (skips cleanly if no Confirmate)

# Uninstall
sudo ./uninstall.sh                  # removes hooks + scripts; asks before deleting config
```

`smoke.rb` env vars: `CONFIRMATE_URL`, `TOE_ID`, `CONFIRMATE_AUTH=on`,
`CONFIRMATE_CLIENT_ID`, `CONFIRMATE_CLIENT_SECRET`.

---

## Project layout

```
addon-confirmate-evidence/
├── etc/confirmate-evidence.conf      # YAML config
├── lib/                              # Ruby library
│   ├── confirmate_client.rb          #   HTTP client for Evidence Store
│   ├── ontology_mapper.rb            #   ONE XML → confirmate.ontology.v1
│   └── token_manager.rb              #   OAuth2 client_credentials
├── hooks/                            # OpenNebula hook scripts
│   ├── confirmate_vm_evidence.rb     #   VM state changes
│   ├── confirmate_nic_evidence.rb    #   NIC attach / detach
│   ├── confirmate_image_evidence.rb  #   Image state
│   └── confirmate_net_evidence.rb    #   Virtual Network creation
├── templates/                        # onehook create templates
├── tests/                            # Unit tests + smoke test
├── examples/                         # Sample evidence JSON payloads
└── install.sh / uninstall.sh
```

---

## Appendix A — Local Confirmate for testing

Use this if you don't have a Confirmate URL yet. Bring up an
in-memory test instance on any Linux host the OpenNebula Front-End
can reach.

```bash
# 1) Install Go 1.26+
curl -fsSL -O https://go.dev/dl/go1.26.3.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.26.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 2) Clone, build, run
git clone --recurse-submodules https://github.com/confirmate/confirmate
cd confirmate/core
go build -o bin/confirmate ./cmd/confirmate
tmux new-session -d -s confirmate -c "$(pwd)" \
  "./bin/confirmate --auth-enabled --oauth2-embedded \
                    --oauth2-key-save-on-create \
                    --db-in-memory \
                    --create-default-target-of-evaluation \
                    --api-port 8080 2>&1 | tee /var/log/confirmate.log"

# 3) Verify
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/v1/auth/certs   # → 200
```

Test instance values to use in step 2 of Quick Start:

- `confirmate.endpoint`: `http://<host>:8080`
- `auth.client_id` / `client_secret`: `confirmate` / `confirmate`
- `evidence.target_of_evaluation_id`: `00000000-0000-0000-0000-000000000000`

> In-memory DB: data is lost on restart. For persistent deployments
> use a Postgres backend (drop the `--db-in-memory` flag and add
> `--db-host` / `--db-port` / `--db-user` / `--db-password` /
> `--db-name`).

---

## Acknowledgments

<img src="https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg" alt="EU Flag" width="50" align="left" style="margin-right: 10px;">

This project has received funding from the European Union's Horizon
Europe research and innovation programme under grant agreement No.
**101120688** ([EMERALD](https://emerald-he.eu)).

**Partners:** [Fraunhofer AISEC](https://www.aisec.fraunhofer.de/) — Confirmate + EUCS · [OpenNebula Systems](https://opennebula.io) — cloud management + addon · [CaixaBank](https://www.caixabank.com) — Pilot 4 validation

## License

Apache License 2.0. See [LICENSE](LICENSE).
