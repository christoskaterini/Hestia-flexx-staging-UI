#!/bin/bash
set -e

# flexx-staging.sh — sync a WordPress site to a staging domain via HestiaCP
# runs as the logged-in user from terminal, or as root when called by the API

CREATE_TARGET=false
INTERACTIVE=true
WP_CHECK=false
WP_LOGIN=false

# args must be parsed before anything else references these variables
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --user)          HESTIA_USER="$2"; shift ;;
        --source)        SOURCE_DOM="$2";  shift ;;
        --target)        TARGET_DOM="$2";  shift ;;
        --sync)          SYNC_TYPE="$2";   shift ;;
        --create-target) CREATE_TARGET=true ;;
        --wp-check)      WP_CHECK=true ;;
        --wp-login)      WP_LOGIN=true ;;
        --confirm)       INTERACTIVE=false ;;
        *) echo "ERROR: Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

if [ "$WP_CHECK" = false ] && [ "$WP_LOGIN" = false ]; then
    echo "=========================================="
    echo "          FLEXX-STAGING SYNC TOOL         "
    echo "=========================================="
fi

if [ -n "$HESTIA_USER" ] && [[ ! "$HESTIA_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid User parameter. Only alphanumeric, dashes, and underscores allowed."
    exit 1
fi

if [ -n "$SOURCE_DOM" ] && [[ ! "$SOURCE_DOM" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "ERROR: Invalid Source Domain format."
    exit 1
fi

if [ -n "$TARGET_DOM" ] && [[ ! "$TARGET_DOM" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "ERROR: Invalid Target Domain format."
    exit 1
fi

if [ -n "$SYNC_TYPE" ] && [[ ! "$SYNC_TYPE" =~ ^[1-3]$ ]]; then
    echo "ERROR: Invalid Sync Type. Must be 1, 2, or 3."
    exit 1
fi

if [ -z "$HESTIA_USER" ]; then
    HESTIA_USER="$USER"
fi

if [ "$WP_CHECK" = false ] && [ "$WP_LOGIN" = false ]; then
    echo "Running as user: $HESTIA_USER"
    echo ""
fi

# interactive mode — prompt for missing args when run directly from terminal
if [ "$WP_CHECK" = false ] && [ "$WP_LOGIN" = false ] && \
   ([ -z "$SOURCE_DOM" ] || [ -z "$TARGET_DOM" ] || [ -z "$SYNC_TYPE" ]); then

    echo "Available websites for user $HESTIA_USER:"
    ls -1 /home/"$HESTIA_USER"/web/ | grep -v '^\.' | sed 's/^/  - /'
    echo ""
    read -r -p "Enter SOURCE Domain (Where to copy FROM): " SOURCE_DOM
    read -r -p "Enter TARGET Domain (Where to copy TO):   " TARGET_DOM

    echo ""
    echo "What do you want to sync?"
    echo "1) Files ONLY     (Safe for Live eCommerce DB)"
    echo "2) Database ONLY  (DANGEROUS for Live eCommerce DB)"
    echo "3) ALL            (OVERWRITES EVERYTHING - Files + Database)"
    read -r -p "Select 1, 2, or 3: " SYNC_TYPE

    echo ""
    echo "WARNING: You are about to overwrite data on --> $TARGET_DOM"
    read -r -p "Are you 100% sure? (type 'yes' to continue): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# when the API calls this as root, the session user might not match the actual
# domain owner (e.g. admin using "Login As"). resolve from the filesystem instead.
if [ "$EUID" -eq 0 ] && [ -n "$SOURCE_DOM" ]; then
    FOUND_USER=$(ls -1d /home/*/web/"$SOURCE_DOM" 2>/dev/null | awk -F'/' '{print $3}' | head -n 1)
    if [ -n "$FOUND_USER" ]; then
        if [ "$FOUND_USER" != "$HESTIA_USER" ]; then
            if [ "$WP_CHECK" = false ] && [ "$WP_LOGIN" = false ]; then
                echo "--> Correcting user to actual domain owner: $FOUND_USER"
            fi
            HESTIA_USER="$FOUND_USER"
        fi
    else
        echo "ERROR: Domain '$SOURCE_DOM' not found in any user's web directory."
        exit 1
    fi
fi

SOURCE_PATH="/home/$HESTIA_USER/web/$SOURCE_DOM/public_html"
TARGET_PATH="/home/$HESTIA_USER/web/$TARGET_DOM/public_html"

# --- wp-check: test for wp-config.php, print result, exit --------------------
if [ "$WP_CHECK" = true ]; then
    if [ -f "$SOURCE_PATH/wp-config.php" ]; then
        echo "WP"
    else
        echo "NOT_WP"
    fi
    exit 0
fi

# --- wp-login: drop a self-deleting auth file and return its URL --------------
if [ "$WP_LOGIN" = true ]; then
    if [ ! -f "$SOURCE_PATH/wp-config.php" ]; then
        echo "ERROR: Not a WordPress installation."
        exit 1
    fi

    if ! command -v wp &> /dev/null; then
        echo "ERROR: WP-CLI not found. Cannot generate login URL."
        exit 1
    fi

    run_wp() {
        php -d disable_functions="" /usr/local/bin/wp "$@" --path="$SOURCE_PATH" --allow-root
    }

    WP_USER=$(run_wp user list --role=administrator --field=user_login --number=1 --quiet 2>/dev/null | head -n 1)
    if [ -z "$WP_USER" ]; then
        echo "ERROR: No administrator account found in WordPress."
        exit 1
    fi

    # random filename so it can't be guessed
    TOKEN=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
    LOGIN_FILE="flexx-login-${TOKEN}.php"

    # sets auth cookie then redirects to wp-admin, deletes itself on first hit
    cat > "$SOURCE_PATH/$LOGIN_FILE" <<PHPEOF
<?php
define('WP_USE_THEMES', false);
require_once __DIR__ . '/wp-load.php';
\$user = get_user_by('login', '${WP_USER}');
unlink(__FILE__);
if (\$user) {
    wp_set_current_user(\$user->ID);
    wp_set_auth_cookie(\$user->ID, true);
    wp_redirect(admin_url());
    exit;
}
wp_die('Login failed: user not found.');
PHPEOF

    # file was created as root — hand it back to the site user
    chown "$HESTIA_USER":"$HESTIA_USER" "$SOURCE_PATH/$LOGIN_FILE"
    chmod 644 "$SOURCE_PATH/$LOGIN_FILE"

    SITE_URL=$(run_wp option get siteurl --quiet 2>/dev/null | tr -d '[:space:]')
    if [ -z "$SITE_URL" ]; then
        SITE_URL="http://$SOURCE_DOM"
    fi

    # PHP reads only this last line as the login URL
    echo "${SITE_URL}/${LOGIN_FILE}"
    exit 0
fi

# --- sync --------------------------------------------------------------------

if [ "$CREATE_TARGET" = true ]; then
    SYNC_TYPE="3"  # empty site needs everything, not just files or just DB
    if [ ! -d "$TARGET_PATH" ]; then
        echo "--> Auto-provisioning staging domain: $TARGET_DOM..."
        if [ "$EUID" -eq 0 ]; then
            /usr/local/hestia/bin/v-add-web-domain "$HESTIA_USER" "$TARGET_DOM"
            DB_SUFFIX=$(echo "$TARGET_DOM" | sed 's/[^a-zA-Z0-9]//g' | head -c 12)
            DB_NAME="${HESTIA_USER}_${DB_SUFFIX}"
            DB_USER="${DB_NAME}"
            DB_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
            /usr/local/hestia/bin/v-add-database "$HESTIA_USER" "$DB_SUFFIX" "$DB_SUFFIX" "$DB_PASS"
            sleep 2
            echo "--> Database $DB_NAME created."
        else
            echo "ERROR: Auto-provisioning requires root/API privileges."
            exit 1
        fi
    fi
fi

if [ ! -d "$SOURCE_PATH" ]; then
    echo "ERROR: SOURCE domain path does not exist: $SOURCE_PATH"
    echo "Available folders in /home/$HESTIA_USER/web/:"
    ls -la /home/"$HESTIA_USER"/web/
    exit 1
fi

if [ ! -d "$TARGET_PATH" ]; then
    sleep 2  # v-add-web-domain can take a moment before the folder appears
    if [ ! -d "$TARGET_PATH" ]; then
        echo "ERROR: TARGET domain path does not exist: $TARGET_PATH"
        echo "Available folders in /home/$HESTIA_USER/web/:"
        ls -la /home/"$HESTIA_USER"/web/
        exit 1
    fi
fi

# --- phase 1: files ----------------------------------------------------------
if [ "$SYNC_TYPE" == "1" ] || [ "$SYNC_TYPE" == "3" ]; then
    echo "--> Syncing files (excluding wp-config.php and .htaccess)..."

    rsync -a \
        --exclude 'wp-config.php' \
        --exclude '.htaccess' \
        "$SOURCE_PATH/" "$TARGET_PATH/"

    # Hestia drops a placeholder index.html on new domains that breaks WP routing
    rm -f "$TARGET_PATH/index.html"

    # only copy .htaccess if the target doesn't already have one
    if [ ! -f "$TARGET_PATH/.htaccess" ] && [ -f "$SOURCE_PATH/.htaccess" ]; then
        cp "$SOURCE_PATH/.htaccess" "$TARGET_PATH/.htaccess"
    fi

    # if the target has no wp-config.php it has no database either — copy the config
    # then provision a fresh DB so we don't accidentally point staging at live
    if [ ! -f "$TARGET_PATH/wp-config.php" ] && [ -f "$SOURCE_PATH/wp-config.php" ]; then
        cp "$SOURCE_PATH/wp-config.php" "$TARGET_PATH/wp-config.php"

        if [ "$CREATE_TARGET" != true ] && [ "$EUID" -eq 0 ]; then
            echo "--> Target wp-config was missing — provisioning an isolated database..."
            DB_SUFFIX=$(echo "$TARGET_DOM" | sed 's/[^a-zA-Z0-9]//g' | head -c 12)
            DB_NAME="${HESTIA_USER}_${DB_SUFFIX}"
            DB_USER="${DB_NAME}"
            DB_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
            /usr/local/hestia/bin/v-add-database "$HESTIA_USER" "$DB_SUFFIX" "$DB_SUFFIX" "$DB_PASS"
            sleep 2
            echo "--> Database $DB_NAME created."
        fi

        if [ -n "$DB_NAME" ]; then
            echo "--> Injecting database credentials into wp-config.php..."
            sed -i "s/['\"]DB_NAME['\"] *, *['\"][^'\"]*['\"]/'DB_NAME', '$DB_NAME'/" "$TARGET_PATH/wp-config.php"
            sed -i "s/['\"]DB_USER['\"] *, *['\"][^'\"]*['\"]/'DB_USER', '$DB_USER'/" "$TARGET_PATH/wp-config.php"
            sed -i "s/['\"]DB_PASSWORD['\"] *, *['\"][^'\"]*['\"]/'DB_PASSWORD', '$DB_PASS'/" "$TARGET_PATH/wp-config.php"
        fi
    fi

    echo "--> Fixing file permissions..."
    # running as root means ownership ends up as root — hand everything back to the site user
    if [ "$EUID" -eq 0 ]; then
        chown -R "$HESTIA_USER":"$HESTIA_USER" "$TARGET_PATH"
    fi
    find "$TARGET_PATH" -type d -exec chmod 755 {} +
    find "$TARGET_PATH" -type f -exec chmod 644 {} +

    echo "--> File sync complete."
fi

# --- phase 2: database -------------------------------------------------------
if [ "$SYNC_TYPE" == "2" ] || [ "$SYNC_TYPE" == "3" ]; then

    if ! command -v wp &> /dev/null; then
        echo "--> WP-CLI not found. Installing globally..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        echo "--> WP-CLI installed."
    fi

    # some hosts disable proc_open in php.ini — override it for WP-CLI only
    run_wp() {
        php -d disable_functions="" /usr/local/bin/wp "$@" --allow-root
    }

    echo "--> Exporting database from source..."
    run_wp db export "$SOURCE_PATH/sync_dump.sql" --path="$SOURCE_PATH" --quiet
    mv "$SOURCE_PATH/sync_dump.sql" "$TARGET_PATH/sync_dump.sql"

    echo "--> Resetting target database..."
    run_wp db reset --yes --path="$TARGET_PATH" --quiet

    echo "--> Importing database into target..."
    run_wp db import "$TARGET_PATH/sync_dump.sql" --path="$TARGET_PATH" --quiet
    rm "$TARGET_PATH/sync_dump.sql"

    # pull the exact live URL from the DB — handles www. and http/https automatically
    EXACT_OLD_URL=$(run_wp option get siteurl --path="$SOURCE_PATH" --quiet)

    PROTOCOL="https://"
    if [ "$CREATE_TARGET" = true ]; then
        PROTOCOL="http://"  # freshly provisioned domains have no SSL cert yet
    elif [[ "$EXACT_OLD_URL" == http://* ]]; then
        PROTOCOL="http://"
    fi
    NEW_URL="${PROTOCOL}${TARGET_DOM}"

    echo "--> Syncing database table prefix..."
    SOURCE_PREFIX=$(run_wp config get table_prefix --path="$SOURCE_PATH" --quiet)
    TARGET_PREFIX=$(run_wp config get table_prefix --path="$TARGET_PATH" --quiet)
    if [ "$SOURCE_PREFIX" != "$TARGET_PREFIX" ] && [ -n "$SOURCE_PREFIX" ]; then
        run_wp config set table_prefix "$SOURCE_PREFIX" --path="$TARGET_PATH" --quiet
    fi

    # without unique cache keys, staging and live share the same Redis/Memcached entries
    echo "--> Isolating object cache keys..."
    run_wp config set WP_CACHE_KEY_SALT "${TARGET_DOM}_" --path="$TARGET_PATH" --type=constant --quiet || true
    run_wp config set WP_REDIS_PREFIX   "${TARGET_DOM}_" --path="$TARGET_PATH" --type=constant --quiet || true

    echo "--> Running search-replace: $EXACT_OLD_URL → $NEW_URL..."
    if [ -n "$EXACT_OLD_URL" ]; then
        run_wp search-replace "$EXACT_OLD_URL" "$NEW_URL" --skip-columns=guid --path="$TARGET_PATH" --quiet
    fi
    # belt-and-suspenders: catch hardcoded URLs the DB value might have missed
    run_wp search-replace "https://$SOURCE_DOM"     "$NEW_URL" --skip-columns=guid --path="$TARGET_PATH" --quiet
    run_wp search-replace "http://$SOURCE_DOM"      "$NEW_URL" --skip-columns=guid --path="$TARGET_PATH" --quiet
    run_wp search-replace "https://www.$SOURCE_DOM" "$NEW_URL" --skip-columns=guid --path="$TARGET_PATH" --quiet
    run_wp search-replace "http://www.$SOURCE_DOM"  "$NEW_URL" --skip-columns=guid --path="$TARGET_PATH" --quiet

    # force these as a backstop — search-replace can miss serialized edge cases
    run_wp option update home    "$NEW_URL" --path="$TARGET_PATH" --quiet 2>/dev/null || true
    run_wp option update siteurl "$NEW_URL" --path="$TARGET_PATH" --quiet 2>/dev/null || true

    if [ "$PROTOCOL" = "http://" ]; then
        run_wp config set FORCE_SSL_ADMIN false --path="$TARGET_PATH" --raw --quiet || true
    fi

    echo "--> Flushing cache before plugin deactivation..."
    run_wp cache flush --path="$TARGET_PATH" --quiet 2>/dev/null || true

    echo "--> Deactivating security, caching, and redirect plugins on target..."
    run_wp plugin deactivate \
        all-in-one-wp-security-and-firewall \
        anti-malware \
        autoptimize \
        better-wp-security \
        breeze \
        bulletproof-security \
        comet-cache \
        defender-security \
        flying-press \
        hummingbird-performance \
        imagify \
        ithemes-security \
        jetpack \
        limit-login-attempts-reloaded \
        litespeed-cache \
        loginizer \
        malcare-security \
        miniorange-2-factor-authentication \
        nginx-helper \
        nitropack \
        phastpress \
        really-simple-ssl \
        redirection \
        redis-cache \
        safe-svg \
        secupress \
        security-ninja \
        sg-cachepress \
        sg-security \
        shield-security \
        simple-301-redirects \
        solid-security \
        sucuri-scanner \
        swift-performance \
        swift-performance-lite \
        two-factor-authentication \
        w3-total-cache \
        wp-cerber \
        wp-fastest-cache \
        wp-hide-security-enhancer \
        wp-optimize \
        wp-rocket \
        wp-super-cache \
        wps-hide-login \
        wordfence \
        --path="$TARGET_PATH" --quiet 2>/dev/null || true

    echo "--> Flushing permalinks..."
    run_wp rewrite flush --hard --path="$TARGET_PATH" --quiet

    echo "--> Database sync complete."
fi

if [ "$SYNC_TYPE" != "1" ] && [ "$SYNC_TYPE" != "2" ] && [ "$SYNC_TYPE" != "3" ]; then
    echo "ERROR: Invalid sync type. Aborted."
    exit 1
fi

echo ""
echo "=========================================="
echo "          FLEXX-STAGING COMPLETE!         "
echo "=========================================="
