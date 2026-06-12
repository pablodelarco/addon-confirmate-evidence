# Changelog

All notable changes to addon-confirmate-evidence will be documented in this file.

## [Unreleased] — Production readiness (Keycloak + HTTPS)

Hardening for a real EMERALD deployment, where the Evidence Store, Orchestrator
and Keycloak are separate HTTPS hosts and auth is issued by **Keycloak** (not
Confirmate's embedded OAuth). The OAuth2 client_credentials protocol and the
HTTPS request path were already correct; these changes are configuration,
defensive guards, and docs.

### Added
- CXB OpenNebula custom-control evidence (CIS), emitted as `virtualMachine.labels`
  so custom metrics can evaluate them (raw XML stays attached for audit):
  `diskEncryption` (CIS 4.3 vmdisk_encryption), `publicIp` (CIS 4.4
  public_ip_adress — spelling as in the CXB catalogue), and `sshRestricted` / `rdpRestricted` (CIS 9.2 / 9.3),
  computed from the VM's NIC security-group inbound rules. The VM hook fetches
  the referenced security groups via `onesecgroup show -x` (id integer-sanitised,
  best-effort) and passes them to `map_vm(sg_xml_by_id:)`. New public helper
  `OntologyMapper.security_group_ids`. The IAM/system-level controls in the CXB
  catalogue (mfa_enabled 4.5, key_enforcement 6.3, api_keys_rotation 13.1,
  asset_inventory_enabled 8.5, audit_logging_configurated 8.6) are out of the
  per-resource hook scope and need a separate collector / Tecnalia coordination.
- `confirmate.tls.ca_file` config key: trust an extra CA bundle **in addition**
  to the host's system roots, for OpenNebula front-ends whose trust store lacks
  the CA that signed the Confirmate/Keycloak certificates. Certificate
  verification (`VERIFY_PEER`) is never weakened. Wired into both the Evidence
  Store client and the token request.
- Fail-fast validation of `evidence.target_of_evaluation_id`: a missing or
  non-UUID value now raises with a clear message instead of silently POSTing
  evidence the orchestrator rejects. The all-zeros placeholder is allowed (it is
  a valid ToE against a local `--create-default-target-of-evaluation`
  orchestrator) but logs a loud warning.
- Config file now ships a clearly-labeled **local-testing** block plus a
  commented **production template** (Keycloak token endpoint shape). README gains
  a Keycloak-fronted production configuration section.

### Changed
- De-staled `token_manager.rb` docs: the token endpoint is an OpenID Connect
  provider (Keycloak in production, Confirmate's embedded server locally), not
  specifically "Confirmate's embedded OAuth server".

### Fixed
- `ConfirmateClient#store_evidence`: a success response with an empty or
  non-JSON body no longer falls through to the retry loop (the
  `return ... rescue {}` modifier aborted the return), which re-POSTed stored
  evidence and then raised a spurious failure.
- SSH/RDP labels are now emitted only when **every** security group referenced
  by the VM's NICs was fetched and parsed; with partial coverage the missing
  group could contain the exposing rule, so the labels are omitted (with a
  warning) instead of claiming false compliance. `parse_inbound_rules` returns
  `nil` for unreadable XML vs `[]` for a genuinely rule-less group.
- The NIC hook now passes security-group data when re-submitting VM evidence
  (via the new shared `OntologyMapper.fetch_sg_xml_by_id`), so NIC attach/detach
  no longer erases the `sshRestricted`/`rdpRestricted` labels.
- Tests: replaced two tautological assertions (NIC exposure, diskEncryption)
  with exact ones; added coverage for the all-disks-encrypted true branch and
  the partial/malformed security-group cases. Example payloads in `examples/`
  regenerated to the current evidence shape (labels included).
- README aligned with the shipped code: VM labels documented, `vmImage`
  `labels.publicAccess`, CIS table updated (4.3/4.4/9.2/9.3 label-based;
  8.5/8.6 marked partial), placeholder-ToE wording, test counts.
- `vmImage` evidence no longer sends `publicAccess`: checked against the current
  upstream spec (`core/api/evidence/openapi.yaml`), `publicAccess` exists only on
  `FileStorage`/`ObjectStorage`, not on `confirmate.ontology.v1.VMImage`. The
  OpenNebula `PERMISSIONS/OTHER_U` flag is now emitted as a label
  (`vmImage.labels.publicAccess`), so a strict Evidence Store cannot reject image
  evidence for an unknown field. VM, NetworkInterface and VirtualNetwork field
  names were re-verified against the same spec and need no changes.

### Added (EMERALD mini-audit metric binding)
- NetworkInterface evidence now carries `accessRestriction.l3Firewall`
  (`enabled`, `restrictedPorts`) computed from the NIC's security-group
  inbound rules — `restrictedPorts` is `"22"` exactly when SSH is blocked from
  an unrestricted source, matching the deployed EMERALD `RestrictSSH` metric
  (security-metrics PR #325), which evaluates
  `networkInterface.accessRestriction.l3Firewall.restrictedPorts == "22"`.
  Scoped to SSH on purpose: the metric uses strict string equality, so a
  broader list ("22,3389") would fail a compliant NIC; RDP state remains in
  the VM's `labels.rdpRestricted`. Omitted under the same integrity rule as
  the VM labels (no/partial SG coverage -> unknown -> absent).
  `VirtualMachinePublicIpDisabled` (same PR) evaluates
  `virtualMachine.internetAccessibleEndpoint == false`, which the addon
  already emits unchanged.

### Hardening (full-repo scan follow-up)
- Evidence Store client: trailing slash in `confirmate.endpoint` no longer
  produces `//v1/...` request paths; HTTP 409 (deterministic-UUID dedup) is
  treated as "already stored" success; any other 4xx fails fast instead of
  being retried (retrying a deterministic rejection cannot help); 5xx still
  retries with backoff. New `tests/test_confirmate_client.rb` pins this
  retry/status contract with stubbed responses (no network).
- Evidence IDs are now generated with a strict RFC 4122 §4.3 UUIDv5
  implementation on Ruby stdlib only. The previous code preferred
  `Digest::UUID` (an ActiveSupport extension absent from stock Ruby) and fell
  back to a non-conformant manual digest, so IDs could differ between hosts.
- ToE guard coerces non-String YAML values before validating, so a typo'd
  config reports the curated error instead of a `NoMethodError`.
- NICs with a global-unicast IPv6 address (`IP6_GLOBAL`) are now classified as
  internet-accessible.
- All four hooks: dependency `require` failures now log and exit 0 (never
  block OpenNebula operations), an empty stdin pipe falls back to ARGV, and
  the no-input-at-all path also exits 0 instead of 1, completing the
  "every error path exits 0" contract.
- `uninstall.sh` matches hooks by exact name (no substring multi-ID deletes),
  survives non-interactive runs, and removes the `.conf.new` leftover;
  `install.sh` hook-name extraction no longer relies on GNU-only sed syntax.
- Removed the dead `OntologyMapper#map_security_group` (never wired to a hook;
  its rule shape did not match the current `NetworkSecurityGroup` schema) and
  the unused `nic_template.xml` fixture.

## [0.2.0] - 2026-05-21

### Changed — Clouditor → Confirmate migration

Clouditor has been replaced by its successor [Confirmate](https://github.com/confirmate/confirmate).
This release migrates the addon end-to-end. For install + use
instructions, see [README.md](README.md).

- Library, hooks, templates, config file, and the `hook-*` names renamed
  from `clouditor_*` / `hook-clouditor-*` to `confirmate_*` / `hook-confirmate-*`.
- Config: top-level `clouditor:` key is now `confirmate:`. Default endpoint
  moves from `:8082` to Confirmate's `:8080`. `evidence.cloud_service_id`
  renamed to `evidence.target_of_evaluation_id` (back-compat read of the
  old key is kept for one release).
- Auth: Confirmate uses OAuth 2.0 **client_credentials**. Replaced the old
  JSON `{username,password}` flow with the standard form-encoded
  `grant_type=client_credentials` + HTTP Basic. New `auth.enabled` toggle
  that mirrors the orchestrator's `--auth-enabled` flag: when off, the
  addon omits the `Authorization` header entirely (matches the default
  `--db-in-memory` local test path). The JWT-payload Base64 decode is gone;
  `expires_in` from the OAuth response is now authoritative.
- Evidence shape: the StoreEvidence REST endpoint expects the Evidence
  message as the HTTP body (per `body: "evidence"` annotation in
  `evidence_store.proto`). Dropped the outer `{"evidence": …}` wrapper.
- Evidence field renames:
  - `cloudServiceId` → `targetOfEvaluationId`
  - `raw` moved from the Evidence envelope onto the ontology resource
    (`virtualMachine.raw`, `networkInterface.raw`, etc.).
- VirtualMachine ontology renames (`confirmate.ontology.v1.VirtualMachine`):
  `networkInterfaces` → `networkInterfaceIds` (IDs only); `blockStorage` →
  `blockStorageIds`; `autoUpdates` → `automaticUpdates`; `publicIp` →
  `internetAccessibleEndpoint`. The `atRestEncryption` field is no longer
  a VM-level property; the algorithm + enabled flag remain in the
  attached `raw` XML.
- NetworkInterface no longer has typed fields for `ip` or
  `accessRestriction.securityGroups`; these move to `labels` (a proto
  `map<string,string>`) so they stay queryable. New
  `internetAccessibleEndpoint` boolean.
- Tests rewritten to assert on the new shape; new `tests/smoke.rb` runs
  end-to-end against a live Confirmate (skips when none reachable).

### Fixed

- `epoch_to_rfc3339` was referenced but never defined; added a small
  implementation (`Time.at(secs).utc.strftime`) so tests pass.
- `Digest::UUID` access on Ruby 2.6 raises `LoadError`/`NameError` (not
  `NoMethodError`); the rescue now covers all three and falls back to
  manual SHA1 UUIDv5.

### Removed

- The Clouditor-era `demo/` directory (Docker Compose + setup scripts)
  has been dropped. For local testing, follow the upstream Confirmate
  recipe in README "Appendix A".

## [0.1.0] - 2026-03-10

### Added
- Initial release for EMERALD GA #7 at Fraunhofer AISEC
- VM state hooks (RUNNING, POWEROFF, DONE)
- NIC attach/detach API hooks
- Image state hooks (READY)
- Network creation API hooks
- Ontology mapper for VirtualMachine, NetworkInterface, VMImage, VirtualNetwork, NetworkSecurityGroup
- OAuth2 token management with automatic refresh
- HTTP client with retry logic and exponential backoff
- Demo environment with Docker Compose and Clouditor setup scripts
- Sample evidence payloads for compliant and non-compliant VMs
- Unit tests for ontology mapper and token manager
- Install/uninstall scripts with hook registration
- EUCS/CIS control coverage: CIS 4.3, 4.4, 8.3, 8.5, 8.6, 9.2, 9.3
