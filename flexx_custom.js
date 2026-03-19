// flexx_custom.js — injects staging + WP admin buttons into the HestiaCP domain list
// staging button: opens the sync modal
// WP admin button: one-click auto-login to wp-admin (only shown on WP sites)

document.addEventListener("DOMContentLoaded", function () {
    if (window.location.pathname !== "/list/web/") return;

    const actionLists = document.querySelectorAll("ul.units-table-row-actions");

    actionLists.forEach((ul, index) => {
        const row = ul.closest(".units-table-row");
        if (!row) return;

        const editLink =
            row.querySelector("a.units-table-heading-cell") ||
            row.querySelector(".units-table-heading-cell a");

        let rowDomain = "";
        let rowUser   = "";

        if (editLink?.href?.includes("domain=")) {
            const url = new URL(editLink.href, window.location.origin);
            rowDomain = url.searchParams.get("domain") || "";
            rowUser   = url.searchParams.get("user")   || "";
        } else {
            const nameEl = row.querySelector(".units-table-heading-cell");
            if (nameEl) rowDomain = nameEl.innerText.trim().split("\n")[0].trim();
        }

        // fallback: read domain from the row checkbox
        if (!rowDomain) {
            const cb = row.querySelector('input[type="checkbox"][name="domain[]"]');
            if (cb?.value) rowDomain = cb.value;
        }

        if (!rowDomain) return;

        // resolve the domain owner — needed for admin "Login As" sessions where
        // the session user doesn't match the actual domain owner
        if (!rowUser) {
            row.querySelectorAll("a").forEach(link => {
                if (!rowUser && link.href?.includes("user=")) {
                    const u = new URL(link.href, window.location.origin);
                    rowUser = u.searchParams.get("user") || "";
                }
            });
        }

        if (!rowUser) {
            const pageParams = new URLSearchParams(window.location.search);
            rowUser = pageParams.get("loginas") || pageParams.get("user") || "";
        }

        if (!rowUser) {
            // Hestia renders the active user in the top-nav after a redirect
            const badge = document.querySelector('.profile-name, .top-bar-user, a[href="/edit/user/"]');
            if (badge) rowUser = badge.innerText.trim();
        }

        if (!rowUser) {
            const hiddenUser = document.querySelector('input[name="user"]');
            rowUser = hiddenUser?.value || "";
        }

        // inject staging button
        const deleteBtn = ul.querySelector(".shortcut-delete");

        const stagingLi = document.createElement("li");
        stagingLi.className = "units-table-row-action shortcut-staging";

        const stagingLink = document.createElement("a");
        stagingLink.href      = "javascript:void(0);";
        stagingLink.title     = "Flexx-Staging";
        stagingLink.className = "units-table-row-action-link data-controls";
        stagingLink.onclick   = () => openStagingModal(rowDomain, rowUser);
        stagingLink.innerHTML = `<i class="fas fa-layer-group icon-orange"></i><span class="u-hide-desktop">Flexx-Staging</span>`;

        stagingLi.appendChild(stagingLink);

        if (deleteBtn) {
            ul.insertBefore(stagingLi, deleteBtn);
        } else {
            ul.appendChild(stagingLi);
        }

        // stagger WP detection calls — 150ms per row avoids hammering the API
        // when the page loads with many domains at once
        setTimeout(() => checkAndAddWpButton(ul, rowDomain, rowUser), index * 150);
    });
});

async function checkAndAddWpButton(ul, domain, user) {
    const token    = document.querySelector('input[name="token"]')?.value || "";
    const formData = new FormData();
    formData.append("action",        "wp_check");
    formData.append("token",         token);
    formData.append("source_domain", domain);
    formData.append("source_user",   user);

    try {
        const res    = await fetch("/api/flexx_api.php", { method: "POST", body: formData });
        const result = await res.json();

        if (!result.success || !result.is_wp) return;

        const wpLi = document.createElement("li");
        wpLi.className = "units-table-row-action shortcut-wp-admin";

        const wpLink = document.createElement("a");
        wpLink.href      = "javascript:void(0);";
        wpLink.title     = "WP Admin Auto-Login";
        wpLink.className = "units-table-row-action-link data-controls";
        wpLink.innerHTML = `<i class="fas fa-key"></i><span class="u-hide-desktop">WP Admin</span>`;

        wpLink.onmouseover = () => wpLink.querySelector("i").classList.add("icon-green");
        wpLink.onmouseout  = () => wpLink.querySelector("i").classList.remove("icon-green");
        wpLink.onclick     = () => executeWpLogin(domain, user, wpLink);

        wpLi.appendChild(wpLink);

        // place it right after the staging button
        const stagingBtn = ul.querySelector(".shortcut-staging");
        if (stagingBtn?.nextSibling) {
            ul.insertBefore(wpLi, stagingBtn.nextSibling);
        } else {
            const deleteBtn = ul.querySelector(".shortcut-delete");
            deleteBtn ? ul.insertBefore(wpLi, deleteBtn) : ul.appendChild(wpLi);
        }

    } catch (err) {
        console.warn(`[Flexx] WP check failed for ${domain}:`, err);
    }
}

async function executeWpLogin(domain, user, anchor) {
    const originalHTML         = anchor.innerHTML;
    anchor.innerHTML           = `<i class="fas fa-spinner fa-spin" style="color: #21759b;"></i>`;
    anchor.style.pointerEvents = "none";

    // open the tab immediately — browsers block window.open() called inside async/await
    const loginWindow = window.open("about:blank", "_blank");
    if (!loginWindow) {
        alert("Please allow popups for this site to use WP Admin auto-login.");
        anchor.innerHTML           = originalHTML;
        anchor.style.pointerEvents = "auto";
        return;
    }

    loginWindow.document.write(`<!DOCTYPE html>
<html>
<head>
  <title>Logging in to WordPress...</title>
  <style>
    body { display:flex; align-items:center; justify-content:center; height:100vh;
           font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
           background:#f0f0f1; color:#3c434a; margin:0; }
    .wrap { text-align:center; }
    .spinner { border:4px solid #ddd; border-top-color:#21759b; border-radius:50%;
               width:36px; height:36px; animation:spin 0.8s linear infinite; margin:0 auto 16px; }
    @keyframes spin { to { transform:rotate(360deg); } }
    p { margin:6px 0; font-size:14px; }
    small { opacity:0.5; font-size:12px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="spinner"></div>
    <p>Authenticating with WordPress&hellip;</p>
    <small>Generating secure one-time login link</small>
  </div>
</body>
</html>`);

    const token    = document.querySelector('input[name="token"]')?.value || "";
    const formData = new FormData();
    formData.append("action",        "wp_login");
    formData.append("token",         token);
    formData.append("source_domain", domain);
    formData.append("source_user",   user);

    try {
        const res    = await fetch("/api/flexx_api.php", { method: "POST", body: formData });
        const result = await res.json();

        if (result.success && result.login_url) {
            loginWindow.location.href = result.login_url;
        } else {
            loginWindow.close();
            alert("WP Login failed: " + (result.error || "Unknown error. Check HestiaCP logs."));
        }
    } catch (err) {
        loginWindow.close();
        alert("Request failed. Check your connection or HestiaCP error logs.");
    } finally {
        anchor.innerHTML           = originalHTML;
        anchor.style.pointerEvents = "auto";
    }
}

function openStagingModal(sourceDomain, sourceUser) {
    document.getElementById("flexx-staging-modal")?.remove();

    // grab all domain names visible in the current UI for the target dropdown
    const allRows = document.querySelectorAll(".units-table-row");
    const availableDomains = new Set();

    allRows.forEach(row => {
        const el = row.querySelector(".units-table-heading-cell a") ||
                   row.querySelector(".units-table-heading-cell");
        if (!el) return;
        const name = el.innerText.trim().split("\n")[0].trim();
        if (name && name !== "Name:" && name !== sourceDomain) {
            availableDomains.add(name);
        }
    });

    let domainOptions = `<option value="">-- Select Target Domain --</option>`;
    domainOptions += `<option value="__NEW__" style="font-weight:bold; color:var(--color-green,#4caf50);">+ Create New Domain...</option>`;
    availableDomains.forEach(d => {
        domainOptions += `<option value="${d}">${d}</option>`;
    });

    const overlay = document.createElement("div");
    overlay.id = "flexx-staging-modal";
    overlay.style.cssText = `
        position:fixed; inset:0; background:rgba(0,0,0,0.55); z-index:9999;
        display:flex; align-items:center; justify-content:center;
        backdrop-filter:blur(2px);
    `;

    const panel = document.createElement("div");
    panel.style.cssText = `
        background:var(--color-background,#fff);
        color:var(--color-text,#333);
        width:490px; border-radius:6px;
        box-shadow:0 10px 30px rgba(0,0,0,0.45);
        border:1px solid var(--color-line,rgba(80,80,80,0.97));
        overflow:hidden;
        font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    `;

    panel.innerHTML = `
        <div style="background:var(--color-background-sidebar,#2a2c35);
                    color:var(--color-text-sidebar,#fff);
                    padding:15px 20px; font-size:16px; font-weight:600;
                    display:flex; justify-content:space-between; align-items:center;
                    border-bottom:1px solid var(--color-line,rgba(80,80,80,0.97));">
            <span><i class="fas fa-layer-group" style="color:#ff9800; margin-right:8px;"></i>Flexx-Staging Sync</span>
            <a href="javascript:void(0);" onclick="document.getElementById('flexx-staging-modal').remove();"
               style="color:var(--color-text-sidebar,#fff); opacity:0.7; text-decoration:none; line-height:1;">
                <i class="fas fa-times"></i>
            </a>
        </div>

        <div id="flexx-staging-body" style="padding:20px; max-height:80vh; overflow-y:auto;">
            <p style="margin-top:0; font-size:14px;">
                Sync data from <strong>${sourceDomain}</strong> to a target environment.
            </p>

            <div id="flexx-staging-error" style="display:none; background:#ffebee; color:#c62828;
                 border-left:4px solid #c62828; padding:10px 15px; margin-bottom:15px;
                 border-radius:4px; font-size:13px;"></div>

            <div style="margin-top:15px;">
                <label style="display:block; font-weight:bold; margin-bottom:5px; font-size:13px;">
                    Target Domain <span style="color:#E73A33;">*</span>
                </label>
                <select id="flexx-target-domain" class="form-control"
                    style="width:100%; background:var(--color-background,#fff); color:inherit;
                           padding:8px; border-radius:4px; font-size:14px;"
                    onchange="
                        document.getElementById('flexx-new-domain-wrapper').style.display =
                            (this.value === '__NEW__') ? 'block' : 'none';
                        document.getElementById('flexx-staging-error').style.display = 'none';
                    ">
                    ${domainOptions}
                </select>
                <p style="font-size:11px; margin:4px 0 0; opacity:0.7;">
                    Select an existing domain, or create a new one automatically.
                </p>
            </div>

            <div id="flexx-new-domain-wrapper"
                 style="display:none; margin-top:15px; padding:12px;
                        border:1px dashed var(--color-border-input,rgba(80,80,80,0.97));
                        border-radius:4px;">
                <label style="display:block; font-weight:bold; margin-bottom:5px; font-size:13px;">
                    New Domain Name <span style="color:#E73A33;">*</span>
                </label>
                <input type="text" id="flexx-new-domain-name" class="form-control"
                    placeholder="e.g. staging.${sourceDomain}"
                    style="width:100%; background:var(--color-background,#fff); color:inherit;
                           padding:8px; border-radius:4px; font-size:14px;"
                    onfocus="document.getElementById('flexx-staging-error').style.display='none';">
                <p style="font-size:11px; margin:4px 0 0; opacity:0.7;">
                    This domain will be created in Hestia automatically before the sync begins.
                </p>
            </div>

            <div style="margin-top:20px;">
                <label style="display:block; font-weight:bold; margin-bottom:5px; font-size:13px;">
                    Sync Mode <span style="color:#E73A33;">*</span>
                </label>

                <label style="display:block; font-size:14px; margin-bottom:8px; padding:10px;
                              border:1px solid var(--color-border,rgba(80,80,80,0.97));
                              border-radius:4px; cursor:pointer;">
                    <input type="radio" name="flexx-sync-mode" value="1" style="margin-right:8px;" checked
                           onchange="document.getElementById('flexx-staging-error').style.display='none';">
                    <strong>FILES ONLY</strong>
                    <span style="font-size:12px; margin-left:8px; opacity:0.7;">(Safe for live eCommerce DB)</span>
                </label>

                <label style="display:block; font-size:14px; margin-bottom:8px; padding:10px;
                              border:1px solid var(--color-border,rgba(80,80,80,0.97));
                              border-radius:4px; cursor:pointer;">
                    <input type="radio" name="flexx-sync-mode" value="2" style="margin-right:8px;"
                           onchange="document.getElementById('flexx-staging-error').style.display='none';">
                    <strong>DATABASE ONLY</strong>
                    <span style="font-size:12px; color:#E73A33; margin-left:8px;">(Dangerous for live DBs)</span>
                </label>

                <label style="display:block; font-size:14px; padding:10px;
                              border:1px solid var(--color-border,rgba(80,80,80,0.97));
                              border-radius:4px; cursor:pointer;">
                    <input type="radio" name="flexx-sync-mode" value="3" style="margin-right:8px;"
                           onchange="document.getElementById('flexx-staging-error').style.display='none';">
                    <strong>ALL</strong>
                    <span style="font-size:12px; color:#E73A33; margin-left:8px;">(Overwrites Files + Database)</span>
                </label>
            </div>

            <div style="margin-top:25px; padding-top:15px;
                        border-top:1px solid var(--color-line,rgba(80,80,80,0.97));
                        display:flex; justify-content:flex-end; gap:10px;">
                <button onclick="document.getElementById('flexx-staging-modal').remove();"
                        class="button button-secondary"
                        style="padding:8px 15px; border:1px solid var(--color-line,rgba(80,80,80,0.97));
                               background:transparent; color:var(--color-text,#333);
                               cursor:pointer; border-radius:4px; font-weight:600;">
                    Cancel
                </button>
                <button onclick="validateAndConfirmStaging('${sourceDomain}', '${sourceUser}')"
                        class="button button-danger"
                        style="padding:8px 20px; border:none; background:#E73A33; color:#fff;
                               cursor:pointer; border-radius:4px; font-weight:600;">
                    Execute Sync
                </button>
            </div>
        </div>
    `;

    overlay.appendChild(panel);
    document.body.appendChild(overlay);

    overlay.addEventListener("click", e => {
        if (e.target === overlay) overlay.remove();
    });
}

function showStagingError(message) {
    const box = document.getElementById("flexx-staging-error");
    box.innerHTML = `<i class="fas fa-circle-exclamation" style="margin-right:5px;"></i>${message}`;
    box.style.display = "block";
}

function validateAndConfirmStaging(sourceDomain, sourceUser) {
    let targetDomain = document.getElementById("flexx-target-domain").value;
    const isNew      = targetDomain === "__NEW__";
    const syncModeEl = document.querySelector('input[name="flexx-sync-mode"]:checked');

    if (!targetDomain) {
        showStagingError("Please select a Target Domain.");
        return;
    }

    if (isNew) {
        targetDomain = document.getElementById("flexx-new-domain-name").value.trim().toLowerCase();
        if (!targetDomain || targetDomain.length < 4) {
            showStagingError("Please enter a valid new domain name (e.g. staging.example.com).");
            return;
        }
    }

    if (!syncModeEl) {
        showStagingError("Please select a Sync Mode.");
        return;
    }

    showConfirmationView(sourceDomain, targetDomain, syncModeEl.value, isNew, sourceUser);
}

function showConfirmationView(sourceDomain, targetDomain, syncMode, isNew, sourceUser) {
    document.getElementById("flexx-staging-body").innerHTML = `
        <div style="padding:10px 0; text-align:center;">
            <i class="fas fa-exclamation-triangle" style="font-size:40px; color:#ff9800; margin-bottom:15px;"></i>
            <h3 style="margin:0 0 10px; font-size:18px; color:var(--color-text,#333);">Confirm Synchronization</h3>
            <p style="font-size:14px; color:var(--color-text,#333); margin-bottom:20px;">
                You are about to sync data from <strong>${sourceDomain}</strong>
                to <strong>${targetDomain}</strong>.<br>
                This will overwrite the target based on the selected sync mode.
            </p>
            <div style="display:flex; justify-content:center; gap:15px;">
                <button onclick="document.getElementById('flexx-staging-modal').remove();"
                        class="button button-secondary"
                        style="padding:8px 20px; border:1px solid var(--color-line,rgba(80,80,80,0.97));
                               background:transparent; color:var(--color-text,#333);
                               cursor:pointer; border-radius:4px; font-weight:500;">
                    Cancel
                </button>
                <button onclick="finalExecuteStaging('${sourceDomain}','${targetDomain}','${syncMode}',${isNew},'${sourceUser}')"
                        class="button button-danger"
                        style="padding:8px 20px; border:none; background:#E73A33; color:#fff;
                               cursor:pointer; border-radius:4px; font-weight:600;">
                    Yes, Proceed!
                </button>
            </div>
        </div>
    `;
}

async function finalExecuteStaging(sourceDomain, targetDomain, syncMode, isNew, sourceUser) {
    const body = document.getElementById("flexx-staging-body");

    body.innerHTML = `
        <div style="padding:20px 0; text-align:center;">
            <i class="fas fa-circle-notch fa-spin" style="font-size:44px; color:#ff9800; margin-bottom:15px;"></i>
            <h3 style="margin:0 0 10px; font-size:18px; color:var(--color-text,#333);">Syncing in Progress...</h3>
            <p style="font-size:14px; color:var(--color-text,#333);">
                Please wait. Large sites may take several minutes.
            </p>
        </div>
    `;

    const token    = document.querySelector('input[name="token"]')?.value || "";
    const formData = new FormData();
    formData.append("action",        "sync");
    formData.append("token",         token);
    formData.append("source_domain", sourceDomain);
    formData.append("target_domain", targetDomain);
    formData.append("sync_mode",     syncMode);
    formData.append("source_user",   sourceUser);
    formData.append("create_new",    isNew);

    try {
        const res    = await fetch("/api/flexx_api.php", { method: "POST", body: formData });
        const result = await res.json();

        if (res.ok && result.success) {
            body.innerHTML = `
                <div style="padding:10px 0; text-align:center;">
                    <i class="fas fa-circle-check" style="font-size:44px; color:#4CAF50; margin-bottom:15px;"></i>
                    <h3 style="margin:0 0 10px; font-size:18px; color:var(--color-text,#333);">Sync Completed!</h3>
                    <div style="font-size:13px; color:var(--color-text,#333); text-align:left;
                                border:1px dashed var(--color-border,rgba(80,80,80,0.97));
                                border-radius:4px; padding:10px; margin-bottom:15px;
                                max-height:200px; overflow-y:auto;">
                        <strong>Command:</strong><br>
                        <code style="font-size:11px; word-break:break-all;">${result.cmd_run}</code>
                        <br><br>
                        <strong>Output:</strong>
                        <pre style="margin:6px 0 0; white-space:pre-wrap; font-family:monospace; font-size:12px;">${result.output || "No output."}</pre>
                    </div>
                    <button onclick="document.getElementById('flexx-staging-modal').remove(); window.location.reload();"
                            class="button button-secondary"
                            style="padding:8px 20px; border:1px solid var(--color-line,rgba(80,80,80,0.97));
                                   background:transparent; color:var(--color-text,#333);
                                   cursor:pointer; border-radius:4px; font-weight:600;">
                        Close &amp; Refresh
                    </button>
                </div>
            `;
        } else {
            throw new Error(result.error || "Unknown error during sync.");
        }

    } catch (err) {
        body.innerHTML = `
            <div style="padding:20px 0; text-align:center;">
                <i class="fas fa-circle-xmark" style="font-size:44px; color:#E73A33; margin-bottom:15px;"></i>
                <h3 style="margin:0 0 10px; font-size:18px; color:var(--color-text,#333);">Sync Failed</h3>
                <div style="font-size:13px; color:#E73A33; background:rgba(231,58,51,0.08);
                            padding:10px; border:1px solid rgba(231,58,51,0.25);
                            border-radius:4px; text-align:left; max-height:160px; overflow-y:auto;">
                    <strong>Error:</strong> ${err.message}
                </div>
                <button onclick="document.getElementById('flexx-staging-modal').remove();"
                        class="button button-secondary"
                        style="margin-top:15px; padding:8px 20px;
                               border:1px solid var(--color-line,rgba(80,80,80,0.97));
                               background:transparent; color:var(--color-text,#333);
                               cursor:pointer; border-radius:4px; font-weight:600;">
                    Close
                </button>
            </div>
        `;
    }
}
