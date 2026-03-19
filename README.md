# Flexx-Staging for HestiaCP

A native staging tool built directly into the HestiaCP web panel for WordPress. No terminal required.

## What it does

Adds two buttons to every domain row in your HestiaCP **Web** list:

- **Orange staging icon** — opens a sync modal to clone a WordPress site to a target domain
- **Green key icon** — one-click auto-login to wp-admin (only appears on WordPress installs)

From the modal you can sync an existing domain or let the tool create a brand new staging domain automatically, including its database.

## ⚠️ Read before syncing databases

If you select **Database** or **All** and the destination is your **live** site, the tool will overwrite your live database completely. On eCommerce sites this means any orders placed since the last sync will be gone.

Always take a manual database backup before pushing staging back to production.

---

## Prerequisites

- HestiaCP installed and running
- Root SSH access to the server
- A DNS `A` record pointing your staging domain to the server IP (required even when using auto-provision — Hestia won't create the web config otherwise)

---

## Installation

```bash
rm -rf /tmp/Hestia-flexx-staging-UI && \
git clone https://github.com/christoskaterini/Hestia-flexx-staging-UI.git /tmp/Hestia-flexx-staging-UI
cd /tmp/Hestia-flexx-staging-UI
sudo bash install-ui.sh
```

The installer:
1. Checks for WP-CLI and installs it globally if missing
2. Creates the `custom_scripts` directory if it doesn't exist
3. Copies `flexx_custom.js` → `/usr/local/hestia/web/js/custom_scripts/`
4. Copies `flexx_api.php` → `/usr/local/hestia/web/api/`
5. Copies `flexx-staging.sh` → `/usr/local/hestia/bin/v-flexx-staging`
6. Creates a sudoers entry so the panel can call the script as root

After installing, hard-refresh the Hestia panel (**Ctrl+F5**).

### Updating

Re-run the same install command. The installer will overwrite the existing files and skip any steps that are already in place (WP-CLI version check, sudoers entry).

---

## Usage

1. Go to **Web** in the HestiaCP panel
2. Hover over a domain — click the orange **staging icon**
3. Pick a target domain from the dropdown, or choose **+ Create New Domain...** to auto-provision one
4. Select a sync mode and click **Execute Sync**

The **key icon** appears next to any domain where a `wp-config.php` is detected. Clicking it opens wp-admin in a new tab, logged in as the first admin user — no password needed. The login link is single-use and self-deletes immediately.

---

## Sync modes

| Mode | What it does | Safe for live eCommerce? |
|---|---|---|
| **Files only** | rsync everything except `wp-config.php` and `.htaccess` | ✅ Yes |
| **Database only** | export → import + URL replace | ⚠️ Manual backup first |
| **All** | Files + Database in one pass | ⚠️ Manual backup first |

---

## What happens during a database sync

1. Exports source DB to a temporary `.sql` file
2. Drops and recreates target DB tables
3. Imports the dump
4. Reads the source site URL from the DB and runs `search-replace` to the target domain — handles `http`, `https`, `www` variants
5. Syncs the `table_prefix` if it differs between source and target
6. Sets unique `WP_CACHE_KEY_SALT` and `WP_REDIS_PREFIX` constants so staging and live don't share cache entries
7. Deactivates known-problematic plugins (see below)
8. Flushes permalinks and object cache

---

## Plugin deactivation on staging

Security and caching plugins break staging environments in predictable ways — firewalls block staging IPs, caches serve live URLs, login limiters lock you out. The sync automatically deactivates these plugin slugs on the **target** after a database sync:

**Security & login:** `wordfence`, `all-in-one-wp-security-and-firewall`, `ithemes-security`, `better-wp-security`, `sucuri-scanner`, `sg-security`, `wp-cerber`, `shield-security`, `defender-security`, `loginizer`, `limit-login-attempts-reloaded`, `two-factor-authentication`

**Caching & performance:** `w3-total-cache`, `litespeed-cache`, `wp-super-cache`, `wp-fastest-cache`, `sg-cachepress`, `wp-rocket`, `autoptimize`, `wp-optimize`, `breeze`, `hummingbird-performance`

**Other:** `redirection`, `simple-301-redirects`, `safe-svg`

These are only deactivated on the target. Your source site is never touched.

> If you push the staging database back to live, these plugins will be deactivated there too — intentionally. Re-activate them manually after the push. This prevents Wordfence/AIOS from immediately writing staging firewall rules into your live `.htaccess`.

---

## Pushing staging back to live

**Files only (recommended for theme/CSS changes)**
Run a **Files Only** sync from staging → live. The live database is not touched. Clear your caching plugin cache afterward so the new files are served immediately.

**Database or All (static/non-eCommerce sites only)**
The sync will work, but security and caching plugins will be deactivated on live afterward — see above. Re-activate them immediately after the sync completes.

---

## Uninstallation

```bash
rm -f /usr/local/hestia/web/js/custom_scripts/flexx_custom.js
rm -f /usr/local/hestia/web/api/flexx_api.php
rm -f /usr/local/hestia/bin/v-flexx-staging
rm -f /etc/sudoers.d/flexx-staging
rm -rf /tmp/Hestia-flexx-staging-UI
```

WP-CLI is left in place since it's useful independently. Remove it with `rm -f /usr/local/bin/wp` if you don't want it.

---

## Contributing

If a caching or security plugin broke your staging environment and it's not in the deactivation list, open an issue on GitHub with the plugin slug. Contributions to the plugin list are the most impactful way to improve this tool for everyone.

Bug reports and PRs are welcome.
