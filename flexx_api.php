<?php
ob_start();

// flexx_api.php — backend for the Flexx-Staging HestiaCP panel integration
// handles three actions: sync, wp_check, wp_login
// installed at /web/[panel-domain]/public_html/api/flexx_api.php

// no timeout — large DB/file clones can take a while
set_time_limit(0);
ignore_user_abort(true);

// pulls in Hestia's session and auth context
include($_SERVER['DOCUMENT_ROOT'] . "/inc/main.php");

if (empty($_SESSION['user'])) {
    header('HTTP/1.1 401 Unauthorized');
    echo json_encode(['error' => 'Unauthorized. Please log in to HestiaCP.']);
    exit();
}

$token = $_POST['token'] ?? '';
if ($token !== $_SESSION['token']) {
    header('HTTP/1.1 403 Forbidden');
    echo json_encode(['error' => 'Invalid CSRF token.']);
    exit();
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('HTTP/1.1 405 Method Not Allowed');
    echo json_encode(['error' => 'Only POST requests are allowed.']);
    exit();
}

$action       = $_POST['action']        ?? 'sync';
$sourceDomain = $_POST['source_domain'] ?? '';
$targetDomain = $_POST['target_domain'] ?? '';
$syncMode     = (int)($_POST['sync_mode'] ?? 1);
$createNew    = filter_var($_POST['create_new'] ?? false, FILTER_VALIDATE_BOOLEAN);

// admins may be operating on another user's domain via "Login As"
$requestUser = !empty($_POST['source_user']) ? $_POST['source_user'] : $_SESSION['user'];

// whitelist action first — nothing else runs if this is bogus
if (!in_array($action, ['sync', 'wp_check', 'wp_login'])) {
    header('HTTP/1.1 400 Bad Request');
    echo json_encode(['error' => 'Invalid action. Expected: sync, wp_check, or wp_login.']);
    exit();
}

if (!preg_match('/^[a-zA-Z0-9_-]+$/', $requestUser)) {
    header('HTTP/1.1 400 Bad Request');
    echo json_encode(['error' => 'Invalid user format.']);
    exit();
}

if (empty($sourceDomain) || !preg_match('/^[a-zA-Z0-9.-]+$/', $sourceDomain)) {
    header('HTTP/1.1 400 Bad Request');
    echo json_encode(['error' => 'Invalid or missing source domain.']);
    exit();
}

// target and sync mode are only needed for sync
if ($action === 'sync') {
    if (empty($targetDomain) || !preg_match('/^[a-zA-Z0-9.-]+$/', $targetDomain)) {
        header('HTTP/1.1 400 Bad Request');
        echo json_encode(['error' => 'Invalid or missing target domain.']);
        exit();
    }
    if (!in_array($syncMode, [1, 2, 3])) {
        header('HTTP/1.1 400 Bad Request');
        echo json_encode(['error' => 'Invalid sync mode. Expected 1, 2, or 3.']);
        exit();
    }
}

$usernameArg = escapeshellarg($requestUser);
$sourceArg   = escapeshellarg($sourceDomain);
$targetArg   = escapeshellarg($targetDomain);
$syncArg     = escapeshellarg($syncMode);

// HESTIA_CMD is defined in main.php as "/usr/bin/sudo /usr/local/hestia/bin/"
// using it means we ride Hestia's existing sudoers rules — no custom entry needed
if ($action === 'wp_check') {
    $cmd = HESTIA_CMD . "v-flexx-staging --user $usernameArg --source $sourceArg --wp-check 2>&1";

} elseif ($action === 'wp_login') {
    $cmd = HESTIA_CMD . "v-flexx-staging --user $usernameArg --source $sourceArg --wp-login 2>&1";

} else {
    $createFlag = $createNew ? '--create-target' : '';
    $cmd = HESTIA_CMD . "v-flexx-staging --user $usernameArg --source $sourceArg --target $targetArg --sync $syncArg $createFlag 2>&1";
}

exec($cmd, $outputLines, $returnCode);
$rawOutput = implode("\n", $outputLines);
$trimmed  = trim($rawOutput);
$lastLine = trim(end($outputLines));

header('Content-Type: application/json');

$response = [
    'success' => true,
    'action'  => $action,
    'cmd_run' => $cmd,
    'output'  => $trimmed,
];

if ($action === 'wp_check') {
    $response['is_wp'] = ($lastLine === 'WP');

} elseif ($action === 'wp_login') {
    if (strpos($lastLine, 'http') === 0) {
        $response['login_url'] = $lastLine;
    } else {
        // script returned an error string instead of a URL
        $response['success'] = false;
        $response['error']   = $lastLine ?: 'Failed to generate login URL.';
        http_response_code(500);
    }

} else {
    // empty output means shell_exec got nothing back — something broke silently
    if (empty($trimmed)) {
        $response['success'] = false;
        $response['error']   = 'No output returned from the sync script.';
        http_response_code(500);
    }
}

echo json_encode($response);
exit();
?>
