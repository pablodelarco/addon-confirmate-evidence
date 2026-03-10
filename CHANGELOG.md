# Changelog

All notable changes to addon-clouditor-evidence will be documented in this file.

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
