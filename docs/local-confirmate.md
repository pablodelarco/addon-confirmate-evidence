# Local Confirmate for testing

Use this when you do not have a Confirmate deployment yet. It starts an
in-memory test instance on any Linux host that the OpenNebula front-end can
reach.

```bash
# 1) Install Go 1.26 or later
curl -fsSL -O https://go.dev/dl/go1.26.3.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.26.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 2) Clone, build and run
git clone --recurse-submodules https://github.com/confirmate/confirmate
cd confirmate/core
go build -o bin/confirmate ./cmd/confirmate
tmux new-session -d -s confirmate -c "$(pwd)" \
  "./bin/confirmate --auth-enabled --oauth2-embedded \
                    --oauth2-key-save-on-create \
                    --db-in-memory \
                    --create-default-target-of-evaluation \
                    --api-port 8080 2>&1 | tee /var/log/confirmate.log"

# 3) Check that it answers
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/v1/auth/certs   # 200
```

Use these values in `/etc/one/confirmate-evidence.conf`.

| Parameter | Value |
|---|---|
| `confirmate.endpoint` | `http://<host>:8080` |
| `confirmate.auth.enabled` | `true` |
| `confirmate.auth.client_id`, `client_secret` | `confirmate`, `confirmate` |
| `evidence.target_of_evaluation_id` | `00000000-0000-0000-0000-000000000000` |

The add-on accepts the all-zeros ToE with a warning. It works only against this
local default orchestrator.

The in-memory database loses its data on restart. For a persistent instance,
drop `--db-in-memory` and add `--db-host`, `--db-port`, `--db-user`,
`--db-password` and `--db-name` for a Postgres backend.

## Send a test evidence

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
sudo -u oneadmin onevnet delete $VNET_ID
```

The log should show `Evidence ... stored successfully (HTTP 200)`.

## Read the assessment results

```bash
ACCESS=$(curl -sS -u confirmate:confirmate \
  -d 'grant_type=client_credentials' \
  http://<host>:8080/v1/auth/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

curl -sS -H "Authorization: Bearer $ACCESS" \
  http://<host>:8080/v1/orchestrator/assessment_results \
  | python3 -m json.tool
```

Each result points to its evidence by ID.

```json
{
  "metricId": "...",
  "compliant": true,
  "evidenceId": "...",
  "resourceId": "one-vm-42",
  "targetOfEvaluationId": "..."
}
```

An empty `{}` usually means the account cannot read the ToE. A service client
like the one the add-on uses can send evidence but often cannot read results,
so query with the EMERALD UI account or an administrator.

## Smoke test

`tests/smoke.rb` posts one evidence end to end and is skipped when no
Confirmate is reachable. It reads `CONFIRMATE_URL`, `TOE_ID`,
`CONFIRMATE_AUTH=on`, `CONFIRMATE_CLIENT_ID` and `CONFIRMATE_CLIENT_SECRET`.
