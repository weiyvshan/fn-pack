[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $projectPath '..\..')).Path
$auditScript = Join-Path $repositoryRoot '.agents\skills\fnnas-app-creator\scripts\audit_fnos_project.ps1'
$bashPath = 'C:\Program Files\Git\bin\bash.exe'
$sourceCheckoutTest = Join-Path $projectPath 'tests\source-checkout.test.ps1'
$bundledSkillCreatorRelativeHashes = [ordered]@{
  'SKILL.md' = 'd34217ee6a048c57e5dda79374ce92c55e798bead5fce65db5873ad9fb4039ef'
  'references/openai_yaml.md' = '9fb5928b7f4a746fdb39df503ebbd7a659d5e64b47f85a60626aa1a03fd76b17'
  'references/powershell-authoring.md' = '68f4ea1d189fd7d9942dfdadb75e629405ce454f68577477458545e2637bbc4c'
  'scripts/generate_openai_yaml.sh' = '370cb18721efc9f7c6127aaebd2a367ec2118970c2dc4f8d4ff801e89324aecb'
  'scripts/init_skill.sh' = 'b60b85b9ac693215ecd1d4578f350b014f9fd8b9a9ae91789771f47725114edb'
  'scripts/quick_validate.sh' = '2f070718580206c62b5e547a5e7cd700b4eb2211aac8527e147311cf374bd7d8'
}
$bundledSkillCreatorRoot = Join-Path $projectPath 'app/builtin-skills/skill-creator'
$bundledSkillCreatorFiles = @(
  foreach ($relativePath in $bundledSkillCreatorRelativeHashes.Keys) {
    Get-Item -LiteralPath (Join-Path $bundledSkillCreatorRoot $relativePath)
  }
)

if (-not (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
  throw "Git Bash was not found at $bashPath"
}

$jsonFiles = @(
  'config/privilege',
  'config/resource',
  'app/ui/config',
  'wizard/install',
  'wizard/config',
  'app/server/package.json',
  'runtime.lock.json'
)
foreach ($relativePath in $jsonFiles) {
  $path = Join-Path $projectPath $relativePath
  Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable | Out-Null
}

$shellFiles = @(
  Get-ChildItem -LiteralPath (Join-Path $projectPath 'cmd') -File
  Get-Item -LiteralPath (Join-Path $projectPath 'app/dsh-launcher')
  Get-Item -LiteralPath (Join-Path $projectPath 'app/pnpm-launcher')
  Get-Item -LiteralPath (Join-Path $projectPath 'scripts/build-source-runtime.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'scripts/package-linux.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'scripts/materialize-workspace-links.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'tests/pnpm-launcher.test.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'tests/dsh-launcher.test.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'tests/main-lifecycle.test.sh')
  Get-Item -LiteralPath (Join-Path $projectPath 'tests/skill-creator.test.sh')
  Get-Item -LiteralPath (Join-Path $bundledSkillCreatorRoot 'scripts/generate_openai_yaml.sh')
  Get-Item -LiteralPath (Join-Path $bundledSkillCreatorRoot 'scripts/init_skill.sh')
  Get-Item -LiteralPath (Join-Path $bundledSkillCreatorRoot 'scripts/quick_validate.sh')
)
foreach ($file in $shellFiles) {
  & $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash -n "$script_path"' _ $file.FullName
  if ($LASTEXITCODE -ne 0) {
    throw "Shell syntax validation failed: $($file.FullName)"
  }
}

$textFiles = @($shellFiles.FullName) + @($bundledSkillCreatorFiles.FullName) + @(
  (Join-Path $projectPath 'app/builtin-skills/dsh-maintenance/SKILL.md'),
  (Join-Path $projectPath 'app/gateway-proxy.js'),
  (Join-Path $projectPath 'app/gateway-compat.js'),
  (Join-Path $projectPath 'app/gateway-websocket.js'),
  (Join-Path $projectPath 'app/summary-client-compat.js'),
  (Join-Path $projectPath 'app/select-loopback-port.js'),
  (Join-Path $projectPath 'app/backend-ready.js'),
  (Join-Path $projectPath 'app/web/fnos-open-enhancer.js'),
  (Join-Path $projectPath 'scripts/check-summary-client.mjs'),
  (Join-Path $projectPath 'scripts/generate-source-runtime.mjs'),
  (Join-Path $projectPath 'scripts/prune-source-runtime.mjs'),
  (Join-Path $projectPath 'patches/0002-dsh-plugin-profile-scoped-management.patch'),
  (Join-Path $projectPath 'patches/0004-web-app-private-auth-token-handoff.patch'),
  (Join-Path $projectPath 'patches/0007-attachment-storage-respect-access-boundary.patch'),
  (Join-Path $projectPath 'patches/0008-fnos-transport-defaults.patch'),
  (Join-Path $projectPath 'tests/config-common.test.sh'),
  (Join-Path $projectPath 'tests/fnos-open-enhancer.test.js'),
  (Join-Path $projectPath 'tests/gateway-websocket.test.js'),
  (Join-Path $projectPath 'tests/gateway-transport.test.js'),
  (Join-Path $projectPath 'tests/summary-client-compat.test.js'),
  (Join-Path $projectPath 'tests/summary-client-build.test.js'),
  (Join-Path $projectPath 'tests/fixtures/summary-client-bundle.js'),
  (Join-Path $projectPath 'tests/generate-source-runtime.test.mjs'),
  (Join-Path $projectPath 'tests/prune-source-runtime.test.mjs')
)
foreach ($path in $textFiles) {
  $bytes = [IO.File]::ReadAllBytes($path)
  for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
    if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
      throw "CRLF line endings are not allowed in NAS runtime files: $path"
    }
  }
}

$skillCreatorValidator = Join-Path $bundledSkillCreatorRoot 'scripts/quick_validate.sh'
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); skill_path=$(cygpath -u "$2"); exec /usr/bin/bash "$script_path" "$skill_path"' _ $skillCreatorValidator $bundledSkillCreatorRoot
if ($LASTEXITCODE -ne 0) { throw 'Bundled skill-creator validation failed.' }

$node = Get-Command node -ErrorAction Stop
& $node.Source --check (Join-Path $projectPath 'app/gateway-proxy.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-proxy.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/gateway-compat.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-compat.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/gateway-websocket.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-websocket.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/summary-client-compat.js')
if ($LASTEXITCODE -ne 0) { throw 'summary-client-compat.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'tests/fixtures/summary-client-bundle.js')
if ($LASTEXITCODE -ne 0) { throw 'summary-client-bundle.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/select-loopback-port.js')
if ($LASTEXITCODE -ne 0) { throw 'select-loopback-port.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/backend-ready.js')
if ($LASTEXITCODE -ne 0) { throw 'backend-ready.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'app/web/fnos-open-enhancer.js')
if ($LASTEXITCODE -ne 0) { throw 'fnos-open-enhancer.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'scripts/check-summary-client.mjs')
if ($LASTEXITCODE -ne 0) { throw 'check-summary-client.mjs syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'tests/summary-client-build.test.js')
if ($LASTEXITCODE -ne 0) { throw 'summary-client-build.test.js syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'scripts/generate-source-runtime.mjs')
if ($LASTEXITCODE -ne 0) { throw 'generate-source-runtime.mjs syntax validation failed.' }
& $node.Source --check (Join-Path $projectPath 'scripts/prune-source-runtime.mjs')
if ($LASTEXITCODE -ne 0) { throw 'prune-source-runtime.mjs syntax validation failed.' }
$selectedPortOutput = (& $node.Source (Join-Path $projectPath 'app/select-loopback-port.js') | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Loopback port selection failed.' }
$selectedPort = 0
if (-not [int]::TryParse($selectedPortOutput, [ref]$selectedPort) -or $selectedPort -lt 1 -or $selectedPort -gt 65535) {
  throw "Loopback port selector returned an invalid port: $selectedPortOutput"
}
& $node.Source (Join-Path $projectPath 'tests/gateway-proxy.test.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-proxy tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/gateway-websocket.test.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-websocket tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/gateway-transport.test.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-transport tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/summary-client-compat.test.js')
if ($LASTEXITCODE -ne 0) { throw 'summary-client-compat tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/summary-client-build.test.js')
if ($LASTEXITCODE -ne 0) { throw 'summary-client build gate tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/fnos-open-enhancer.test.js')
if ($LASTEXITCODE -ne 0) { throw 'fnos-open-enhancer tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/gateway-compat.test.js')
if ($LASTEXITCODE -ne 0) { throw 'gateway-compat tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/backend-ready.test.js')
if ($LASTEXITCODE -ne 0) { throw 'backend-ready tests failed.' }
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash "$script_path"' _ (Join-Path $projectPath 'tests/config-common.test.sh')
if ($LASTEXITCODE -ne 0) { throw 'config-common tests failed.' }
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash "$script_path"' _ (Join-Path $projectPath 'tests/pnpm-launcher.test.sh')
if ($LASTEXITCODE -ne 0) { throw 'pnpm launcher tests failed.' }
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash "$script_path"' _ (Join-Path $projectPath 'tests/dsh-launcher.test.sh')
if ($LASTEXITCODE -ne 0) { throw 'dsh launcher tests failed.' }
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash "$script_path"' _ (Join-Path $projectPath 'tests/main-lifecycle.test.sh')
if ($LASTEXITCODE -ne 0) { throw 'main lifecycle tests failed.' }
& $bashPath --noprofile --norc -c 'export PATH=/usr/bin:/bin; script_path=$(cygpath -u "$1"); exec /usr/bin/bash "$script_path"' _ (Join-Path $projectPath 'tests/skill-creator.test.sh')
if ($LASTEXITCODE -ne 0) { throw 'skill-creator tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/generate-source-runtime.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'generate-source-runtime tests failed.' }
& $node.Source (Join-Path $projectPath 'tests/prune-source-runtime.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'prune-source-runtime tests failed.' }
& pwsh -NoProfile -ExecutionPolicy Bypass -File $sourceCheckoutTest
if ($LASTEXITCODE -ne 0) { throw 'source checkout resolver tests failed.' }

function Get-PngDimensions([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 24) { throw "Invalid PNG: $Path" }
  $width = ($bytes[16] * 16777216) + ($bytes[17] * 65536) + ($bytes[18] * 256) + $bytes[19]
  $height = ($bytes[20] * 16777216) + ($bytes[21] * 65536) + ($bytes[22] * 256) + $bytes[23]
  return @($width, $height)
}

$iconChecks = @(
  @{ Path = 'ICON.PNG'; Size = 64 },
  @{ Path = 'ICON_256.PNG'; Size = 256 },
  @{ Path = 'app/ui/images/icon_64.png'; Size = 64 },
  @{ Path = 'app/ui/images/icon_256.png'; Size = 256 }
)
foreach ($check in $iconChecks) {
  $dimensions = Get-PngDimensions (Join-Path $projectPath $check.Path)
  if ($dimensions[0] -ne $check.Size -or $dimensions[1] -ne $check.Size) {
    throw "Unexpected icon dimensions for $($check.Path): $($dimensions -join 'x')"
  }
}

$runtimeLock = Get-Content -LiteralPath (Join-Path $projectPath 'runtime.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$serverMarker = Get-Content -LiteralPath (Join-Path $projectPath 'app/server/package.json') -Raw | ConvertFrom-Json -AsHashtable
$bundledMaintenanceSkillPath = Join-Path $projectPath 'app/builtin-skills/dsh-maintenance/SKILL.md'
$bundledMaintenanceSkillText = Get-Content -LiteralPath $bundledMaintenanceSkillPath -Raw
$bundledMaintenanceSkillHash = (Get-FileHash -LiteralPath $bundledMaintenanceSkillPath -Algorithm SHA256).Hash.ToLowerInvariant()
$bundledSkillCreatorText = Get-Content -LiteralPath (Join-Path $bundledSkillCreatorRoot 'SKILL.md') -Raw
$bundledSkillCreatorActualFiles = @(
  Get-ChildItem -LiteralPath $bundledSkillCreatorRoot -Recurse -File |
    ForEach-Object { [IO.Path]::GetRelativePath($bundledSkillCreatorRoot, $_.FullName).Replace('\', '/') } |
    Sort-Object
)
$bundledSkillCreatorExpectedFiles = @($bundledSkillCreatorRelativeHashes.Keys | Sort-Object)
$bundledSkillCreatorInventoryDifference = @(
  Compare-Object -ReferenceObject $bundledSkillCreatorExpectedFiles -DifferenceObject $bundledSkillCreatorActualFiles
)
$buildText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/build-fpk.ps1') -Raw
$packageLinuxText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/package-linux.sh') -Raw
$sourceResolverText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/resolve-upstream-source.ps1') -Raw
$sourceBuildText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/build-source-runtime.sh') -Raw
$sourcePrunerText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/prune-source-runtime.mjs') -Raw
$summaryClientCheckerText = Get-Content -LiteralPath (Join-Path $projectPath 'scripts/check-summary-client.mjs') -Raw
$manifestText = Get-Content -LiteralPath (Join-Path $projectPath 'manifest') -Raw
$manifestFields = @{}
foreach ($line in $manifestText -split "`r?`n") {
  if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $manifestFields[$matches[1]] = $matches[2] }
}
$configCommonText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/config-common') -Raw
$installCallbackText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/install_callback') -Raw
$uninstallCallbackText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/uninstall_callback') -Raw
$upgradeInitText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/upgrade_init') -Raw
$upgradeCallbackText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/upgrade_callback') -Raw
$gatewayProxyText = Get-Content -LiteralPath (Join-Path $projectPath 'app/gateway-proxy.js') -Raw
$fnosOpenEnhancerText = Get-Content -LiteralPath (Join-Path $projectPath 'app/web/fnos-open-enhancer.js') -Raw
$dshLauncherText = Get-Content -LiteralPath (Join-Path $projectPath 'app/dsh-launcher') -Raw
$terminalBashPath = Join-Path $repositoryRoot 'vendor/upstream/deepseek-harness/packages/terminal/terminal-bash/src/index.ts'
$terminalBashText = Get-Content -LiteralPath $terminalBashPath -Raw
if (Test-Path -LiteralPath (Join-Path $projectPath 'LICENSE')) {
  throw 'The application root must not contain a LICENSE file.'
}
if ($manifestFields['appname'] -cne 'deepseek-harness' -or
    $manifestFields['version'] -cne '0.0.18' -or
    $manifestFields['platform'] -cne 'x86') {
  throw 'The DeepSeek Harness manifest must use appname deepseek-harness, version 0.0.18, and platform x86.'
}
if ($bundledMaintenanceSkillHash -cne '309f2d6973a678533493905a779ea097a9be17c26d32aaa9bea2614e56ed07df' -or
    $bundledMaintenanceSkillText -notmatch '(?m)^name: dsh-maintenance$' -or
    $bundledMaintenanceSkillText -match '(?m)^name: gateway-route-injection$') {
  throw 'The bundled dsh-maintenance skill must match the reviewed source.'
}
if ($bundledSkillCreatorInventoryDifference.Count -ne 0) {
  throw 'The bundled skill-creator inventory must contain exactly the reviewed fnOS/Linux source subset and no PowerShell scripts.'
}
foreach ($relativePath in $bundledSkillCreatorRelativeHashes.Keys) {
  $skillFilePath = Join-Path $bundledSkillCreatorRoot $relativePath
  $skillFileHash = (Get-FileHash -LiteralPath $skillFilePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($skillFileHash -cne $bundledSkillCreatorRelativeHashes[$relativePath]) {
    throw "The bundled skill-creator file differs from the reviewed source contract: $relativePath"
  }
}
if ($bundledSkillCreatorText -notmatch '(?m)^name: skill-creator$' -or
    @(Get-ChildItem -LiteralPath $bundledSkillCreatorRoot -Recurse -File -Filter '*.ps1').Count -ne 0) {
  throw 'The bundled skill-creator identity is invalid or a PowerShell script remains in the fnOS package source.'
}
if (Test-Path -LiteralPath (Join-Path $projectPath 'app/builtin-skills/gateway-route-injection')) {
  throw 'The retired bundled gateway-route-injection skill path must not remain in the package source.'
}
if ($manifestText -match '(?m)^\s*(service_port|checkport)\s*=') {
  throw 'Gateway-only applications must not declare service_port or checkport.'
}
$mainText = Get-Content -LiteralPath (Join-Path $projectPath 'cmd/main') -Raw
if ($mainText -match 'TRIM_SERVICE_PORT' -or $mainText -notmatch 'select-loopback-port\.js' -or $mainText -match '\b120\b') {
  throw 'Lifecycle script still contains the fixed-port or long synchronous-start contract.'
}
if ($mainText -notmatch 'backend-ready\.js' -or $mainText -notmatch '45' -or $mainText -notmatch '\$DSH_PID' -or
    $mainText -notmatch 'STARTUP_STABILITY_SECONDS=15' -or
    $mainText -notmatch 'wait_for_backend_stability' -or
    $mainText -match 'apply_profile_compatibility|apply_profile_plugin_gate|start_service_with_upgrade_recovery|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade' -or
    $configCommonText -match 'migrate_dsh_home|migrate_profile_conflicts|upgrade-runtime-backup|stage_packaged_runtime_for_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade' -or
    $upgradeInitText -match 'migrate|stage_|restore_|upgrade-runtime' -or
    $upgradeCallbackText -match 'migrate|stage_|restore_|upgrade-runtime') {
  throw 'Lifecycle scripts must not perform profile, data, or runtime migration during startup or upgrade.'
}
if ($mainText -notmatch '(?s)require_package_start_identity\(\).*?id -u.*?TRIM_UID.*?必须通过 fnOS 应用中心启用' -or
    $mainText -notmatch '(?s)start_service\(\) \{\s*require_package_start_identity \|\| return 1') {
  throw 'Lifecycle startup must reject an unexpected UID before persistent-state writes.'
}
if ($mainText -match 'write_loopback_profile' -or $mainText -match 'cordis\.patch\.yml') {
  throw 'Lifecycle startup must not persist a second DSH webserver port source.'
}
if (-not $gatewayProxyText.Contains('rewriteRemoteWebUiLoopback') -or
    -not $gatewayProxyText.Contains('id: "@linxin666/dsh-remote-web-ui"') -or
    -not $gatewayProxyText.Contains('id: "@linxin666/dsh-web-all"') -or
    -not $gatewayProxyText.Contains('remote-web-ui: pair flow + heartbeats') -or
    -not $gatewayProxyText.Contains('remote-web-ui: remote desktop channel') -or
    -not $gatewayProxyText.Contains('const loopback = ctx.get("connection")?.isLoopback ?? true;') -or
    -not $gatewayProxyText.Contains('if (isLoopbackHostname(window.location.hostname)) return false;') -or
    -not $gatewayProxyText.Contains('if (isLoopbackHostname(hostname)) return false;')) {
  throw 'The fnOS gateway must keep the exact fail-closed remote-web-ui desktop compatibility adapter.'
}
if (-not $gatewayProxyText.Contains('rewriteBetterSidebarWebSocketResilience') -or
    -not $gatewayProxyText.Contains('dsh-fnos-better-sidebar-ws') -or
    -not $gatewayProxyText.Contains('/sidebar/ws/agent-terminals') -or
    -not $gatewayProxyText.Contains('/sidebar/ws/agent-opens') -or
    -not $gatewayProxyText.Contains('failures = 0;') -or
    -not $gatewayProxyText.Contains('socket.send(\"ping\")') -or
    -not $gatewayProxyText.Contains('}, 25000);') -or
    -not $gatewayProxyText.Contains('window.clearInterval(keepAlive)')) {
  throw 'The fnOS gateway must keep the fail-closed dsh-better-sidebar WebSocket resilience adapter.'
}
if (-not $fnosOpenEnhancerText.Contains('/open-in-app/apps') -or
    -not $fnosOpenEnhancerText.Contains('/open-in-app/open') -or
    -not $fnosOpenEnhancerText.Contains('/__fnos/export-session') -or
    -not $fnosOpenEnhancerText.Contains('/api/session.export') -or
    -not $fnosOpenEnhancerText.Contains('openFileManager') -or
    -not $fnosOpenEnhancerText.Contains('payload.app !== FILE_MANAGER_APP_ID') -or
    -not $fnosOpenEnhancerText.Contains('isEmbeddedHost()') -or
    -not $fnosOpenEnhancerText.Contains('withWebCarrierUserAgent') -or
    -not $fnosOpenEnhancerText.Contains('FNAppVer') -or
    -not $fnosOpenEnhancerText.Contains('SDK_READY_TIMEOUT_MS') -or
    -not $fnosOpenEnhancerText.Contains('fnosFileManagerAppsResponse(embedded)') -or
    -not $fnosOpenEnhancerText.Contains('openErrorResponse') -or
    -not $gatewayProxyText.Contains('serveLocalJavaScript(response, FNOS_OPEN_ENHANCER_FILE, "no-store")') -or
    $installCallbackText.Contains('fnos-open-enhancer') -or
    $upgradeCallbackText.Contains('fnos-open-enhancer')) {
  throw 'The packaged fnOS opener must provide the bounded Web carrier on fresh install and upgrade without lifecycle-time patching.'
}
if (-not $gatewayProxyText.Contains('SESSION_EXPORT_PATH') -or
    -not $gatewayProxyText.Contains('SESSION_EXPORT_UPSTREAM_PATH') -or
    -not $gatewayProxyText.Contains('SESSION_EXPORT_MAX_BYTES') -or
    -not $gatewayProxyText.Contains('validateSessionExportPayload') -or
    -not $gatewayProxyText.Contains('upstream session export was not a ZIP archive')) {
  throw 'The fnOS gateway must keep the authenticated, bounded Session ZIP export route.'
}
if (-not $gatewayProxyText.Contains('TRIM_DATA_SHARE_PATHS') -or
    -not $gatewayProxyText.Contains('TRIM_DATA_ACCESSIBLE_PATHS')) {
  throw 'The fnOS opener must include both package shares and user-authorized paths.'
}
$visibleRootConfigText = [regex]::Match($gatewayProxyText, '(?s)function readFnosEnvConfig\(.*?return \{').Value
if ($configCommonText -notmatch 'validate_package_home\(\)' -or
     $configCommonText -notmatch 'ensure_dsh_home\(\)' -or
    $mainText -notmatch 'unset DSH_ADDITIONAL_WRITABLE_ROOTS DSH_PERMISSION_MODE' -or
    $mainText -notmatch 'DSH_HOME="\$\{TRIM_PKGHOME\}/\.dsh"' -or
    $mainText -notmatch 'HOME="\$TRIM_PKGHOME"' -or
    $configCommonText -notmatch 'ensure_shell_state\(\)' -or
    $configCommonText -notmatch 'shell_state_root\(\)' -or
    $mainText -notmatch 'HISTFILE="\$SHELL_HISTORY_FILE"' -or
    $mainText -notmatch 'XDG_STATE_HOME="\$SHELL_XDG_STATE_HOME"' -or
    $mainText -notmatch 'XDG_CACHE_HOME="\$SHELL_XDG_CACHE_HOME"' -or
    $mainText -notmatch 'XDG_DATA_HOME="\$SHELL_XDG_DATA_HOME"' -or
    $installCallbackText -notmatch 'ensure_shell_state "\$TRIM_PKGVAR"' -or
    $upgradeCallbackText -notmatch 'ensure_shell_state "\$TRIM_PKGVAR"' -or
    $terminalBashText -notmatch "DSH_SHELL: '1'" -or
    $dshLauncherText -notmatch 'unset DSH_ADDITIONAL_WRITABLE_ROOTS DSH_PERMISSION_MODE' -or
    $gatewayProxyText -notmatch 'env\.TRIM_PKGHOME' -or
    $gatewayProxyText -notmatch 'env\.TRIM_PKGVAR' -or
    $gatewayProxyText -notmatch 'path\.join\(packageHome, "\.dsh"\)' -or
    $visibleRootConfigText -notmatch 'visibleRoots\.includes') {
  throw 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME and expose the normalized package root.'
}
if ($mainText -notmatch 'PNPM_BIN="\$\{TRIM_PKGVAR\}/bin"' -or
    $mainText -notmatch 'export PATH="\$\{PNPM_BIN\}:\$\{NODE_RUNTIME_BIN\}:' -or
    $mainText -notmatch '\[ ! -x "\$PNPM_LAUNCHER" \]' -or
    $mainText -notmatch '\[ ! -x "\$DSH_LAUNCHER" \]' -or
    $mainText -notmatch 'export DSH_FNOS_PLUGIN_POLICY=1') {
  throw 'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'
}
if ($mainText -notmatch 'BUNDLED_SKILL_DIR="\$\{TRIM_APPDEST\}/builtin-skills"' -or
    $mainText -notmatch 'BUNDLED_MAINTENANCE_SKILL="\$\{BUNDLED_SKILL_DIR\}/dsh-maintenance/SKILL\.md"' -or
    $mainText -notmatch 'BUNDLED_SKILL_CREATOR="\$\{BUNDLED_SKILL_DIR\}/skill-creator/SKILL\.md"' -or
    $mainText -notmatch 'export DSH_BUNDLED_SKILL_DIR="\$BUNDLED_SKILL_DIR"' -or
    $dshLauncherText -notmatch 'BUNDLED_SKILL_DIR="\$\{APP_DEST\}/builtin-skills"' -or
    $dshLauncherText -notmatch 'BUNDLED_MAINTENANCE_SKILL="\$\{BUNDLED_SKILL_DIR\}/dsh-maintenance/SKILL\.md"' -or
    $dshLauncherText -notmatch 'BUNDLED_SKILL_CREATOR="\$\{BUNDLED_SKILL_DIR\}/skill-creator/SKILL\.md"' -or
    $dshLauncherText -notmatch 'export DSH_BUNDLED_SKILL_DIR="\$BUNDLED_SKILL_DIR"') {
  throw 'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
}
if (@($mainText, $dshLauncherText, $configCommonText, $installCallbackText, $uninstallCallbackText, $upgradeInitText, $upgradeCallbackText) -match '\$\{?TRIM_PKGVAR\}?/bundled-skills|DSH_HOME.*/skills/(?:dsh-maintenance|skill-creator)|setfacl.*skills|chown.*skills') {
  throw 'Lifecycle and launcher code must not synchronize bundled skills through persistent state or manage user-skill ACLs.'
}
if ($mainText -notmatch 'AUTH_TOKEN_FILE="\$\{TRIM_PKGVAR\}/web-auth\.token"' -or
    $mainText -notmatch 'DSH_WEB_AUTH_TOKEN_FILE="\$AUTH_TOKEN_FILE"' -or
    $mainText -notmatch '--trusted-host 127\.0\.0\.1' -or
    $mainText -notmatch 'rm -f -- "\$PORT_FILE" "\$AUTH_TOKEN_FILE"' -or
    $gatewayProxyText -notmatch 'readLaunchToken' -or
    $gatewayProxyText -notmatch 'tokenExchangePath' -or
    $gatewayProxyText -notmatch 'backendAuthCookieName') {
  throw 'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
}
if ($mainText -match '(?m)^\s*(?:nohup\s+)?(?:env\s+\\\s*)?.*\$DSH_ENTRY.*--no-open') {
  throw 'Lifecycle startup must rely on the managed token handoff instead of passing --no-open to retained Web profiles.'
}
if ($configCommonText -notmatch 'install_dsh_launcher\(\)' -or
    $configCommonText -notmatch 'chmod 700 "\$temporary"' -or
    $installCallbackText -notmatch 'install_dsh_launcher "\$TRIM_APPDEST" "\$TRIM_PKGVAR"' -or
    $upgradeCallbackText -notmatch 'install_dsh_launcher "\$TRIM_APPDEST" "\$TRIM_PKGVAR"' -or
    $dshLauncherText -notmatch 'APP_DEST="/var/apps/\$\{APP_NAME\}/target"' -or
    $dshLauncherText -notmatch 'DSH_HOME="\$\{PKG_HOME\}/\.dsh"' -or
    $dshLauncherText -notmatch 'DSH_FNOS_PLUGIN_POLICY=1' -or
    $dshLauncherText -notmatch 'PATH="\$\{SCRIPT_DIR\}:\$\{NODE_RUNTIME_BIN\}:/usr/local/bin:/usr/bin:/bin"') {
  throw 'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
}
if ($configCommonText -match 'stage_packaged_runtime_for_upgrade|materialize_pending_packaged_runtime|stage_profile_manifest_for_upgrade|stage_settings_document_for_upgrade|restore_staged_profile_manifest|restore_staged_settings_document|has_pending_packaged_runtime_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade|upgrade-runtime-backup' -or
    $upgradeInitText -match 'stage_packaged_runtime_for_upgrade|restore_pending_packaged_runtime' -or
    $upgradeCallbackText -match 'materialize_pending_packaged_runtime|migrate_profile_conflicts|upgrade-runtime-backup' -or
    $mainText -match 'start_service_with_upgrade_recovery|has_pending_packaged_runtime_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade') {
  throw 'Upgrade hooks must stop and validate the package without creating migration backups.'
}
if ($configCommonText -notmatch 'prepare_landlock_launcher\(\)' -or
    $configCommonText -notmatch 'chmod 0755 "\$launcher"' -or
    $installCallbackText -notmatch 'prepare_landlock_launcher "\$TRIM_APPDEST"' -or
    $upgradeCallbackText -notmatch 'prepare_landlock_launcher "\$TRIM_APPDEST"' -or
    $mainText -notmatch 'LANDLOCK_LAUNCHER="\$\{TRIM_APPDEST\}/server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run"' -or
    $mainText -notmatch 'landlock_probe=\$\("\$LANDLOCK_LAUNCHER" --probe' -or
    $mainText -notmatch 'landlock: fully enforced' -or
    $mainText -notmatch 'landlock: partially enforced \(older ABI\)') {
  throw 'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
}
if ($mainText -notmatch 'web\s+--port\s+"\$PORT"\s+--trusted-host\s+127\.0\.0\.1') {
  throw 'Lifecycle startup must pass the selected loopback port only through the DSH CLI.'
}
if ($mainText -match '\b(?:NODE_OPTIONS|NODE_USE_ENV_PROXY)\b' -or $mainText -match '\bexport\s+(?:HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy|npm_config_proxy|npm_config_https_proxy|npm_config_noproxy)\b') {
  throw 'Proxy activation must not use global Node options or export proxy variables from the lifecycle shell.'
}
if ($mainText -notmatch '(?s)validate_proxy_runtime\(\).*?\[ -n "\$PROXY_URL" \] \|\| return 0.*?--help.*?grep -Fq -- ''--use-env-proxy''') {
  throw 'Configured proxies must be gated by an explicit Node --use-env-proxy capability check.'
}
foreach ($proxyVariable in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'npm_config_proxy', 'npm_config_https_proxy')) {
  $expectedLine = '      ' + $proxyVariable + '="$PROXY_URL" \'
  if (-not $mainText.Contains($expectedLine)) {
    throw "The DSH launch environment is missing $proxyVariable."
  }
}
foreach ($noProxyVariable in @('NO_PROXY', 'no_proxy', 'npm_config_noproxy')) {
  $expectedLine = '      ' + $noProxyVariable + '="127.0.0.1,localhost" \'
  if (-not $mainText.Contains($expectedLine)) {
    throw "The DSH launch environment is missing the loopback exclusion $noProxyVariable."
  }
}
if ($mainText -notmatch '(?m)^\s+"\$NODE_BIN" --use-env-proxy "\$DSH_ENTRY" web --port "\$PORT" --trusted-host 127\.0\.0\.1') {
  throw 'The configured-proxy DSH command must enable Node environment proxy support.'
}
if ($mainText -notmatch '(?m)^\s+nohup "\$NODE_BIN" "\$DSH_ENTRY" web --port "\$PORT" --trusted-host 127\.0\.0\.1') {
  throw 'The no-proxy DSH command must remain free of the proxy switch and injected environment.'
}
if ($mainText -notmatch '(?s)select_terminal_shell\(\) \{.*?\[ -x /bin/bash \].*?SHELL=/bin/bash.*?\[ -x /bin/sh \].*?SHELL=/bin/sh.*?export SHELL.*?\}' -or
    $mainText -notmatch '(?s)mkdir -p "\$TRIM_PKGVAR".*?ensure_shell_state "\$TRIM_PKGVAR".*?select_terminal_shell \|\| return 1.*?start_dsh_process') {
  throw 'Lifecycle startup must export a controlled bash-or-sh terminal shell before starting DSH.'
}
if ($mainText -match '(?i)(?:/etc/passwd|\bchsh\b|\busermod\b)') {
  throw 'Terminal compatibility must not make the fnOS package account login-capable.'
}
if ($runtimeLock.schema -ne 5 -or
    $runtimeLock.upstream_repository -ne 'https://github.com/deepseek-ai/deepseek-harness.git' -or
    $runtimeLock.upstream_commit -notmatch '^[0-9a-f]{40}$' -or
    $runtimeLock.upstream_tree -notmatch '^[0-9a-f]{40}$' -or
    $runtimeLock.pnpm_lock_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $runtimeLock.cli_package_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $runtimeLock.target -ne 'linux-x64-gnu' -or
    $runtimeLock.platform -ne 'x86' -or
    $runtimeLock.workspace_closure_algorithm -ne 2) {
  throw 'runtime.lock.json contains an invalid official source lock.'
}
$gitmodulesPath = Join-Path $repositoryRoot '.gitmodules'
if (-not (Test-Path -LiteralPath $gitmodulesPath -PathType Leaf)) {
  throw 'The repository must declare the locked DeepSeek Harness upstream submodule.'
}
$submodulePath = (& git config -f $gitmodulesPath --get 'submodule.deepseek-harness.path' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $submodulePath -cne 'vendor/upstream/deepseek-harness') {
  throw 'The DeepSeek Harness submodule path is invalid.'
}
$submoduleUrl = (& git config -f $gitmodulesPath --get 'submodule.deepseek-harness.url' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $submoduleUrl -cne $runtimeLock.upstream_repository) {
  throw 'The DeepSeek Harness submodule URL does not match runtime.lock.json.'
}
$null = & git config -f $gitmodulesPath --get 'submodule.deepseek-harness.branch' 2>$null
if ($LASTEXITCODE -eq 0) {
  throw 'The DeepSeek Harness submodule must not track a branch.'
}
if ($LASTEXITCODE -ne 1) {
  throw 'Unable to inspect the DeepSeek Harness submodule branch declaration.'
}
$gitlink = (& git -C $repositoryRoot ls-files --stage -- 'vendor/upstream/deepseek-harness' | Out-String).Trim()
$gitlinkMatch = [regex]::Match($gitlink, '^160000\s+([0-9a-f]{40})\s+\d+\s+')
if ($LASTEXITCODE -ne 0 -or
    -not $gitlinkMatch.Success -or
    $gitlinkMatch.Groups[1].Value -cne $runtimeLock.upstream_commit) {
  throw 'The DeepSeek Harness gitlink does not match runtime.lock.json.'
}
$sourcePatchLocks = @($runtimeLock.source_patches)
$expectedSourcePatches = @(
  @{
    path = 'patches/0002-dsh-plugin-profile-scoped-management.patch'
    artifact_path = 'source-patches/0002-dsh-plugin-profile-scoped-management.patch'
    sha256 = '955c619b25940b37f91e31b23b0c7f9ced89159e93edc9d648f7686fe1db05b8'
    test_target = 'packages/boot/plugin-manager/tests/operations.spec.ts'
  },
  @{
    path = 'patches/0004-web-app-private-auth-token-handoff.patch'
    artifact_path = 'source-patches/0004-web-app-private-auth-token-handoff.patch'
    sha256 = '2d0042a10d0b65962309a7abe750d9b73ae1205ccc8398df6b09cd3ebafeb9ad'
    test_target = 'packages/bundle/web-app/tests/web-app.spec.ts'
  },
  @{
    path = 'patches/0007-attachment-storage-respect-access-boundary.patch'
    artifact_path = 'source-patches/0007-attachment-storage-respect-access-boundary.patch'
    sha256 = '592a2e95d8421a65f153b8565036c2b76e8db265b5d02aea1ce73a01033c250c'
    test_target = 'packages/attachment/attachment-local/tests/store.spec.ts'
  },
  @{
    path = 'patches/0008-fnos-transport-defaults.patch'
    artifact_path = 'source-patches/0008-fnos-transport-defaults.patch'
    sha256 = 'cb37de2416c84ddb48239d000cd27d00c9431825d31472e21d767ca5b6a90a12'
    test_target = 'packages/api/gateway/tests/gateway-stream.host.spec.ts packages/client/connection/tests/recovery-config.client.spec.ts'
  }
)
if ($sourcePatchLocks.Count -ne $expectedSourcePatches.Count) {
  throw 'runtime.lock.json must contain exactly four ordered source patches.'
}
for ($index = 0; $index -lt $expectedSourcePatches.Count; $index++) {
  $sourcePatchLock = $sourcePatchLocks[$index]
  $expectedSourcePatch = $expectedSourcePatches[$index]
  if ($sourcePatchLock -isnot [Collections.IDictionary] -or
      $sourcePatchLock.path -cne $expectedSourcePatch.path -or
      $sourcePatchLock.artifact_path -cne $expectedSourcePatch.artifact_path -or
      $sourcePatchLock.sha256 -cne $expectedSourcePatch.sha256 -or
      $sourcePatchLock.test_target -cne $expectedSourcePatch.test_target) {
    throw "runtime.lock.json contains an invalid or out-of-order source patch lock at index $index."
  }
  $sourcePatchPath = Join-Path $projectPath $sourcePatchLock.path
  $sourcePatchHash = (Get-FileHash -LiteralPath $sourcePatchPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sourcePatchHash -cne $sourcePatchLock.sha256) {
    throw "Source patch hash does not match runtime.lock.json: $sourcePatchHash"
  }
}
if ($serverMarker.dependencies['@deepseek-ai/dsh'] -ne $runtimeLock.dsh_version) {
  throw 'The source runtime marker must use the locked official DSH version.'
}
if ($buildText -match '\bRuntimeFpk\b' -or
    $buildText -match 'techysy/deepseek-harness-fnos' -or
    $buildText -match '\$sourceCache' -or
    $buildText -notmatch 'resolve-upstream-source\.ps1' -or
    $buildText -notmatch '(?s)git.*archive' -or
    $buildText -notmatch 'Get-GitBlobSha256' -or
    $buildText -notmatch "cat-file', 'blob'" -or
    $buildText -notmatch 'build-source-runtime\.sh' -or
    $buildText -notmatch 'package-linux\.sh' -or
    $buildText -notmatch 'Source patch SHA-256 mismatch' -or
    $buildText -notmatch 'source-patches/0002-dsh-plugin-profile-scoped-management\.patch' -or
    $buildText -notmatch 'source-patches/0004-web-app-private-auth-token-handoff\.patch' -or
    $buildText -notmatch 'source-patches/0007-attachment-storage-respect-access-boundary\.patch' -or
    $buildText -notmatch 'source-patches/0008-fnos-transport-defaults\.patch' -or
    $buildText -notmatch '\$\{appName\}_\$\{version\}_\$\{platform\}\.fpk' -or
    $sourceBuildText -notmatch 'node-linker=hoisted' -or
    $sourceBuildText -notmatch '<source-commit> <dsh-version>' -or
    $sourceBuildText -notmatch '\(<source\.patch> <patch-sha256> <test-target>\)\.\.\.' -or
    $buildText -notmatch '\$wslRuntimeArchive, \$sourceCommit, \$runtimeLock' -or
    $sourceBuildText -notmatch '\$\{#source_commit\}.*-eq 40' -or
    $sourceBuildText -notmatch 'DSH_BUILD_CLIENT_PROFILE=official DSH_CLIENT_COMMIT_HASH="\$source_commit" pnpm run build' -or
    $sourceBuildText -notmatch 'git apply --check --whitespace=error-all "\$source_patch"' -or
    $sourceBuildText -notmatch "IFS=' ' read -r -a test_targets" -or
    $sourceBuildText -notmatch 'pnpm exec vitest run "\$\{test_targets\[@\]\}"' -or
    $sourceBuildText -notmatch 'A locked source patch test target must be under packages/' -or
    $sourceBuildText -notmatch 'vitest run --config vitest\.e2e\.config\.ts packages/sandbox/sandbox-local/tests/landlock\.e2e\.ts' -or
    $sourceBuildText -notmatch 'vitest run apps/cli/tests/args\.spec\.ts' -or
    $sourceBuildText -notmatch 'vitest run apps/cli/tests/plugin-fnos\.spec\.ts' -or
    $sourceBuildText -notmatch 'run_vitest_with_retries 3 --config vitest\.e2e\.config\.ts apps/cli/tests/built-bin\.e2e\.ts' -or
    $sourceBuildText -notmatch 'generate-source-runtime\.mjs' -or
    $sourceBuildText -notmatch 'prune-source-runtime\.mjs' -or
    $sourceBuildText -match '--no-frozen-lockfile' -or
    $sourceBuildText -notmatch '(?s)generate-source-runtime\.mjs.*?install --offline --frozen-lockfile' -or
    $sourceBuildText -notmatch 'materialize-workspace-links\.sh' -or
    $sourceBuildText -notmatch '<landlock\.tgz>' -or
    $sourceBuildText -notmatch 'install -D -m 0755.*landlock-run' -or
    $sourceBuildText -notmatch 'node_modules/node-pty/prebuilds/linux-x64/pty\.node' -or
    $buildText -notmatch '@img\\sharp-linux-x64\\lib' -or
    $buildText -notmatch "Filter '\*\.node'" -or
    $buildText -notmatch '\$nestedFileEntries' -or
    $sourceBuildText -notmatch 'find "\$sharp_package_lib" -maxdepth 1 -type f -name ''\*\.node''' -or
    $sourceBuildText -notmatch '(?s)materialize-workspace-links\.sh.*?chmod 0755 "\$landlock_launcher"' -or
    $sourceBuildText -notmatch '"\$landlock_launcher" --probe' -or
    $sourcePrunerText -notmatch 'typescript_sources' -or
    $sourcePrunerText -notmatch 'source_maps' -or
    $sourcePrunerText -notmatch 'development_directories' -or
    $sourcePrunerText -notmatch 'unsupported_platform_prebuilds' -or
    $buildText -notmatch 'Final app\.tgz contains unsupported node-pty prebuilds' -or
    $sourcePrunerText -notmatch 'node_modules/node-pty/prebuilds/linux-x64/pty\.node') {
  throw 'The build must consume the locked official Git source without an upstream FPK.'
}
if ($sourceResolverText -notmatch "SubmodulePath = 'vendor/upstream/deepseek-harness'" -or
    $sourceResolverText -notmatch 'Initialize-LockedSubmodule' -or
    $sourceResolverText -notmatch 'clone --no-checkout' -or
    $sourceResolverText -notmatch 'checkout --detach' -or
    $sourceResolverText -notmatch "ls-files', '--stage'" -or
    $sourceResolverText -notmatch 'must pin a commit without a tracking branch' -or
    $sourceResolverText -notmatch 'must be clean because local changes are not build inputs' -or
    $sourceResolverText -match 'deepseek-harness-source') {
  throw 'The source resolver must enforce the clean pinned upstream submodule contract.'
}
$pnpmLock = $runtimeLock.pnpm
if ($pnpmLock.version -notmatch '^\d+\.\d+\.\d+$' -or
    $pnpmLock.asset_name -ne "pnpm-$($pnpmLock.version).tgz" -or
    $pnpmLock.asset_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $pnpmLock.integrity -notmatch '^sha512-[A-Za-z0-9+/]+={0,2}$') {
  throw 'runtime.lock.json contains an invalid pnpm supply-chain lock.'
}
$landlockLock = $runtimeLock.landlock_run
if ($landlockLock.package_name -ne '@deepseek-ai/node-addon-system-linux-x64' -or
    $landlockLock.version -notmatch '^\d+\.\d+\.\d+$' -or
    $landlockLock.asset_name -ne "node-addon-system-linux-x64-$($landlockLock.version).tgz" -or
    $landlockLock.asset_url -ne "https://registry.npmjs.org/@deepseek-ai/node-addon-system-linux-x64/-/$($landlockLock.asset_name)" -or
    $landlockLock.asset_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $landlockLock.integrity -notmatch '^sha512-[A-Za-z0-9+/]+={0,2}$' -or
    $landlockLock.binary_path -ne 'bin/landlock-run') {
  throw 'runtime.lock.json contains an invalid landlock-run supply-chain lock.'
}
$trimSdkLockPath = Join-Path $projectPath 'app\web\trim-web-app.lock.json'
$trimSdkLock = Get-Content -LiteralPath $trimSdkLockPath -Raw | ConvertFrom-Json -AsHashtable
$trimSdkArtifactPath = Join-Path $projectPath ($trimSdkLock['artifact_path'].Replace('/', '\'))
if ($trimSdkLock['source_package']['name'] -ne '@trimjs/web-app' -or
    $trimSdkLock['source_package']['version'] -notmatch '^\d+\.\d+\.\d+$' -or
    $trimSdkLock['artifact_sha256'] -notmatch '^[0-9a-f]{64}$' -or
    -not (Test-Path -LiteralPath $trimSdkArtifactPath -PathType Leaf)) {
  throw 'The vendored fnOS JS SDK lock is invalid.'
}
$trimSdkHash = (Get-FileHash -LiteralPath $trimSdkArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($trimSdkHash -cne $trimSdkLock['artifact_sha256'] -or
    (Get-Item -LiteralPath $trimSdkArtifactPath).Length -ne [long]$trimSdkLock['artifact_bytes']) {
  throw 'The vendored fnOS JS SDK artifact does not match its lock.'
}
if ($buildText -notmatch '\[string\]\$LandlockTarball' -or
    $buildText -notmatch 'landlock-run tarball SHA-256 mismatch' -or
    $buildText -notmatch 'landlock-run tarball integrity mismatch' -or
    $buildText -notmatch 'server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run' -or
    $buildText -notmatch 'The final app\.tgz strips the landlock-run mode but lifecycle permission repair is missing' -or
    $buildText -notmatch 'The final app\.tgz landlock-run binary differs from the locked official binary') {
  throw 'The FPK build must verify the locked landlock-run asset and final executable payload.'
}
if ($buildText -notmatch 'Resolve-WslDistribution' -or
    -not $buildText.Contains('Debian-\d+') -or
    $buildText -notmatch 'Read-ManifestFields' -or
    $buildText -notmatch 'Final FPK manifest is missing source field' -or
    $buildText -notmatch 'Final FPK manifest changed source field' -or
    $buildText -notmatch 'generatedManifestFields' -or
    $buildText -match 'stagedManifestHash' -or
    $packageLinuxText -notmatch 'existing_artifacts' -or
    $packageLinuxText -notmatch 'fnpack must produce exactly one FPK') {
  throw 'The FPK build must resolve the available WSL distribution and validate normalized manifest fields plus isolated output.'
}
if ($buildText -notmatch 'Get-BuildComponent' -or
    $buildText -notmatch 'Write-Utf8Json' -or
    $buildText -notmatch 'build-info\.json' -or
    $buildText -notmatch 'source-only server marker' -or
    $buildText -notmatch 'build provenance identity is invalid' -or
    $buildText -notmatch 'component differs from build provenance' -or
    $buildText -notmatch 'BuildInfoSHA256' -or
    $buildText -notmatch 'gateway-websocket\.js' -or
    $buildText -notmatch 'summary-client-compat\.js' -or
    $buildText -notmatch 'check-summary-client\.mjs' -or
    $buildText -notmatch 'summaryClientCheckerPath' -or
    $buildText -notmatch '& \$node\.Source \$summaryClientCheckerPath \$summaryClientCompatPath \$summaryClientBundlePath' -or
    $buildText -match 'assertKnownChangesSummaryClient' -or
    $buildText -match 'rewriteChangesSummaryClient' -or
    $buildText -match 'new vm\.Script\(adapted') {
  throw 'The FPK build must emit deterministic device-readable provenance and invoke the shared summary-client compatibility checker.'
}
if ($summaryClientCheckerText -notmatch 'assertKnownChangesSummaryClient' -or
    $summaryClientCheckerText -notmatch 'rewriteChangesSummaryClient' -or
    $summaryClientCheckerText -notmatch 'new vm\.Script\(adapted' -or
    $summaryClientCheckerText -notmatch 'process\.argv\.slice\(2\)' -or
    $summaryClientCheckerText -notmatch 'summary-client build gate passed') {
  throw 'The shared summary-client compatibility checker must validate legacy shape, adapted shape, arguments, and rewritten script syntax.'
}
if ($buildText -notmatch '(?s)\$summaryClientBundlePath.*?& \$node\.Source \$summaryClientCheckerPath \$summaryClientCompatPath \$summaryClientBundlePath.*?\$yamlPackagePath') {
  throw 'The shared summary-client compatibility gate must run after runtime extraction and before packaging checks.'
}
if (([regex]::Matches($buildText, [regex]::Escape('builtin-skills/dsh-maintenance/SKILL.md'))).Count -lt 2 -or
    $buildText -match 'builtin-skills/gateway-route-injection/SKILL\.md|builtin-skills/skill-creator/scripts/[^''"]+\.ps1|TRIM_PKGVAR.*bundled-skills') {
  throw 'The FPK build must record and require the packaged dsh-maintenance skill and the PowerShell-free skill-creator subset.'
}
foreach ($relativePath in $bundledSkillCreatorRelativeHashes.Keys) {
  $packagedSkillPath = "builtin-skills/skill-creator/$relativePath"
  if (([regex]::Matches($buildText, [regex]::Escape($packagedSkillPath))).Count -lt 2) {
    throw "The FPK build does not record and require bundled skill-creator file: $relativePath"
  }
}
if (Test-Path -LiteralPath (Join-Path $projectPath 'app/build-info.json')) {
  throw 'build-info.json must be generated per build instead of retained in the source app tree.'
}
if ($mainText -match 'danger-full-access') {
  throw 'The fnOS lifecycle must not disable sandboxing to work around a missing backend.'
}
$pnpmLauncher = Get-Content -LiteralPath (Join-Path $projectPath 'app/pnpm-launcher') -Raw
if ($pnpmLauncher -notmatch 'TRIM_APPDEST' -or
    $pnpmLauncher -notmatch 'TRIM_PKGVAR' -or
    $pnpmLauncher -notmatch 'pnpm/bin/pnpm\.cjs' -or
    $pnpmLauncher -notmatch 'DSH_PLUGIN_STORE_DIR' -or
    $pnpmLauncher -notmatch '\.dsh/profiles' -or
    $pnpmLauncher -notmatch '\[ -L "\$checked_path" \]' -or
    $pnpmLauncher -notmatch '\[\[:cntrl:\]\]' -or
    $pnpmLauncher -notmatch 'pnpm_config_store_dir="\$PNPM_STORE"' -or
    $pnpmLauncher -notmatch 'npm_config_proxy' -or
    $pnpmLauncher -notmatch 'npm_config_https_proxy' -or
    $pnpmLauncher -notmatch 'npm_config_noproxy' -or
    $pnpmLauncher -notmatch 'HTTP_PROXY' -or
    $pnpmLauncher -notmatch 'HTTPS_PROXY' -or
    $pnpmLauncher -notmatch 'NO_PROXY' -or
    $pnpmLauncher -notmatch 'PATH="\$\{NODE_RUNTIME_BIN\}:' -or
    $pnpmLauncher -match '--store-dir') {
  throw 'The pnpm launcher must validate stores and pass the selected store plus Node 24 through the environment.'
}

$auditJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File $auditScript -ProjectPath $projectPath -Format json
if ($LASTEXITCODE -ne 0) { throw 'fnOS static audit command failed.' }
$audit = $auditJson | ConvertFrom-Json -AsHashtable
if ($audit.summary.high -gt 0) {
  throw "fnOS static audit reported $($audit.summary.high) high-severity finding(s)."
}

[pscustomobject]@{
  Project = $projectPath
  JsonFiles = $jsonFiles.Count
  ShellFiles = $shellFiles.Count
  ProxyTests = 'passed'
  LoopbackPortSelectorTests = 'passed'
  ConfigTests = 'passed'
  AuditHigh = $audit.summary.high
  AuditMedium = $audit.summary.medium
  AuditFindings = $audit.findings
}
