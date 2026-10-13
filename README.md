# addon-confirmate-evidence

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-%E2%89%A5%206.x-brightgreen)](https://opennebula.io)
[![EMERALD](https://img.shields.io/badge/EU-EMERALD%20Horizon%20Europe-yellow)](https://emerald-he.eu)

This add-on collects security evidence from an [OpenNebula](https://opennebula.io)
cloud and sends it to [Confirmate](https://github.com/confirmate/confirmate), the
compliance engine from Fraunhofer AISEC. Confirmate checks the evidence against
EUCS and CIS metrics, and the results appear in the EMERALD UI.

```text
[OpenNebula front-end] --hooks--> [this add-on] --HTTPS POST--> [Confirmate Evidence Store] --> [EMERALD UI]
```

OpenNebula hooks run the add-on every time a VM, NIC, image, network, user or
datastore changes. The add-on maps the resource to the Confirmate ontology,
removes passwords, tokens and 2FA secrets from the raw XML, and posts the
evidence with an OAuth2 token.

## Install

You need an OpenNebula front-end (6.x or later), the URL of a Confirmate Evidence
Store and an OAuth2 client for it. To test without a real deployment, start a
local Confirmate first with [docs/local-confirmate.md](docs/local-confirmate.md).

```bash
git clone https://github.com/pablodelarco/addon-confirmate-evidence
cd addon-confirmate-evidence
sudo ./install.sh
```

The installer copies the scripts to `/var/lib/one/remotes/hooks/`, the
configuration to `/etc/one/confirmate-evidence.conf`, and registers 12 hooks.

## Configure

Edit `/etc/one/confirmate-evidence.conf`. In an EMERALD deployment, Keycloak
issues the token, so ask the platform operator for a service client.

```yaml
confirmate:
  endpoint: "https://<evidence-store-host>"
  auth:
    enabled: true
    token_url: "https://<keycloak-host>/realms/<realm>/protocol/openid-connect/token"
    client_id: "<service-client-id>"
    client_secret: "<service-client-secret>"

evidence:
  target_of_evaluation_id: "<ToE UUID from the EMERALD UI>"
```

```bash
sudo chown oneadmin:oneadmin /etc/one/confirmate-evidence.conf
sudo chmod 640 /etc/one/confirmate-evidence.conf
```

| Parameter | Description | Default |
|---|---|---|
| `confirmate.endpoint` | Evidence Store URL | `http://localhost:8080` |
| `confirmate.auth.enabled` | Send a bearer token | `false` |
| `confirmate.auth.token_url` | OAuth2 token endpoint | `http://localhost:8080/v1/auth/token` |
| `confirmate.auth.client_id`, `client_secret` | OAuth2 client | `confirmate`, `confirmate` |
| `confirmate.auth.static_token` | Fixed bearer token instead of OAuth2 (testing) | empty |
| `confirmate.tls.ca_file` | Extra CA bundle, added to the system roots | empty |
| `evidence.target_of_evaluation_id` | ToE UUID (required) | all-zeros placeholder |
| `evidence.additional_target_of_evaluation_ids` | Other ToEs that receive a copy of every evidence | empty |
| `evidence.tool_id` | Tool name sent with every evidence | `opennebula-addon-confirmate-evidence` |
| `evidence.default_region` | Region label | `eu-south-1` |
| `evidence.logrotate_path` | Logrotate file used to report log retention | `/etc/logrotate.d/opennebula` |
| `logging.level`, `logging.file` | Add-on log | `info`, `/var/log/one/confirmate-evidence.log` |

The add-on does not start if `target_of_evaluation_id` is missing or is not a
UUID.

## Check that it works

```bash
sudo -u oneadmin onehook list | grep -c hook-confirmate   # expect 12
sudo tail -f /var/log/one/confirmate-evidence.log
```

Create or change any resource, for example a test virtual network. The log
shows `Evidence ... stored successfully (HTTP 200)` when the evidence reaches
Confirmate.

## What the add-on collects

Hooks react to changes, so existing resources are sent the next time they
change state.

| OpenNebula event | Evidence sent |
|---|---|
| VM enters RUNNING or POWEROFF, or is terminated | VirtualMachine, one NetworkInterface per NIC, one BlockStorage per disk |
| NIC attached or detached | The VM is sent again when it returns to RUNNING |
| Image becomes READY | VMImage |
| Virtual network created | VirtualNetwork |
| User created or updated | Identity |
| Datastore created, updated or permissions changed | ObjectStorage |

The evidence covers disk encryption, public IPs, SSH and RDP exposure in
security groups, backups, log retention, MFA for administrators and public
access to images and datastores.
[docs/mapping.md](docs/mapping.md) lists every field and the controls it
supports.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `HTTP 401` in the add-on log | Wrong `client_id` or `client_secret`, or `auth.enabled` does not match the server |
| `HTTP 400` with a validation message | `target_of_evaluation_id` is not a real ToE. Copy it from the EMERALD UI |
| Fewer than 12 hooks registered | Register the templates by hand, as shown in [docs/troubleshooting.md](docs/troubleshooting.md) |

[docs/troubleshooting.md](docs/troubleshooting.md) covers the other cases.

## Tests

```bash
ruby tests/test_ontology_mapper.rb
ruby tests/test_token_manager.rb
ruby tests/test_confirmate_client.rb
ruby tests/smoke.rb   # end-to-end POST, skipped if no Confirmate is reachable
```

`sudo ./uninstall.sh` removes the hooks and scripts and asks before it deletes
the configuration.

## Acknowledgments

<img src="https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg" alt="EU Flag" width="50" align="left" style="margin-right: 10px;">

This project has received funding from the European Union's Horizon
Europe research and innovation programme under grant agreement No.
**101120688** ([EMERALD](https://emerald-he.eu)).

**Partners:** [Fraunhofer AISEC](https://www.aisec.fraunhofer.de/) (Confirmate) · [OpenNebula Systems](https://opennebula.io) (OpenNebula and this add-on) · [CaixaBank](https://www.caixabank.com) (Pilot 4 validation)

## License

Apache License 2.0. See [LICENSE](LICENSE).
