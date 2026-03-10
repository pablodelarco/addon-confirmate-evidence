#!/bin/bash
# =============================================================================
# addon-clouditor-evidence - Installer
# =============================================================================
# Installs the Clouditor Evidence Collection Gateway for OpenNebula.
# Run as root or oneadmin on the OpenNebula Front-End.
#
# Part of the EMERALD project (EU Horizon Europe, Grant No. 101120688)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ONE_LOCATION="${ONE_LOCATION:-}"
if [ -z "$ONE_LOCATION" ]; then
    HOOKS_DIR="/var/lib/one/remotes/hooks"
    LIB_DIR="/var/lib/one/remotes/hooks/clouditor-evidence/lib"
    ETC_DIR="/etc/one"
    LOG_DIR="/var/log/one"
    ONE_USER="oneadmin"
else
    HOOKS_DIR="$ONE_LOCATION/var/remotes/hooks"
    LIB_DIR="$ONE_LOCATION/var/remotes/hooks/clouditor-evidence/lib"
    ETC_DIR="$ONE_LOCATION/etc"
    LOG_DIR="$ONE_LOCATION/var/log"
    ONE_USER="${ONE_USER:-$(whoami)}"
fi

echo "======================================"
echo " addon-clouditor-evidence - Installer"
echo "======================================"
echo ""
echo "Hooks directory: $HOOKS_DIR"
echo "Library directory: $LIB_DIR"
echo "Config directory: $ETC_DIR"
echo ""

# Verify OpenNebula directories exist
if [ ! -d "$HOOKS_DIR" ]; then
    echo "ERROR: Hooks directory not found: $HOOKS_DIR"
    echo "Is OpenNebula installed? Set ONE_LOCATION if using a custom install path."
    exit 1
fi

# Copy library files
echo "[1/5] Installing library files..."
mkdir -p "$LIB_DIR"
cp "$SCRIPT_DIR"/lib/*.rb "$LIB_DIR/"
echo "  Installed: token_manager.rb, ontology_mapper.rb, clouditor_client.rb"

# Copy hook scripts
echo "[2/5] Installing hook scripts..."
cp "$SCRIPT_DIR"/hooks/*.rb "$HOOKS_DIR/"
chmod 750 "$HOOKS_DIR"/clouditor_*.rb
echo "  Installed: clouditor_vm_evidence.rb, clouditor_nic_evidence.rb,"
echo "             clouditor_image_evidence.rb, clouditor_net_evidence.rb"

# Set ownership
echo "[3/5] Setting file ownership..."
if id "$ONE_USER" &>/dev/null; then
    chown -R "$ONE_USER":"$ONE_USER" "$LIB_DIR" 2>/dev/null || true
    chown "$ONE_USER":"$ONE_USER" "$HOOKS_DIR"/clouditor_*.rb 2>/dev/null || true
fi

# Copy configuration (do not overwrite existing)
echo "[4/5] Installing configuration..."
if [ ! -f "$ETC_DIR/clouditor-evidence.conf" ]; then
    cp "$SCRIPT_DIR"/etc/clouditor-evidence.conf "$ETC_DIR/"
    if id "$ONE_USER" &>/dev/null; then
        chown "$ONE_USER":"$ONE_USER" "$ETC_DIR/clouditor-evidence.conf" 2>/dev/null || true
    fi
    chmod 640 "$ETC_DIR/clouditor-evidence.conf"
    echo "  Configuration installed at: $ETC_DIR/clouditor-evidence.conf"
else
    echo "  Configuration already exists, skipping (backup at clouditor-evidence.conf.new)"
    cp "$SCRIPT_DIR"/etc/clouditor-evidence.conf "$ETC_DIR/clouditor-evidence.conf.new"
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/clouditor-evidence.log" 2>/dev/null || true
if id "$ONE_USER" &>/dev/null; then
    chown "$ONE_USER":"$ONE_USER" "$LOG_DIR/clouditor-evidence.log" 2>/dev/null || true
fi

# Register hooks with OpenNebula
echo "[5/5] Registering hooks..."
if command -v onehook &>/dev/null; then
    for tmpl in "$SCRIPT_DIR"/templates/*.tmpl; do
        name=$(grep "^NAME" "$tmpl" | sed 's/.*= *"\?\([^"]*\)"\?.*/\1/')
        echo -n "  $name... "

        # Check if hook already exists
        existing=$(onehook list -f NAME="$name" --no-header 2>/dev/null | awk '{print $1}')
        if [ -n "$existing" ]; then
            echo "already exists (ID: $existing), skipping"
        else
            if onehook create "$tmpl" 2>/dev/null; then
                echo "created"
            else
                echo "FAILED (register manually with: onehook create $tmpl)"
            fi
        fi
    done
else
    echo "  WARNING: onehook command not found."
    echo "  Register hooks manually after installation:"
    echo "    for tmpl in $SCRIPT_DIR/templates/*.tmpl; do onehook create \$tmpl; done"
fi

echo ""
echo "======================================"
echo " Installation complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Edit $ETC_DIR/clouditor-evidence.conf with your Clouditor endpoint"
echo "  2. Set the cloud_service_id to match your Clouditor configuration"
echo "  3. Verify connectivity: curl -s http://<clouditor-host>:8082/v1/orchestrator/cloud_services"
echo "  4. Test a hook: create a VM and check /var/log/one/clouditor-evidence.log"
echo ""
