# Troubleshooting

## Hooks are missing after install

`onehook create` fails with `argument 0 must be one of file` when `oneadmin`
cannot read the template, for example under `/root`. Copy the templates to
`/tmp` and register them from there.

```bash
sudo cp templates/*.tmpl /tmp/
sudo chmod 644 /tmp/hook-*.tmpl
sudo -u oneadmin sh -c 'for t in /tmp/hook-*.tmpl; do onehook create "$t"; done'
sudo -u oneadmin onehook list | grep -c hook-confirmate   # expect 12
```

## HTTP 401 Unauthorized

The `client_id` or `client_secret` is wrong, or `auth.enabled` does not match
the server. With Keycloak, check that `token_url` points to the right realm.

## HTTP 400 with a validation message

`target_of_evaluation_id` is not a real ToE. Copy the "Target ID" from the ToE
"Information" tab in the EMERALD UI.

## A hook runs but no evidence is stored

The POST failed. Check that the front-end reaches the server.

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://<evidence-store-host>/v1/auth/certs
```

Anything other than `200` is a network, DNS or firewall problem. If it is
`200`, set `logging.level: debug` to see the full HTTP response.

## NIC attach and detach hooks do not run

On OpenNebula 7.2 the hook validator and the API use different method names
for these calls, so the NIC hooks never fire. No evidence is lost, because the
VM returns to RUNNING after the change and the VM hook sends the VM and its
NICs again.

## Confirmate log shows `Stream restarted ... err="EOF"`

Long-running Confirmate processes can lose their internal streams. Evidence is
still stored but assessment results may stop. Restart Confirmate, and use a
Postgres backend so the data survives the restart.

## Useful commands

```bash
sudo tail -20 /var/log/one/confirmate-evidence.log
sudo -u oneadmin onehook log --since $(date -d '1 hour ago' +%m/%d) | head -30
```
