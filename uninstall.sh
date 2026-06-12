#!/bin/bash
# =============================================================================
# addon-confirmate-evidence - Uninstaller
# =============================================================================
# Removes the Confirmate Evidence Collection Gateway from OpenNebula.
# Run as root or oneadmin on the OpenNebula Front-End.
#
# Part of the EMERALD project (EU Horizon Europe, Grant No. 101120688)
# =============================================================================

set -e

ONE_LOCATION="${ONE_LOCATION:-}"
if [ -z "$ONE_LOCATION" ]; then
    HOOKS_DIR="/var/lib/one/remotes/hooks"
    LIB_DIR="/var/lib/one/remotes/hooks/confirmate-evidence"
    ETC_DIR="/etc/one"
else
    HOOKS_DIR="$ONE_LOCATION/var/remotes/hooks"
    LIB_DIR="$ONE_LOCATION/var/remotes/hooks/confirmate-evidence"
    ETC_DIR="$ONE_LOCATION/etc"
fi

echo "========================================"
echo " addon-confirmate-evidence - Uninstaller"
echo "========================================"
echo ""

# Remove registered hooks
echo "[1/3] Removing registered hooks..."
if command -v onehook &>/dev/null; then
    HOOK_NAMES=(
        "hook-confirmate-vm-running"
        "hook-confirmate-vm-poweroff"
        "hook-confirmate-vm-done"
        "hook-confirmate-nic-attach"
        "hook-confirmate-nic-detach"
        "hook-confirmate-image-ready"
        "hook-confirmate-net-create"
    )
    for name in "${HOOK_NAMES[@]}"; do
        # Exact NAME match (column 2), one ID per line; never pass a multi-line
        # blob to `onehook delete`.
        hook_ids=$(onehook list --no-header 2>/dev/null | awk -v n="$name" '$2 == n {print $1}')
        if [ -n "$hook_ids" ]; then
            for hook_id in $hook_ids; do
                echo -n "  Deleting $name (ID: $hook_id)... "
                onehook delete "$hook_id" 2>/dev/null && echo "done" || echo "FAILED"
            done
        else
            echo "  $name not found, skipping"
        fi
    done
else
    echo "  WARNING: onehook command not found, cannot remove hooks automatically"
fi

# Remove hook scripts
echo "[2/3] Removing hook scripts and libraries..."
for script in confirmate_vm_evidence.rb confirmate_nic_evidence.rb confirmate_image_evidence.rb confirmate_net_evidence.rb; do
    if [ -f "$HOOKS_DIR/$script" ]; then
        rm -f "$HOOKS_DIR/$script"
        echo "  Removed: $HOOKS_DIR/$script"
    fi
done

if [ -d "$LIB_DIR" ]; then
    rm -rf "$LIB_DIR"
    echo "  Removed: $LIB_DIR/"
fi

# Configuration (ask before removing)
echo "[3/3] Configuration..."
# The .conf.new backup left by repeated installs is always safe to remove.
rm -f "$ETC_DIR/confirmate-evidence.conf.new"

if [ -f "$ETC_DIR/confirmate-evidence.conf" ]; then
    if [ -t 0 ]; then
        # `read` returns non-zero on EOF; don't let set -e abort the uninstall.
        read -p "  Remove configuration file? (y/N) " -n 1 -r || REPLY="n"
        echo
    else
        # Non-interactive run: preserve the config (safe default).
        REPLY="n"
        echo "  Non-interactive run: preserving configuration."
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$ETC_DIR/confirmate-evidence.conf"
        echo "  Removed: $ETC_DIR/confirmate-evidence.conf"
    else
        echo "  Configuration preserved at: $ETC_DIR/confirmate-evidence.conf"
    fi
fi

echo ""
echo "========================================"
echo " Uninstall complete!"
echo "========================================"
echo ""
