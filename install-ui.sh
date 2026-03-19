#!/bin/bash
set -e

echo "=========================================="
echo "   FLEXX-STAGING UI — INSTALLER/UPDATER   "
echo "=========================================="

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run this installer as root (sudo bash install-ui.sh)"
    exit 1
fi

# make sure we're running from the repo directory where the source files live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in flexx_custom.js flexx_api.php flexx-staging.sh; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "ERROR: Required file '$f' not found in $SCRIPT_DIR"
        echo "Run this script from inside the cloned repository."
        exit 1
    fi
done

# WP-CLI — skip if already installed and working, otherwise install/update
echo "--> Checking WP-CLI..."
if command -v wp &> /dev/null; then
    echo "    WP-CLI already installed: $(wp --version --allow-root 2>/dev/null || echo 'unknown version')"
else
    echo "    WP-CLI not found. Installing globally..."
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    echo "    WP-CLI installed: $(wp --version --allow-root 2>/dev/null)"
fi

# JS — Hestia's custom_scripts folder may not exist on older installs
JS_DIR="/usr/local/hestia/web/js/custom_scripts"
if [ ! -d "$JS_DIR" ]; then
    echo "--> Creating custom_scripts directory..."
    mkdir -p "$JS_DIR"
fi
echo "--> Installing flexx_custom.js..."
cp "$SCRIPT_DIR/flexx_custom.js" "$JS_DIR/flexx_custom.js"
chown root:root "$JS_DIR/flexx_custom.js"
chmod 644 "$JS_DIR/flexx_custom.js"

# PHP API
echo "--> Installing flexx_api.php..."
cp "$SCRIPT_DIR/flexx_api.php" "/usr/local/hestia/web/api/flexx_api.php"
chown root:root "/usr/local/hestia/web/api/flexx_api.php"
chmod 644 "/usr/local/hestia/web/api/flexx_api.php"

# shell script — goes into Hestia's bin as v-flexx-staging
echo "--> Installing v-flexx-staging..."
cp "$SCRIPT_DIR/flexx-staging.sh" "/usr/local/hestia/bin/v-flexx-staging"
chown root:root "/usr/local/hestia/bin/v-flexx-staging"
chmod 755 "/usr/local/hestia/bin/v-flexx-staging"

# sudoers — the PHP API runs as the web user (www-data) and needs to call
# v-flexx-staging as root. without this entry the tool installs fine but
# every sync silently fails with a permission error.
SUDOERS_FILE="/etc/sudoers.d/flexx-staging"
SUDOERS_LINE="www-data ALL=(root) NOPASSWD: /usr/local/hestia/bin/v-flexx-staging"

echo "--> Configuring sudoers..."
if [ -f "$SUDOERS_FILE" ] && grep -qF "$SUDOERS_LINE" "$SUDOERS_FILE"; then
    echo "    Sudoers entry already present. Skipping."
else
    echo "$SUDOERS_LINE" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    # validate the file before committing — a bad sudoers entry can lock out root
    if visudo -cf "$SUDOERS_FILE" &>/dev/null; then
        echo "    Sudoers entry added."
    else
        echo "ERROR: Generated sudoers file failed validation. Removing."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "         INSTALLATION COMPLETE!           "
echo "=========================================="
echo ""
echo "Refresh your HestiaCP panel (Ctrl+F5) to see the new buttons."
