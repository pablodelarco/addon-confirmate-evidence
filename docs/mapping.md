# Resource mapping

The add-on maps each OpenNebula resource to a type of the Confirmate ontology
(`confirmate.ontology.v1`). Every evidence also carries the raw OpenNebula XML,
with the values of any element or attribute whose name contains `PASSWORD`,
`PASSWD`, `SECRET` or `TOKEN` replaced by `[REDACTED]`. If the XML cannot be
parsed, no raw XML is attached.

## Labels that repeat ontology values

The Evidence Store serialises with protojson, which drops `false` booleans and
empty lists. A non-compliant value would then look like missing evidence in the
EMERALD UI. For this reason the add-on also writes these values as string
labels, for example `labels.backupEnabled = "false"`. The metrics still read the
ontology fields.

## VM to VirtualMachine

| OpenNebula XML | Ontology field | Notes |
|---|---|---|
| `ID` | `id` | `one-vm-{id}` |
| `NAME` | `name` | |
| `STIME` | `creationTime` | Epoch converted to RFC 3339 |
| `NIC` (all) | `networkInterfaceIds` | Each NIC is also sent as its own evidence |
| `DISK` (all) | `blockStorageIds` | Each disk is also sent as its own evidence |
| `NIC/EXTERNAL`, `IP6_GLOBAL` or a non-RFC 1918 IP | `internetAccessibleEndpoint`, `labels.publicIp` | CIS 4.4 |
| `LOG` or `MONITORING` | `bootLogging.enabled`, `osLogging.enabled` | Heuristic |
| Front-end logrotate policy | `bootLogging.retentionPeriod`, `osLogging.retentionPeriod` | `rotate N` times the daily, weekly or monthly cycle, in seconds. Omitted if the file cannot be read |
| None | `automaticUpdates.enabled` | Always `false`, OpenNebula has no source for it |
| `DISK/ENCRYPTION` or `ENCRYPT` | `labels.diskEncryption` | CIS 4.3. `"true"` only when every disk is encrypted |
| Security group inbound rules | `labels.sshRestricted`, `labels.rdpRestricted` | CIS 9.2 and 9.3. See the security group rule below |

## NIC to NetworkInterface

| OpenNebula XML | Ontology field | Notes |
|---|---|---|
| `NIC_ID` | `id` | `one-nic-{vm_id}-{nic_id}` |
| `NETWORK` | `name`, `labels.network` | |
| `IP` | `labels.ip` | The ontology has no IP field |
| `SECURITY_GROUPS` | `labels.securityGroupIds` | |
| `EXTERNAL`, `IP6_GLOBAL` or a non-RFC 1918 IP | `internetAccessibleEndpoint` | |
| Security group inbound rules | `accessRestriction.l3Firewall.enabled` | `true` when the rules were read |
| Security group inbound rules | `accessRestriction.l3Firewall.restrictedPorts` | `22` and `3389` when each one is not reachable from any source. Read by the `RestrictSSH` metric |
| Security group inbound rules | `accessRestriction.l3Firewall.allowedSources` | Sources allowed to reach ports 22 or 3389, as an IP range, `vnet:{id}` or `0.0.0.0/0` |

The hooks read every security group of the VM with `onesecgroup show -x`.
If any group cannot be read, the add-on omits the SSH, RDP and firewall fields,
because the missing group could contain the rule that opens the port.

## Disk to BlockStorage

One evidence per VM disk, with id `one-disk-{vm_id}-{disk_id}` and the VM as
`parentId`.

| Source | Ontology field | Notes |
|---|---|---|
| `DISK/ENCRYPTION` or `ENCRYPT` | `atRestEncryption.customerKeyEncryption.enabled` | CIS 4.3, read by `VirtualMachineDiskEncryptionEnabled` |
| `BACKUPS/BACKUP_IDS` of the VM | `backups[0].enabled` | `true` only when at least one backup has been run. A backup policy that never ran counts as `false` |

## Image to VMImage

| OpenNebula XML | Ontology field | Notes |
|---|---|---|
| `ID` | `id` | `one-image-{id}` |
| `NAME` | `name` | |
| `REGTIME` | `creationTime` | |
| `PERMISSIONS/OTHER_U` | `labels.publicAccess` | `VMImage` has no `publicAccess` field |

## Virtual network to VirtualNetwork

`ID` becomes `one-vnet-{id}`, plus `NAME` and the region label.

## User to Identity

| OpenNebula source | Ontology field | Notes |
|---|---|---|
| Member of the `oneadmin` group (GID 0) | `privileged` | |
| `TEMPLATE/FIREEDGE/TWO_FACTOR_AUTH_SECRET` | `enforceMfa` | FireEdge writes it only when the user enrols a second factor. Read by `AdminMFAEnabled` (CIS 4.5) |
| `ENABLED` | `activated` | |
| `AUTH_DRIVER` | `labels.authDriver`, `labels.federated` | `core` is a local account. `ldap`, `x509` and `saml` are federated (control AIM-02) |

The `serveradmin` account (driver `server_cipher`) is skipped. OneFlow, OneGate
and Sunstone use it internally, and it never enrols a second factor.

## Datastore to ObjectStorage

| OpenNebula XML | Ontology field | Notes |
|---|---|---|
| `ID` | `id` | `one-datastore-{id}` |
| `PERMISSIONS/OTHER_U` | `publicAccess` | Read by `ObjectStoragePublicAccessDisabled` |
| `PERMISSIONS/OTHER_M`, `OTHER_A` | `labels.otherManage`, `labels.otherAdmin` | |
| `TYPE` | `labels.datastoreType` | |

## EUCS and CIS controls

| Control | Evidence |
|---|---|
| CIS 4.3, VM disk encryption | BlockStorage `atRestEncryption`, VM `labels.diskEncryption` |
| CIS 4.4, no public IP | VM and NIC `internetAccessibleEndpoint` |
| CIS 4.5, MFA for administrators | Identity `enforceMfa`, `privileged` |
| CIS 8.3, storage not public | ObjectStorage `publicAccess`, VMImage `labels.publicAccess` |
| CIS 8.5, asset inventory | Partial. One evidence per resource, no system-level inventory |
| CIS 8.6, audit logging | Partial. VM logging flags and log retention, no `oned` audit configuration |
| CIS 9.2 and 9.3, SSH and RDP restricted | NIC `l3Firewall`, VM `sshRestricted` and `rdpRestricted` |
| Backups | BlockStorage `backups[0].enabled` |
