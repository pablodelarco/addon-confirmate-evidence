# Tutorial — Install and use addon-confirmate-evidence

A step-by-step walkthrough that takes you from a fresh OpenNebula
Front-End to **live compliance evidence flowing into Confirmate** in
about 15 minutes.

If you want a one-paragraph overview of *what* this does, see
[README.md](README.md). This page is for *doing* it.

---

## What you'll have when you're done

```
   Real action in OpenNebula            evidence            compliance verdict
   ────────────────────────             ────────            ──────────────────

   $ onevm create my.tmpl       ──>    addon hook    ──>   Confirmate stores
   $ onevm nic-attach 42 -n 0          fires                evidence + runs
   $ oneimage create disk.tmpl                              Rego policies
   $ onevnet create net.tmpl                                produces verdicts
                                                            (visible in EMERALD UI)
```

Concretely: every time a VM, NIC, image, or virtual network changes
state in OpenNebula, a small Ruby script wakes up, packages the
resource as JSON, and POSTs it to Confirmate. Confirmate evaluates
EUCS/CIS metrics against the evidence and produces verdicts. The
EMERALD UI is the consumer of those verdicts.

You install **only this addon** on your OpenNebula Front-End. Confirmate
runs somewhere reachable (consortium-hosted, or a local test instance).

---

## Before you start

You need:

- An **OpenNebula Front-End** with `onehook`, `onevm`, `oneimage`,
  `onevnet`, `oneadmin` user. Tested on OpenNebula 7.2; should work
  on 6.x+.
- Root (or `sudo`) on that host.
- A reachable **Confirmate** orchestrator URL. Either:
  - **production**: the consortium's URL + the OAuth client credentials
    EMERALD gave you, or
  - **testing**: bring one up locally with §0 below.
- The **Target of Evaluation (ToE) UUID** for your environment. In
  production this is created in the EMERALD UI. For local testing
  the default ToE has UUID `00000000-0000-0000-0000-000000000000`.

Total time: ~15 minutes.

---

## §0 — (Optional) Bring up a local Confirmate for testing

Skip this section if you already have a Confirmate URL.

This sets up Confirmate's all-in-one server in-memory. Run it on any
Linux box that the OpenNebula Front-End can reach (it does NOT have
to be the same host — but it can be).

```bash
# 1) Install Go 1.26+
curl -fsSL -O https://go.dev/dl/go1.26.3.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.26.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version    # should print go1.26.3

# 2) Clone Confirmate (with the security-metrics submodule)
git clone --recurse-submodules https://github.com/confirmate/confirmate
cd confirmate/core

# 3) Build the all-in-one binary
go build -o bin/confirmate ./cmd/confirmate

# 4) Run it in a tmux session so you can detach
tmux new-session -d -s confirmate -c "$(pwd)" \
  "./bin/confirmate \
     --auth-enabled \
     --oauth2-embedded \
     --oauth2-key-save-on-create \
     --db-in-memory \
     --create-default-target-of-evaluation \
     --api-port 8080 2>&1 | tee /var/log/confirmate.log"

# 5) Verify it's listening
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/v1/auth/certs
# expect: 200
```

✅ **What success looks like.** `curl ... /v1/auth/certs` returns `200`.
`tmux ls` shows the `confirmate` session. Tail
`/var/log/confirmate.log` and you'll see
`Starting Connect server address=0.0.0.0:8080`.

The default service-account credentials for this test instance are
`client_id=confirmate` / `client_secret=confirmate`. Keep them for
the addon config below.

> **Note.** This is an in-memory test instance. Data is lost on
> restart. Long-running instances may need an occasional restart —
> see [Troubleshooting](#troubleshooting).

---

## §1 — Install the addon on your OpenNebula Front-End

```bash
# As root on the OpenNebula Front-End
cd /root  # or anywhere writable by root
git clone https://github.com/pablodelarco/addon-confirmate-evidence
cd addon-confirmate-evidence

# Run the installer
sudo ./install.sh
```

The installer:
- copies `lib/*.rb` to `/var/lib/one/remotes/hooks/confirmate-evidence/lib/`
- copies `hooks/*.rb` to `/var/lib/one/remotes/hooks/`
- copies the default config to `/etc/one/confirmate-evidence.conf`
  (only if it doesn't already exist)
- creates `/var/log/one/confirmate-evidence.log` owned by `oneadmin`
- attempts to register the 7 hooks via `onehook create`

✅ **What success looks like.** The installer ends with
`Installation complete!`. `ls /var/lib/one/remotes/hooks/confirmate_*.rb`
shows 4 files (`confirmate_vm_evidence.rb`,
`confirmate_nic_evidence.rb`, `confirmate_image_evidence.rb`,
`confirmate_net_evidence.rb`).

> **If hook registration fails** with a cryptic
> `command create: argument 0 must be one of file`, the
> templates were unreachable by `oneadmin`. See
> [Troubleshooting](#troubleshooting).

---

## §2 — Configure the addon

Edit `/etc/one/confirmate-evidence.conf`. The three fields you must
review:

```yaml
confirmate:
  endpoint: "http://CONFIRMATE-HOST:8080"     # 1) your Confirmate URL

  auth:
    enabled: true                              # 2) true in production
    token_url: "http://CONFIRMATE-HOST:8080/v1/auth/token"
    client_id: "confirmate"                    # 3) your OAuth client ID
    client_secret: "confirmate"                #    and secret

evidence:
  tool_id: "opennebula-addon-confirmate-evidence"
  target_of_evaluation_id: "PASTE-TOE-UUID-HERE"
  default_region: "eu-south-1"

logging:
  level: "info"
  file: "/var/log/one/confirmate-evidence.log"
```

| Field | What to put |
|---|---|
| `confirmate.endpoint` | Your Confirmate URL. For the local test instance from §0, `http://localhost:8080`. |
| `confirmate.auth.enabled` | `true` if Confirmate runs with `--auth-enabled` (any production deployment). `false` only for a quick local test where you don't want to bother with tokens. |
| `confirmate.auth.client_id` / `client_secret` | Credentials EMERALD gave you. For a local test instance the defaults `confirmate`/`confirmate` work. |
| `evidence.target_of_evaluation_id` | The ToE UUID for your environment. Created in the EMERALD UI. For a local test instance run with `--create-default-target-of-evaluation`, the value is `00000000-0000-0000-0000-000000000000`. |

After editing:

```bash
sudo chown oneadmin:oneadmin /etc/one/confirmate-evidence.conf
sudo chmod 640 /etc/one/confirmate-evidence.conf
```

✅ **What success looks like.** `sudo -u oneadmin cat
/etc/one/confirmate-evidence.conf` displays the file. (If it doesn't,
file ownership is wrong — fix with the `chown` above.)

---

## §3 — Verify the hooks are registered

```bash
sudo -u oneadmin onehook list
```

You should see seven `hook-confirmate-*` entries (some columns may be
truncated; that's cosmetic):

```
  ID NAME                          TYPE
  12 hook-confirmate-vm-poweroff   state
  11 hook-confirmate-vm-done       state
  10 hook-confirmate-nic-detach    api
   9 hook-confirmate-nic-attach    api
   8 hook-confirmate-net-create    api
   7 hook-confirmate-image-ready   state
   6 hook-confirmate-vm-running    state
```

If hooks did not register during `install.sh`, register them by hand:

```bash
# Stage templates somewhere oneadmin can read (NOT under /root/)
sudo cp /root/addon-confirmate-evidence/templates/*.tmpl /tmp/
sudo chmod 644 /tmp/hook-*.tmpl
sudo -u oneadmin sh -c 'for t in /tmp/hook-*.tmpl; do onehook create "$t"; done'
```

✅ **What success looks like.** `onehook list` shows seven entries.

---

## §4 — First end-to-end test (1 piece of evidence)

The fastest way to confirm the chain works is to trigger the
**net-create** hook with a throwaway virtual network. This avoids
spinning up a real VM:

```bash
# Empty the addon log so the test output is easy to read
sudo truncate -s0 /var/log/one/confirmate-evidence.log

# Create a throwaway VNet
cat <<'EOF' | sudo -u oneadmin tee /tmp/test-vnet.tmpl > /dev/null
NAME   = "confirmate-tutorial-test"
VN_MAD = "dummy"
BRIDGE = "br-test"
AR = [ TYPE = "IP4", IP = "192.0.2.0", SIZE = "4" ]
EOF
sudo chmod 644 /tmp/test-vnet.tmpl
VNET_ID=$(sudo -u oneadmin onevnet create /tmp/test-vnet.tmpl | grep -oP 'ID: \K[0-9]+')
echo "Created vnet $VNET_ID"
sleep 3

# Watch the addon log
sudo tail -20 /var/log/one/confirmate-evidence.log

# Cleanup
sudo -u oneadmin onevnet delete $VNET_ID
```

✅ **What success looks like.** Your addon log shows:

```
INFO -- : Network evidence hook triggered
INFO -- : Network creation detected: VNet 13
INFO -- : Sending evidence ... (virtualNetwork: one-vnet-13)
INFO -- : TokenManager: token obtained, expires at ...
INFO -- : Evidence ... stored successfully (HTTP 200)
INFO -- : Network evidence hook completed
```

The key line is `Evidence ... stored successfully (HTTP 200)`. That's
the moment the addon's evidence reached Confirmate.

> **If you see `401 Unauthorized`** repeatedly, your
> `confirmate.auth.client_id` / `client_secret` are wrong. Fix the
> config and try again — no need to re-register hooks.

---

## §5 — Day-to-day: what fires automatically

Once installed and configured, you don't run anything by hand. The
addon reacts to OpenNebula events:

| OpenNebula action | Hook | Evidence sent |
|---|---|---|
| VM enters RUNNING | `hook-confirmate-vm-running` | VirtualMachine + each NetworkInterface |
| VM enters POWEROFF | `hook-confirmate-vm-poweroff` | updated VirtualMachine |
| VM is terminated | `hook-confirmate-vm-done` | final VirtualMachine state |
| `onevm nic-attach` | (covered by vm-running re-firing) | updated VirtualMachine + NICs |
| `onevm nic-detach` | (covered by vm-running re-firing) | updated VirtualMachine + NICs |
| Image reaches READY | `hook-confirmate-image-ready` | VMImage |
| `onevnet create` | `hook-confirmate-net-create` | VirtualNetwork |

Existing VMs are **not** re-scanned retroactively. The hooks fire on
*future* state transitions only.

To watch evidence flow live, tail the log:

```bash
sudo tail -f /var/log/one/confirmate-evidence.log
```

---

## §6 — (Optional) See compliance verdicts in Confirmate

Once Confirmate has received some evidence, it runs Rego policies
against it and produces verdicts. To see them:

```bash
# Get an admin token (for production, use the EMERALD UI's auth flow
# or whatever credentials your operator provides)
ACCESS=$(curl -sS -u <client-id>:<client-secret> \
  -d 'grant_type=client_credentials' \
  http://CONFIRMATE-HOST:8080/v1/auth/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

# List verdicts
curl -sS -H "Authorization: Bearer $ACCESS" \
  http://CONFIRMATE-HOST:8080/v1/orchestrator/assessment_results \
  | python3 -m json.tool
```

✅ **What you should see.** A `"results": [...]` array, with one
entry per (evidence, applicable metric) pair. Each entry has:

```json
{
  "metricId":  "...",
  "compliant": true,            // or false
  "evidenceId": "...",          // links back to the submitted evidence
  "resourceId": "one-vm-42",
  "resourceTypes": ["VirtualMachine", "Compute", ...],
  "complianceComment": "The result of the metric shows that the evidence is compliant to the target value.",
  "targetOfEvaluationId": "..."
}
```

> **Why might `assessment_results` look empty?**
> The service-account credentials (the same `client_id` /
> `client_secret` the addon uses) are typically scoped to "push
> evidence", not "read verdicts". The list endpoint filters by user
> permissions on the ToE, so a push-only account sees `{}`. The
> EMERALD UI logs in as a user that has read permission on the ToE
> and will see verdicts normally. For an ops-side check, query with
> an admin / UI-user account.

---

## Daily operation cheat sheet

```bash
# Is the addon healthy?
sudo tail -20 /var/log/one/confirmate-evidence.log

# Which hooks fired recently, and did they succeed?
sudo -u oneadmin onehook log --since $(date -d '1 hour ago' +%m/%d) | head -30

# Is Confirmate reachable from the OpenNebula Front-End?
curl -sS -o /dev/null -w "%{http_code}\n" http://CONFIRMATE-HOST:8080/v1/auth/certs
# expect 200

# Restart Confirmate (if you run it locally and it's been up for many hours)
ssh CONFIRMATE-HOST 'tmux kill-session -t confirmate; <re-run the tmux command from §0>'
```

---

## Troubleshooting

Each of these is a real error message you may hit, with the actual
cause and fix.

### `command create: argument 0 must be one of file`

You ran `onehook create somefile.tmpl` (directly or via `install.sh`)
and the templates live somewhere `oneadmin` can't read — typically
`/root/...` (mode 700). The error message is misleading; the real
cause is `Permission denied` on the file.

**Fix.** Copy the templates somewhere world-readable first:

```bash
sudo cp /root/addon-confirmate-evidence/templates/*.tmpl /tmp/
sudo chmod 644 /tmp/hook-*.tmpl
sudo -u oneadmin sh -c 'for t in /tmp/hook-*.tmpl; do onehook create "$t"; done'
```

### `Evidence ... HTTP 401 Unauthorized` in the addon log

The token request to Confirmate succeeded but the bearer token was
rejected on `POST /v1/evidence_store/evidence`. Almost always:

- `confirmate.auth.client_id` or `client_secret` in the config is
  wrong, or
- Confirmate was started without `--auth-enabled` but the addon has
  `auth.enabled: true` (or vice versa).

**Fix.** Reconcile the two ends.

### `Evidence ... HTTP 400` with a field validation message

The JSON body Confirmate sees is rejected by its validator. Most
commonly the `target_of_evaluation_id` value is not a valid UUID, or
the placeholder `"00000000-..."` was left in place against a
production Confirmate that has a different default ToE.

**Fix.** Paste the real ToE UUID from the EMERALD UI into
`evidence.target_of_evaluation_id`.

### The hook fires (you see "hook triggered" in the addon log) but no `Evidence stored successfully` line follows

The addon connected to Confirmate but the POST failed silently. Try:

```bash
# Quick reachability check from the OpenNebula Front-End:
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://CONFIRMATE-HOST:8080/v1/auth/certs
```

If that's not `200`, you have a network / DNS / firewall problem
between the Front-End and Confirmate. If it IS `200`, set
`logging.level: debug` in the config, fire one more event, and the
log will show the exact HTTP response Confirmate returned.

### Confirmate log spam: `Stream restarted ... err="unknown: write envelope: EOF"`

A long-running (many hours) Confirmate process degrades its internal
streams. Evidence ingestion still works, but assessment verdicts may
not flow through to the orchestrator's results table.

**Fix.** Restart Confirmate. With the test setup from §0:

```bash
tmux kill-session -t confirmate
# then re-run the tmux new-session command from §0
```

This loses any in-memory data (use a Postgres backend for persistent
production deployments).

### `GET /v1/orchestrator/assessment_results` returns `{}` even though I see evidence in the log

That endpoint filters by user permission on the ToE. Service-account
credentials (which the addon uses) don't have read permission on the
ToE by default. Query the endpoint with the same account the EMERALD
UI uses, or grant the service account explicit read access.

### `nic-attach` / `nic-detach` events don't show up as dedicated NIC evidence

On OpenNebula 7.2 the dedicated NIC API hooks don't fire (the hook
validator and the API dispatcher use different method names for the
same operation). **You don't lose data**: when the VM transitions
back to RUNNING after the hot-plug, the VM state hook re-fires and
re-emits the VM + NIC evidence with the new NIC list. Check
`/var/log/one/confirmate-evidence.log` after a `nic-attach` — you'll
see the re-emission within a few seconds.

---

## Uninstall

```bash
cd /root/addon-confirmate-evidence
sudo ./uninstall.sh
```

The script removes the 7 hooks, the library and hook scripts, and
asks before removing `/etc/one/confirmate-evidence.conf`. Logs at
`/var/log/one/confirmate-evidence.log` are not deleted.

---

## Where to go next

- Look at `examples/evidence-vm-payload.json` and
  `evidence-nic-payload.json` to see the exact JSON the addon sends.
- Tests: `ruby tests/test_ontology_mapper.rb` and
  `ruby tests/test_token_manager.rb` (no live server needed).
- End-to-end smoke test: `tests/smoke.rb` — see header comments for
  env vars.
- Field mapping (which ONE XML elements map to which ontology
  fields) is in [README.md](README.md) under "Resource Mapping".
