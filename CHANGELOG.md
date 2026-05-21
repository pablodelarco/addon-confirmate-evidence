# Changelog

All notable changes to addon-confirmate-evidence will be documented in this file.

## [0.2.0] - 2026-05-21

### Changed — Clouditor → Confirmate migration

Clouditor has been replaced by its successor [Confirmate](https://github.com/confirmate/confirmate).
This release migrates the addon end-to-end. See [MIGRATION.md](MIGRATION.md)
for the gap analysis and ordered plan.

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
  attached `raw` XML pending the long-term decision in MIGRATION.md OQ-2.
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

### Not yet migrated

- `demo/` directory still contains the Clouditor-era Docker setup. Use
  an upstream Confirmate checkout per README "Quick Start" instead.

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
