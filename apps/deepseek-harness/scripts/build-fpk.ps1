[CmdletBinding()]
param(
  [string]$SourceTree,
  [string]$PnpmTarball,
  [string]$LandlockTarball,
  [string]$PnpmStoreDir,
  [string]$PackageTempDir,
  [string]$WslDistribution = 'Debian',
  [switch]$AllowDownload
)

$ErrorActionPreference = 'Stop'

$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $projectPath '..\..')).Path
$temporaryRoot = Join-Path $repositoryRoot '.tmp'
$buildDirectory = Join-Path $repositoryRoot 'build'
$manifestPath = Join-Path $projectPath 'manifest'
$runtimeLockPath = Join-Path $projectPath 'runtime.lock.json'
$fnpackResolver = Join-Path $repositoryRoot '.agents\skills\fnnas-app-creator\scripts\resolve-fnpack.ps1'
$fnpackPath = & $fnpackResolver -Platform linux -Architecture x64 -BundledOnly
$testScript = Join-Path $PSScriptRoot 'test-package.ps1'
$linuxBuildScript = Join-Path $PSScriptRoot 'build-source-runtime.sh'
$linuxPackageScript = Join-Path $PSScriptRoot 'package-linux.sh'
$summaryClientCheckerPath = Join-Path $PSScriptRoot 'check-summary-client.mjs'
$sourceResolverScript = Join-Path $PSScriptRoot 'resolve-upstream-source.ps1'

& pwsh -NoProfile -ExecutionPolicy Bypass -File $testScript
if ($LASTEXITCODE -ne 0) {
  throw 'Source validation failed before build.'
}

$node = Get-Command node -ErrorAction Stop
if (-not (Test-Path -LiteralPath $summaryClientCheckerPath -PathType Leaf)) {
  throw "The shared summary client compatibility checker is missing: $summaryClientCheckerPath"
}
$runtimeLock = Get-Content -LiteralPath $runtimeLockPath -Raw | ConvertFrom-Json -AsHashtable
$sourcePatchLocks = @($runtimeLock['source_patches'])
$pnpmLock = $runtimeLock['pnpm']
$landlockLock = $runtimeLock['landlock_run']
if ($runtimeLock['schema'] -ne 5 -or
    $sourcePatchLocks.Count -ne 5 -or
    @($sourcePatchLocks | Where-Object { $_ -isnot [Collections.IDictionary] }).Count -ne 0 -or
    $pnpmLock -isnot [Collections.IDictionary] -or
    $landlockLock -isnot [Collections.IDictionary]) {
  throw 'runtime.lock.json must use schema 5 and contain five ordered source_patches plus pnpm and landlock_run objects.'
}

$manifestText = Get-Content -LiteralPath $manifestPath -Raw
$appNameMatch = [regex]::Match($manifestText, '(?m)^appname\s*=\s*([^\s#]+)\s*$')
$versionMatch = [regex]::Match($manifestText, '(?m)^version\s*=\s*([^\s#]+)\s*$')
if (-not $appNameMatch.Success -or -not $versionMatch.Success) {
  throw 'The manifest must contain parseable appname and version fields.'
}
$appName = $appNameMatch.Groups[1].Value
$version = $versionMatch.Groups[1].Value

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null

function Invoke-ExternalChecked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$FailureMessage
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FailureMessage (exit $LASTEXITCODE)"
  }
}

function Invoke-ExternalCapture {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$FailureMessage
  )
  $output = & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FailureMessage (exit $LASTEXITCODE)"
  }
  return (($output | Out-String).Trim())
}

function Resolve-WslDistribution([string]$Requested) {
  $registered = @()
  try {
    $output = & wsl.exe --list --quiet 2>$null
    $listExitCode = $LASTEXITCODE
    if ($listExitCode -eq 0) {
      $registered = @(
        $output |
          ForEach-Object { ($_ -replace "`0", '').Trim().TrimStart('*').Trim() } |
          Where-Object { $_ }
      )
    }
  } catch {
    $registered = @()
  }

  if ($registered -contains $Requested) {
    return $Requested
  }

  if ($Requested -ieq 'Debian') {
    $debianVariants = @($registered | Where-Object { $_ -match '^Debian-\d+(?:\.\d+)?$' })
    if ($debianVariants.Count -eq 1) {
      return $debianVariants[0]
    }
    if ($debianVariants.Count -gt 1) {
      throw "Multiple Debian WSL distributions are registered; pass -WslDistribution explicitly: $($debianVariants -join ', ')"
    }
  }

  if ($registered.Count -gt 0) {
    throw "WSL distribution $Requested is not registered. Available distributions: $($registered -join ', ')"
  }
  return $Requested
}

function Read-ManifestFields([string]$Path) {
  $fields = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
      continue
    }
    $match = [regex]::Match($line, '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$')
    if (-not $match.Success) {
      throw "Manifest contains an invalid line: $Path"
    }
    $key = $match.Groups[1].Value
    if ($fields.ContainsKey($key)) {
      throw "Manifest contains duplicate field ${key}: $Path"
    }
    $fields[$key] = $match.Groups[2].Value
  }
  return $fields
}

function Get-GitBlobSha256 {
  param(
    [string]$Repository,
    [string]$RevisionPath
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'git'
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in @('-C', $Repository, 'cat-file', 'blob', $RevisionPath)) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Unable to start git while hashing $RevisionPath"
  }
  try {
    $hashBytes = [Security.Cryptography.SHA256]::HashData($process.StandardOutput.BaseStream)
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
      throw "Unable to read locked Git blob ${RevisionPath}: $($errorText.Trim())"
    }
    return [Convert]::ToHexString($hashBytes).ToLowerInvariant()
  } finally {
    $process.Dispose()
  }
}

function Invoke-TarChecked {
  param([string[]]$Arguments)
  Invoke-ExternalChecked -FilePath $HostTar -Arguments $Arguments -FailureMessage "tar failed: tar $($Arguments -join ' ')"
}

# Windows-path tar invocations must not resolve to Git's GNU tar, which
# interprets `E:\...` as a remote host specification ("Cannot connect to E").
function Resolve-HostTar {
  $systemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path -LiteralPath $systemTar -PathType Leaf) { return $systemTar }
  return 'tar'
}
$HostTar = Resolve-HostTar

function Get-BuildComponent([string]$Root, [string]$RelativePath) {
  $portablePath = $RelativePath.Replace('\', '/')
  $nativePath = Join-Path $Root $RelativePath
  if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) {
    throw "Build provenance component is missing: $portablePath"
  }
  $file = Get-Item -LiteralPath $nativePath
  return [ordered]@{
    path = $portablePath
    bytes = $file.Length
    sha256 = (Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Write-Utf8Json([string]$Path, [Collections.IDictionary]$Value) {
  $json = ($Value | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

$WslDistribution = Resolve-WslDistribution $WslDistribution

$wslPathCache = @{}
function Convert-ToWslPath([string]$Path) {
  $resolvedPath = [IO.Path]::GetFullPath($Path)
  if ($wslPathCache.ContainsKey($resolvedPath)) {
    return $wslPathCache[$resolvedPath]
  }
  $portablePath = $Path.Replace('\', '/')
  $converted = Invoke-ExternalCapture -FilePath 'wsl' -Arguments @(
    '-d', $WslDistribution, '--', 'wslpath', '-a', '-u', $portablePath
  ) -FailureMessage "Unable to convert path for WSL: $Path"
  if (-not $converted.StartsWith('/')) {
    throw "WSL returned an invalid path for ${Path}: $converted"
  }
  $wslPathCache[$resolvedPath] = $converted
  return $converted
}

function Test-ElfMachine {
  param(
    [string]$Path,
    [int]$ExpectedMachine
  )
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 20 -or $bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4c -or $bytes[3] -ne 0x46) {
    throw "Expected an ELF file: $Path"
  }
  if ($bytes[4] -ne 2 -or $bytes[5] -ne 1) {
    throw "Expected a 64-bit little-endian ELF file: $Path"
  }
  $machine = [BitConverter]::ToUInt16($bytes, 18)
  if ($machine -ne $ExpectedMachine) {
    throw "Unexpected ELF machine $machine in $Path; expected $ExpectedMachine"
  }
}

function Remove-SafeTree {
  param(
    [string]$Path,
    [string]$AllowedRoot
  )
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolvedRoot = (Resolve-Path -LiteralPath $AllowedRoot).Path.TrimEnd('\')
  $resolvedTarget = (Resolve-Path -LiteralPath $Path).Path
  if (-not $resolvedTarget.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe recursive removal target: $resolvedTarget"
  }
  Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

function Remove-SafeStaging([string]$Path) {
  Remove-SafeTree -Path $Path -AllowedRoot $temporaryRoot
}

$sourceResolverParameters = @{
  RepositoryRoot = $repositoryRoot
  ExpectedRepository = $runtimeLock['upstream_repository']
  ExpectedCommit = $runtimeLock['upstream_commit']
  ExpectedTree = $runtimeLock['upstream_tree']
}
if ($SourceTree) { $sourceResolverParameters.SourceTree = $SourceTree }
if ($AllowDownload) { $sourceResolverParameters.AllowDownload = $true }
$sourceResolution = & $sourceResolverScript @sourceResolverParameters
$resolvedSource = $sourceResolution.Path
$sourceCommit = $sourceResolution.Commit
$sourceTreeHash = $sourceResolution.Tree
$sourceRemote = $sourceResolution.Repository

$sourcePnpmLockHash = Get-GitBlobSha256 -Repository $resolvedSource -RevisionPath 'HEAD:pnpm-lock.yaml'
$sourceCliPackageHash = Get-GitBlobSha256 -Repository $resolvedSource -RevisionPath 'HEAD:apps/cli/package.json'
if ($sourcePnpmLockHash -cne $runtimeLock['pnpm_lock_sha256']) {
  throw "Official pnpm-lock.yaml hash mismatch: $sourcePnpmLockHash"
}
if ($sourceCliPackageHash -cne $runtimeLock['cli_package_sha256']) {
  throw "Official apps/cli/package.json hash mismatch: $sourceCliPackageHash"
}
$sourceCliPackage = Invoke-ExternalCapture -FilePath 'git' -Arguments @(
  '-C', $resolvedSource, 'show', 'HEAD:apps/cli/package.json'
) -FailureMessage 'Unable to read the locked CLI manifest' | ConvertFrom-Json -AsHashtable
$sourceRootPackage = Invoke-ExternalCapture -FilePath 'git' -Arguments @(
  '-C', $resolvedSource, 'show', 'HEAD:package.json'
) -FailureMessage 'Unable to read the locked root manifest' | ConvertFrom-Json -AsHashtable
if ($sourceCliPackage['name'] -ne '@deepseek-ai/dsh' -or $sourceCliPackage['version'] -ne $runtimeLock['dsh_version']) {
  throw "Unexpected official DSH identity: $($sourceCliPackage['name'])@$($sourceCliPackage['version'])"
}
if ($sourceRootPackage['packageManager'] -ne "pnpm@$($pnpmLock['version'])") {
  throw "Official source requires $($sourceRootPackage['packageManager']), but the runtime lock selects pnpm@$($pnpmLock['version'])"
}
if ($sourceRootPackage['engines']['node'] -ne $runtimeLock['node_engines']) {
  throw "Official Node engine mismatch: $($sourceRootPackage['engines']['node'])"
}

$expectedSourcePatches = @(
  @{
    path = 'patches/0002-dsh-plugin-profile-scoped-management.patch'
    artifact_path = 'source-patches/0002-dsh-plugin-profile-scoped-management.patch'
    test_target = 'packages/boot/plugin-manager/tests/operations.spec.ts'
  },
  @{
    path = 'patches/0004-web-app-private-auth-token-handoff.patch'
    artifact_path = 'source-patches/0004-web-app-private-auth-token-handoff.patch'
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
  },
  @{
    path = 'patches/0009-dsh-file-upload-agent-resolver-release.patch'
    artifact_path = 'source-patches/0009-dsh-file-upload-agent-resolver-release.patch'
    sha256 = '3742e064bde2a94e9afca411e96b44f540a6232d3bb3b4872528013baa2f04f0'
    test_target = 'packages/client/file-upload/tests/file-upload-resolver-release.host.spec.ts'
  }
)
$sourcePatches = @(
  for ($index = 0; $index -lt $expectedSourcePatches.Count; $index++) {
    $lock = $sourcePatchLocks[$index]
    $expected = $expectedSourcePatches[$index]
    if ($lock['path'] -cne $expected.path -or
        $lock['artifact_path'] -cne $expected.artifact_path -or
        $lock['sha256'] -notmatch '^[0-9a-f]{64}$' -or
        $lock['test_target'] -cne $expected.test_target) {
      throw "runtime.lock.json contains an invalid or out-of-order source patch lock at index $index."
    }
    $path = Join-Path $projectPath $lock['path']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Locked source patch is unavailable: $path"
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $lock['sha256']) {
      throw "Source patch SHA-256 mismatch. Expected $($lock['sha256']), got $hash"
    }
    [pscustomobject]@{ Lock = $lock; Path = $path; Hash = $hash }
  }
)

$sourceServerMarkerPath = Join-Path $projectPath 'app\server\package.json'
$sourceServerMarker = Get-Content -LiteralPath $sourceServerMarkerPath -Raw | ConvertFrom-Json -AsHashtable
if ($sourceServerMarker['name'] -ne 'deepseek-harness-fnos-runtime-marker' -or
    $sourceServerMarker['dependencies']['@deepseek-ai/dsh'] -ne $runtimeLock['dsh_version']) {
  throw 'app/server/package.json must remain a source-only marker for the locked DSH runtime.'
}
$sourceServerMarkerComponent = Get-BuildComponent -Root $projectPath -RelativePath 'app\server\package.json'

$cacheDirectory = Join-Path $temporaryRoot 'deepseek-harness-runtime-cache'
$cachedPnpm = Join-Path $cacheDirectory $pnpmLock['asset_name']
if ($PnpmTarball) {
  $resolvedPnpm = (Resolve-Path -LiteralPath $PnpmTarball).Path
} elseif (Test-Path -LiteralPath $cachedPnpm -PathType Leaf) {
  $resolvedPnpm = (Resolve-Path -LiteralPath $cachedPnpm).Path
} elseif ($AllowDownload) {
  New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
  Invoke-WebRequest -Uri $pnpmLock['asset_url'] -OutFile $cachedPnpm -Headers @{
    'User-Agent' = 'fn-pack-deepseek-harness-builder'
  }
  $resolvedPnpm = (Resolve-Path -LiteralPath $cachedPnpm).Path
} else {
  throw "The locked pnpm tarball is unavailable. Pass -PnpmTarball or explicitly use -AllowDownload. Expected cache: $cachedPnpm"
}

$pnpmHash = (Get-FileHash -LiteralPath $resolvedPnpm -Algorithm SHA256).Hash.ToLowerInvariant()
if ($pnpmHash -cne $pnpmLock['asset_sha256']) {
  throw "pnpm tarball SHA-256 mismatch. Expected $($pnpmLock['asset_sha256']), got $pnpmHash"
}
$pnpmSha512 = (Get-FileHash -LiteralPath $resolvedPnpm -Algorithm SHA512).Hash
$pnpmIntegrity = 'sha512-' + [Convert]::ToBase64String([Convert]::FromHexString($pnpmSha512))
if ($pnpmIntegrity -cne $pnpmLock['integrity']) {
  throw "pnpm tarball integrity mismatch. Expected $($pnpmLock['integrity']), got $pnpmIntegrity"
}

$cachedLandlock = Join-Path $cacheDirectory $landlockLock['asset_name']
if ($LandlockTarball) {
  $resolvedLandlock = (Resolve-Path -LiteralPath $LandlockTarball).Path
} elseif (Test-Path -LiteralPath $cachedLandlock -PathType Leaf) {
  $resolvedLandlock = (Resolve-Path -LiteralPath $cachedLandlock).Path
} elseif ($AllowDownload) {
  New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
  Invoke-WebRequest -Uri $landlockLock['asset_url'] -OutFile $cachedLandlock -Headers @{
    'User-Agent' = 'fn-pack-deepseek-harness-builder'
  }
  $resolvedLandlock = (Resolve-Path -LiteralPath $cachedLandlock).Path
} else {
  throw "The locked landlock-run tarball is unavailable. Pass -LandlockTarball or explicitly use -AllowDownload. Expected cache: $cachedLandlock"
}

$landlockHash = (Get-FileHash -LiteralPath $resolvedLandlock -Algorithm SHA256).Hash.ToLowerInvariant()
if ($landlockHash -cne $landlockLock['asset_sha256']) {
  throw "landlock-run tarball SHA-256 mismatch. Expected $($landlockLock['asset_sha256']), got $landlockHash"
}
$landlockSha512 = (Get-FileHash -LiteralPath $resolvedLandlock -Algorithm SHA512).Hash
$landlockIntegrity = 'sha512-' + [Convert]::ToBase64String([Convert]::FromHexString($landlockSha512))
if ($landlockIntegrity -cne $landlockLock['integrity']) {
  throw "landlock-run tarball integrity mismatch. Expected $($landlockLock['integrity']), got $landlockIntegrity"
}

$platform = $runtimeLock['platform']
if ($platform -cne 'x86') {
  throw "Unsupported locked package platform: $platform"
}
$targetPath = Join-Path $buildDirectory "${appName}_${version}_${platform}.fpk"
if (Test-Path -LiteralPath $targetPath) {
  throw "Refusing to overwrite existing artifact: $targetPath"
}

$stagingPath = Join-Path $temporaryRoot ("deepseek-harness-build-" + [guid]::NewGuid().ToString('N'))
$packageStage = Join-Path $stagingPath 'package'
$pnpmStage = Join-Path $stagingPath 'pnpm'
$landlockStage = Join-Path $stagingPath 'landlock'
$verifyStage = Join-Path $stagingPath 'verify'
$verifyAppStage = Join-Path $stagingPath 'verify-app'
$artifactStage = Join-Path $stagingPath 'artifact'
$sourceArchive = Join-Path $stagingPath 'deepseek-harness-source.tar'
$sourceRuntimeArchive = Join-Path $stagingPath 'deepseek-harness-runtime.tgz'
$artifactCreated = $false
$artifactValidated = $false

try {
  New-Item -ItemType Directory -Path $packageStage, $pnpmStage, $landlockStage, $verifyStage, $verifyAppStage, $artifactStage | Out-Null

  foreach ($directory in @('app', 'cmd', 'config', 'wizard')) {
    Copy-Item -LiteralPath (Join-Path $projectPath $directory) -Destination $packageStage -Recurse
  }
  foreach ($file in @('manifest', 'ICON.PNG', 'ICON_256.PNG')) {
    Copy-Item -LiteralPath (Join-Path $projectPath $file) -Destination $packageStage
  }
  Copy-Item -LiteralPath (Join-Path $projectPath 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $packageStage 'app\THIRD_PARTY_NOTICES.md')
  Copy-Item -LiteralPath $runtimeLockPath -Destination (Join-Path $packageStage 'app\runtime.lock.json')
  foreach ($sourcePatch in $sourcePatches) {
    $stagedSourcePatch = Join-Path $packageStage ("app\" + $sourcePatch.Lock['artifact_path'].Replace('/', '\'))
    New-Item -ItemType Directory -Path (Split-Path -Parent $stagedSourcePatch) -Force | Out-Null
    Copy-Item -LiteralPath $sourcePatch.Path -Destination $stagedSourcePatch
  }

  Invoke-ExternalChecked -FilePath 'git' -Arguments @(
    '-C', $resolvedSource, 'archive', '--format=tar', "--output=$sourceArchive", $sourceCommit
  ) -FailureMessage 'Unable to archive the locked official source commit'

  $landlockArchiveEntries = @(& $HostTar -tvzf $resolvedLandlock)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to list the locked landlock-run tarball.' }
  $landlockArchiveBinary = "package/$($landlockLock['binary_path'])"
  $landlockModeLines = @($landlockArchiveEntries | Where-Object { $_.TrimEnd().EndsWith($landlockArchiveBinary) })
  if ($landlockModeLines.Count -ne 1 -or $landlockModeLines[0] -notmatch '^-..x') {
    throw "The locked landlock-run tarball does not contain one executable $landlockArchiveBinary entry."
  }
  Invoke-TarChecked @('-xzf', $resolvedLandlock, '-C', $landlockStage)
  $landlockPackageRoot = Join-Path $landlockStage 'package'
  $landlockPackagePath = Join-Path $landlockPackageRoot 'package.json'
  $landlockPrebuildsPath = Join-Path $landlockPackageRoot 'prebuilds.json'
  $officialLandlockPath = Join-Path $landlockPackageRoot $landlockLock['binary_path']
  $landlockPackage = Get-Content -LiteralPath $landlockPackagePath -Raw | ConvertFrom-Json -AsHashtable
  $landlockPrebuilds = Get-Content -LiteralPath $landlockPrebuildsPath -Raw | ConvertFrom-Json -AsHashtable
  if ($landlockPackage['name'] -ne $landlockLock['package_name'] -or
      $landlockPackage['version'] -ne $landlockLock['version'] -or
      'linux' -notin $landlockPackage['os'] -or
      'x64' -notin $landlockPackage['cpu']) {
    throw "Unexpected landlock-run package identity $($landlockPackage['name'])@$($landlockPackage['version'])"
  }
  $declaredLandlockBinary = @($landlockPrebuilds['binaries'] | Where-Object {
    $_['tool'] -eq 'landlock-run' -and $_['kind'] -eq 'static-musl' -and $_['path'] -eq $landlockLock['binary_path']
  })
  if ($landlockPrebuilds['platform'] -ne 'linux-x64' -or $declaredLandlockBinary.Count -ne 1) {
    throw 'The official landlock-run prebuild declaration does not match linux-x64 static-musl.'
  }
  $sourceLandlockRoot = Join-Path $resolvedSource 'native\system\packages\linux-x64'
  $sourceSystemPackage = Get-Content -LiteralPath (Join-Path $sourceLandlockRoot 'package.json') -Raw | ConvertFrom-Json -AsHashtable
  $assetSystemPackage = Get-Content -LiteralPath (Join-Path $landlockPackageRoot 'package.json') -Raw | ConvertFrom-Json -AsHashtable
  $allowedRepositoryUrls = @(
    'git+https://github.com/deepseek-ai/deepseek-harness.git',
    'git+https://github.com/deepseek-harness/deepseek-harness.git'
  )
  if ($sourceSystemPackage['repository']['url'] -notin $allowedRepositoryUrls -or
      $assetSystemPackage['repository']['url'] -notin $allowedRepositoryUrls) {
    throw 'Unexpected repository URL in official system package metadata.'
  }
  $sourceSystemPackage['repository']['url'] = 'OFFICIAL_REPOSITORY'
  $assetSystemPackage['repository']['url'] = 'OFFICIAL_REPOSITORY'
  if (($sourceSystemPackage | ConvertTo-Json -Depth 8 -Compress) -cne
      ($assetSystemPackage | ConvertTo-Json -Depth 8 -Compress)) {
    throw 'Official landlock-run package.json differs beyond the repository organization rename.'
  }
  $sourcePrebuildsHash = (Get-FileHash -LiteralPath (Join-Path $sourceLandlockRoot 'prebuilds.json') -Algorithm SHA256).Hash
  $assetPrebuildsHash = (Get-FileHash -LiteralPath (Join-Path $landlockPackageRoot 'prebuilds.json') -Algorithm SHA256).Hash
  if ($sourcePrebuildsHash -cne $assetPrebuildsHash) {
    throw 'Official landlock-run asset metadata differs from the locked Git source: prebuilds.json'
  }
  Test-ElfMachine -Path $officialLandlockPath -ExpectedMachine $runtimeLock['elf_machine']
  $officialLandlockHash = (Get-FileHash -LiteralPath $officialLandlockPath -Algorithm SHA256).Hash.ToLowerInvariant()

  $wslArchitecture = Invoke-ExternalCapture -FilePath 'wsl' -Arguments @(
    '-d', $WslDistribution, '--', 'uname', '-m'
  ) -FailureMessage "Unable to start WSL distribution $WslDistribution"
  if ($wslArchitecture -ne 'x86_64') {
    throw "WSL distribution $WslDistribution is not x86-64: $wslArchitecture"
  }

  $wslBuildScript = Convert-ToWslPath $linuxBuildScript
  $wslSourceArchive = Convert-ToWslPath $sourceArchive
  $wslPnpmArchive = Convert-ToWslPath $resolvedPnpm
  $wslLandlockArchive = Convert-ToWslPath $resolvedLandlock
  $wslRuntimeArchive = Convert-ToWslPath $sourceRuntimeArchive
  $wslBuildArguments = @(
    '-d', $WslDistribution, '--'
  )
  if ($PnpmStoreDir) {
    $wslBuildArguments += @('env', "DSH_PNPM_STORE_DIR=$PnpmStoreDir")
  }
  $wslBuildArguments += @(
    'bash', $wslBuildScript,
    $wslSourceArchive, $wslPnpmArchive, $wslLandlockArchive,
    $wslRuntimeArchive, $sourceCommit, $runtimeLock['dsh_version']
  )
  foreach ($sourcePatch in $sourcePatches) {
    $wslBuildArguments += @(
      (Convert-ToWslPath $sourcePatch.Path),
      $sourcePatch.Hash,
      $sourcePatch.Lock['test_target']
    )
  }
  Invoke-ExternalChecked -FilePath 'wsl' -Arguments $wslBuildArguments `
    -FailureMessage 'Official DeepSeek Harness source build failed in WSL'

  $stagedServer = Join-Path $packageStage 'app\server'
  Remove-SafeTree -Path $stagedServer -AllowedRoot $packageStage
  New-Item -ItemType Directory -Path $stagedServer | Out-Null
  Invoke-TarChecked @('-xzf', $sourceRuntimeArchive, '-C', $stagedServer)

  $dshPackagePath = Join-Path $stagedServer 'node_modules\@deepseek-ai\dsh\package.json'
  $dshPackage = Get-Content -LiteralPath $dshPackagePath -Raw | ConvertFrom-Json -AsHashtable
  if ($dshPackage['version'] -ne $runtimeLock['dsh_version']) {
    throw "Built DSH version mismatch: $($dshPackage['version'])"
  }
  $runtimeManifest = Get-Content -LiteralPath (Join-Path $stagedServer 'package.json') -Raw | ConvertFrom-Json -AsHashtable
  if ($runtimeManifest['name'] -ne 'dsh-fnos-runtime' -or
      -not $runtimeManifest['dependencies'].Contains('@deepseek-ai/dsh') -or
      $runtimeManifest['dependencies'].Count -lt 2) {
    throw 'The generated source runtime manifest is invalid.'
  }
  $stagedRuntimeManifestPath = Join-Path $stagedServer 'package.json'
  $stagedRuntimeManifestHash = (Get-FileHash -LiteralPath $stagedRuntimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($stagedRuntimeManifestHash -ceq $sourceServerMarkerComponent['sha256'] -or
      (Get-Item -LiteralPath $stagedRuntimeManifestPath).Length -le $sourceServerMarkerComponent['bytes']) {
    throw 'The generated source runtime was not allowed to retain the source-only server marker.'
  }
  $summaryClientCompatPath = Join-Path $packageStage 'app\summary-client-compat.js'
  $summaryClientBundlePath = Join-Path $stagedServer 'node_modules\@deepseek-ai\dsh-client-ui-deliverables\lib\client.js'
  if (-not (Test-Path -LiteralPath $summaryClientCompatPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $summaryClientBundlePath -PathType Leaf)) {
    throw 'The generated source runtime is missing the reviewed summary client compatibility inputs.'
  }
  & $node.Source $summaryClientCheckerPath $summaryClientCompatPath $summaryClientBundlePath
  if ($LASTEXITCODE -ne 0) {
    throw 'The generated ui-deliverables client bundle is not the reviewed summary compatibility shape.'
  }
  $yamlPackagePath = Join-Path $stagedServer 'node_modules\yaml\package.json'
  $yamlPackage = Get-Content -LiteralPath $yamlPackagePath -Raw | ConvertFrom-Json -AsHashtable
  if ($yamlPackage['name'] -ne 'yaml') {
    throw 'The generated source runtime is missing the YAML document parser required by DSH.'
  }

  $nodePtyPath = Join-Path $stagedServer 'node_modules\node-pty\prebuilds\linux-x64\pty.node'
  $sharpPackageLib = Join-Path $stagedServer 'node_modules\@img\sharp-linux-x64\lib'
  $sharpNodes = @(Get-ChildItem -LiteralPath $sharpPackageLib -File -Filter '*.node')
  if ($sharpNodes.Count -ne 1) {
    throw "Expected exactly one sharp linux-x64 native addon in ${sharpPackageLib}, got $($sharpNodes.Count)"
  }
  $sharpPath = $sharpNodes[0].FullName
  $nativePackageDir = $landlockLock['package_name'].Replace('/', '\')
  $stagedLandlockPath = Join-Path $stagedServer ("node_modules\" + $nativePackageDir + "\" + $landlockLock['binary_path'].Replace('/', '\'))
  $stagedFlockPath = Join-Path $stagedServer "node_modules\$nativePackageDir\bin\glibc\system.node"
  Test-ElfMachine -Path $nodePtyPath -ExpectedMachine $runtimeLock['elf_machine']
  Test-ElfMachine -Path $sharpPath -ExpectedMachine $runtimeLock['elf_machine']
  Test-ElfMachine -Path $stagedLandlockPath -ExpectedMachine $runtimeLock['elf_machine']
  Test-ElfMachine -Path $stagedFlockPath -ExpectedMachine $runtimeLock['elf_machine']
  $stagedLandlockHash = (Get-FileHash -LiteralPath $stagedLandlockPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($stagedLandlockHash -cne $officialLandlockHash) {
    throw 'The staged landlock-run binary differs from the locked official binary.'
  }
  $officialFlockPath = Join-Path $landlockPackageRoot 'bin\glibc\system.node'
  $stagedFlockHash = (Get-FileHash -LiteralPath $stagedFlockPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $officialFlockHash = (Get-FileHash -LiteralPath $officialFlockPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($stagedFlockHash -cne $officialFlockHash) {
    throw 'The staged flock addon differs from the locked official binary.'
  }
  $unexpectedRuntimeTargets = @(
    Get-ChildItem -LiteralPath $stagedServer -Recurse -File |
      Where-Object { $_.Extension -in @('.exe', '.cmd', '.dll', '.pdb') }
  )
  if ($unexpectedRuntimeTargets.Count -ne 0) {
    throw "Target-incompatible runtime files remain: $($unexpectedRuntimeTargets.Count)"
  }
  $nodePtyPrebuildRoot = Join-Path $stagedServer 'node_modules\node-pty\prebuilds'
  $unexpectedNodePtyPlatforms = @(
    Get-ChildItem -LiteralPath $nodePtyPrebuildRoot -Directory |
      Where-Object { $_.Name -cne 'linux-x64' }
  )
  if ($unexpectedNodePtyPlatforms.Count -ne 0) {
    throw "Unsupported node-pty prebuild platforms remain: $($unexpectedNodePtyPlatforms.Name -join ', ')"
  }

  Invoke-TarChecked @('-xzf', $resolvedPnpm, '-C', $pnpmStage)
  $pnpmPackageRoot = Join-Path $pnpmStage 'package'
  $pnpmPackagePath = Join-Path $pnpmPackageRoot 'package.json'
  $pnpmPackage = Get-Content -LiteralPath $pnpmPackagePath -Raw | ConvertFrom-Json -AsHashtable
  if ($pnpmPackage['name'] -ne 'pnpm' -or $pnpmPackage['version'] -ne $pnpmLock['version']) {
    throw "Unexpected pnpm package identity $($pnpmPackage['name'])@$($pnpmPackage['version'])"
  }
  foreach ($pattern in @('*.exe', '*.cmd', '*.dll', '*.pdb')) {
    foreach ($file in @(Get-ChildItem -LiteralPath $pnpmPackageRoot -Recurse -File -Filter $pattern)) {
      Remove-Item -LiteralPath $file.FullName -Force
    }
  }
  foreach ($pattern in @('reflink.darwin-*.node', 'reflink.win32-*.node')) {
    foreach ($file in @(Get-ChildItem -LiteralPath $pnpmPackageRoot -Recurse -File -Filter $pattern)) {
      Remove-Item -LiteralPath $file.FullName -Force
    }
  }
  foreach ($requiredPnpmFile in @('LICENSE', 'bin\pnpm.cjs', 'bin\pnpm.mjs', 'dist\pnpm.mjs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $pnpmPackageRoot $requiredPnpmFile) -PathType Leaf)) {
      throw "pnpm package is missing required file: $requiredPnpmFile"
    }
  }
  Copy-Item -LiteralPath $pnpmPackageRoot -Destination (Join-Path $packageStage 'app\pnpm') -Recurse

  $buildComponentPaths = @(
    'backend-ready.js',
    'builtin-skills/dsh-maintenance/SKILL.md',
    'builtin-skills/init/SKILL.md',
    'builtin-skills/init/agents/openai.yaml',
    'builtin-skills/skill-creator/SKILL.md',
    'builtin-skills/skill-creator/references/openai_yaml.md',
    'builtin-skills/skill-creator/references/powershell-authoring.md',
    'builtin-skills/skill-creator/scripts/generate_openai_yaml.sh',
    'builtin-skills/skill-creator/scripts/init_skill.sh',
    'builtin-skills/skill-creator/scripts/quick_validate.sh',
    'dsh-launcher',
    'gateway-compat.js',
    'gateway-proxy.js',
    'gateway-websocket.js',
    'summary-client-compat.js',
    'pnpm-launcher',
    'runtime.lock.json',
    'select-loopback-port.js',
    'pnpm/package.json',
    'server/package.json',
    'server/node_modules/@deepseek-ai/dsh/package.json',
    'server/node_modules/@deepseek-ai/dsh/lib/bin.js'
  )
  $stagedAppRoot = Join-Path $packageStage 'app'
  $buildInfo = [ordered]@{
    schema = 1
    app = [ordered]@{
      name = $appName
      version = $version
    }
    upstream = [ordered]@{
      package = '@deepseek-ai/dsh'
      version = $runtimeLock['dsh_version']
      repository = $runtimeLock['upstream_repository']
      commit = $sourceCommit
      tree = $sourceTreeHash
    }
    build_input = [ordered]@{
      server_marker = $sourceServerMarkerComponent
    }
    components = @(
      foreach ($componentPath in $buildComponentPaths) {
        Get-BuildComponent -Root $stagedAppRoot -RelativePath $componentPath
      }
    )
  }
  $stagedBuildInfoPath = Join-Path $stagedAppRoot 'build-info.json'
  Write-Utf8Json -Path $stagedBuildInfoPath -Value $buildInfo
  $stagedBuildInfoHash = (Get-FileHash -LiteralPath $stagedBuildInfoPath -Algorithm SHA256).Hash.ToLowerInvariant()

  # The staging tree copies the whole runtime, so it can need more room than a
  # small tmpfs provides. The option keeps that copy off the system temporary
  # directory without touching the temporary directory of the build itself.
  $wslPackageEnvironment = @()
  if (-not [string]::IsNullOrWhiteSpace($PackageTempDir)) {
    $packageTempRoot = if ([IO.Path]::IsPathRooted($PackageTempDir)) {
      $PackageTempDir
    } else {
      Join-Path $repositoryRoot $PackageTempDir
    }
    New-Item -ItemType Directory -Path $packageTempRoot -Force | Out-Null
    $wslPackageEnvironment = @('env', "TMPDIR=$(Convert-ToWslPath $packageTempRoot)")
  }

  $wslPackageArguments = @(
    '-d', $WslDistribution, '--'
  ) + $wslPackageEnvironment + @(
    'sh',
    (Convert-ToWslPath $linuxPackageScript),
    (Convert-ToWslPath $packageStage),
    (Convert-ToWslPath $sourceRuntimeArchive),
    (Convert-ToWslPath $fnpackPath),
    (Convert-ToWslPath $artifactStage)
  )
  Invoke-ExternalChecked -FilePath 'wsl' -Arguments $wslPackageArguments `
    -FailureMessage 'Linux fnpack failed in WSL'

  $generatedArtifacts = @(Get-ChildItem -LiteralPath $artifactStage -File -Filter '*.fpk')
  if ($generatedArtifacts.Count -ne 1 -or $generatedArtifacts[0].Name -cne "$appName.fpk") {
    $generatedNames = ($generatedArtifacts | ForEach-Object Name) -join ', '
    throw "fnpack must produce exactly $appName.fpk in the isolated output directory; got: $generatedNames"
  }
  $candidatePath = $generatedArtifacts[0].FullName

  $outerEntries = @(& $HostTar -tf $candidatePath)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to list the final FPK.' }
  foreach ($requiredOuterEntry in @('app.tgz', 'cmd', 'config', 'manifest', 'ICON.PNG', 'ICON_256.PNG')) {
    if ($requiredOuterEntry -notin $outerEntries) {
      throw "Final FPK is missing required outer entry: $requiredOuterEntry"
    }
  }
  if ('LICENSE' -in $outerEntries -or './LICENSE' -in $outerEntries) {
    throw 'The final FPK unexpectedly contains an application-root LICENSE.'
  }
  Invoke-TarChecked @('-xf', $candidatePath, '-C', $verifyStage)
  $finalManifestPath = Join-Path $verifyStage 'manifest'
  if (-not (Test-Path -LiteralPath $finalManifestPath -PathType Leaf)) {
    throw 'The final FPK does not contain a readable manifest.'
  }
  $stagedManifestFields = Read-ManifestFields (Join-Path $packageStage 'manifest')
  $finalManifestFields = Read-ManifestFields $finalManifestPath
  foreach ($manifestField in $stagedManifestFields.Keys) {
    if (-not $finalManifestFields.ContainsKey($manifestField)) {
      throw "Final FPK manifest is missing source field: $manifestField"
    }
    if ($finalManifestFields[$manifestField] -cne $stagedManifestFields[$manifestField]) {
      throw "Final FPK manifest changed source field: $manifestField"
    }
  }
  $generatedManifestFields = @(
    $finalManifestFields.Keys | Where-Object { $_ -notin $stagedManifestFields.Keys }
  )
  if ($generatedManifestFields.Count -ne 1 -or $generatedManifestFields[0] -cne 'checksum' -or
      $finalManifestFields['checksum'] -notmatch '^[0-9a-f]{32}$') {
    throw "Final FPK manifest contains unexpected generated fields: $($generatedManifestFields -join ', ')"
  }
  $finalAppTgz = Join-Path $verifyStage 'app.tgz'
  if (-not (Test-Path -LiteralPath $finalAppTgz -PathType Leaf)) {
    throw 'The final FPK does not contain app.tgz.'
  }
  $nestedEntries = @(& $HostTar -tzf $finalAppTgz)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to list the final nested app.tgz.' }
  $nestedModeEntries = @(& $HostTar -tvzf $finalAppTgz)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect final app.tgz entry modes.' }
  $nestedFileEntries = @(
    $nestedModeEntries |
      Where-Object { $_ -match '^-' } |
      ForEach-Object { ($_ -split '\s+', 6)[5] }
  )
  if ('LICENSE' -in $nestedEntries -or './LICENSE' -in $nestedEntries) {
    throw 'The final app.tgz unexpectedly contains an application-root LICENSE.'
  }
  $requiredEntries = @(
    'backend-ready.js',
    'build-info.json',
    'builtin-skills/dsh-maintenance/SKILL.md',
    'builtin-skills/init/SKILL.md',
    'builtin-skills/init/agents/openai.yaml',
    'builtin-skills/skill-creator/SKILL.md',
    'builtin-skills/skill-creator/references/openai_yaml.md',
    'builtin-skills/skill-creator/references/powershell-authoring.md',
    'builtin-skills/skill-creator/scripts/generate_openai_yaml.sh',
    'builtin-skills/skill-creator/scripts/init_skill.sh',
    'builtin-skills/skill-creator/scripts/quick_validate.sh',
    'gateway-proxy.js',
    'gateway-compat.js',
    'gateway-websocket.js',
    'summary-client-compat.js',
    'dsh-launcher',
    'pnpm-launcher',
    'pnpm/bin/pnpm.cjs',
    'pnpm/bin/pnpm.mjs',
    'pnpm/dist/pnpm.mjs',
    'runtime.lock.json',
    'select-loopback-port.js',
    'server/node_modules/@deepseek-ai/dsh/lib/bin.js',
    'server/node_modules/@deepseek-ai/cordis-plugin-group/lib/index.js',
    'server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run',
    'server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/glibc/system.node',
    'server/node_modules/node-pty/prebuilds/linux-x64/pty.node',
    'server/node_modules/yaml/dist/doc/directives.js',
    'ui/config',
    'ui/images/icon_64.png',
    'THIRD_PARTY_NOTICES.md'
  ) + @($sourcePatches | ForEach-Object { $_.Lock['artifact_path'] })
  foreach ($requiredEntry in $requiredEntries) {
    if ($requiredEntry -notin $nestedEntries) {
      throw "Final app.tgz is missing required entry: $requiredEntry"
    }
  }
  $incompatibleEntries = @($nestedFileEntries | Where-Object { $_ -match '(?i)\.(exe|cmd|dll|pdb)$' })
  if ($incompatibleEntries.Count -ne 0) {
    throw "Final app.tgz contains target-incompatible files: $($incompatibleEntries.Count)"
  }
  $unsupportedNodePtyEntries = @(
    $nestedFileEntries |
      Where-Object { $_ -match '^server/node_modules/node-pty/prebuilds/(?!linux-x64/)' }
  )
  if ($unsupportedNodePtyEntries.Count -ne 0) {
    throw "Final app.tgz contains unsupported node-pty prebuilds: $($unsupportedNodePtyEntries.Count)"
  }
  $unnecessaryRuntimeEntries = @($nestedFileEntries | Where-Object {
    $_ -match '(?i)(?:^|/)server/node_modules/' -and (
      $_ -match '(?i)\.(?:map|cts|mts|ts)$' -or
      ($_ -match '(?i)(?:^|/)(?:\.circleci|\.github|\.nyc_output|\.yarn|__tests__|benchmarks?|coverage|docs?|examples?|tests?)(?:/|$)' -and
       $_ -notmatch '(?i)^server/node_modules/yaml/(?:browser/)?dist/doc(?:/|$)') -or
      $_ -match '(?i)(?:^|/)(?:authors|changelog|changes|code_of_conduct|contributing|history|readme|security)(?:\.(?:markdown|md|rst|txt))?$' -or
      $_ -match '(?i)\.(?:asm|c|cc|cpp|gyp|gypi|h|hh|hpp|mk|s)$'
    )
  })
  if ($unnecessaryRuntimeEntries.Count -ne 0) {
    $sampleUnnecessaryEntries = ($unnecessaryRuntimeEntries | Select-Object -First 20) -join ', '
    throw "Final app.tgz contains prunable production runtime entries: $($unnecessaryRuntimeEntries.Count): $sampleUnnecessaryEntries"
  }
  $finalLandlockEntry = 'server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run'
  $finalLandlockModeLines = @($nestedModeEntries | Where-Object { $_.TrimEnd().EndsWith($finalLandlockEntry) })
  if ($finalLandlockModeLines.Count -ne 1) {
    throw 'The final app.tgz does not contain one inspectable landlock-run entry.'
  }
  $landlockArchiveExecutable = $finalLandlockModeLines[0] -match '^-..x'
  $installCallbackText = Get-Content -LiteralPath (Join-Path $packageStage 'cmd\install_callback') -Raw
  $upgradeCallbackText = Get-Content -LiteralPath (Join-Path $packageStage 'cmd\upgrade_callback') -Raw
  if (-not $landlockArchiveExecutable -and
      ($installCallbackText -notmatch 'prepare_landlock_launcher' -or
       $upgradeCallbackText -notmatch 'prepare_landlock_launcher')) {
    throw 'The final app.tgz strips the landlock-run mode but lifecycle permission repair is missing.'
  }
  Invoke-TarChecked @('-xzf', $finalAppTgz, '-C', $verifyAppStage)
  $finalBuildInfoPath = Join-Path $verifyAppStage 'build-info.json'
  $finalBuildInfoHash = (Get-FileHash -LiteralPath $finalBuildInfoPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($finalBuildInfoHash -cne $stagedBuildInfoHash) {
    throw 'The final app.tgz build-info.json differs from the staged build provenance.'
  }
  $finalBuildInfo = Get-Content -LiteralPath $finalBuildInfoPath -Raw | ConvertFrom-Json -AsHashtable
  if ($finalBuildInfo['schema'] -ne 1 -or
      $finalBuildInfo['app']['name'] -cne $appName -or
      $finalBuildInfo['app']['version'] -cne $version -or
      $finalBuildInfo['upstream']['package'] -cne '@deepseek-ai/dsh' -or
      $finalBuildInfo['upstream']['version'] -cne $runtimeLock['dsh_version'] -or
      $finalBuildInfo['upstream']['repository'] -cne $runtimeLock['upstream_repository'] -or
      $finalBuildInfo['upstream']['commit'] -cne $sourceCommit -or
      $finalBuildInfo['upstream']['tree'] -cne $sourceTreeHash) {
    throw 'The final app.tgz build provenance identity is invalid.'
  }
  $finalServerMarker = $finalBuildInfo['build_input']['server_marker']
  if ($finalServerMarker['path'] -cne 'app/server/package.json' -or
      $finalServerMarker['bytes'] -ne $sourceServerMarkerComponent['bytes'] -or
      $finalServerMarker['sha256'] -cne $sourceServerMarkerComponent['sha256']) {
    throw 'The final app.tgz does not identify the source-only server marker correctly.'
  }
  $finalBuildComponents = @($finalBuildInfo['components'])
  if ($finalBuildComponents.Count -ne $buildComponentPaths.Count) {
    throw 'The final app.tgz build provenance component count is invalid.'
  }
  for ($componentIndex = 0; $componentIndex -lt $buildComponentPaths.Count; $componentIndex++) {
    $expectedComponentPath = $buildComponentPaths[$componentIndex].Replace('\', '/')
    $recordedComponent = $finalBuildComponents[$componentIndex]
    if ($recordedComponent['path'] -cne $expectedComponentPath) {
      throw "The final app.tgz build provenance component order is invalid at index $componentIndex."
    }
    $actualComponent = Get-BuildComponent -Root $verifyAppStage -RelativePath $buildComponentPaths[$componentIndex]
    if ($recordedComponent['bytes'] -ne $actualComponent['bytes'] -or
        $recordedComponent['sha256'] -cne $actualComponent['sha256']) {
      throw "The final app.tgz component differs from build provenance: $expectedComponentPath"
    }
  }
  $finalPayloadFiles = @(Get-ChildItem -LiteralPath $verifyAppStage -Recurse -File -Force)
  $finalPayloadBytes = ($finalPayloadFiles | Measure-Object -Property Length -Sum).Sum
  $finalSourcePatches = @(
    foreach ($sourcePatch in $sourcePatches) {
      $finalSourcePatchPath = Join-Path $verifyAppStage ($sourcePatch.Lock['artifact_path'].Replace('/', '\'))
      $finalSourcePatchHash = (Get-FileHash -LiteralPath $finalSourcePatchPath -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($finalSourcePatchHash -cne $sourcePatch.Hash) {
        throw "The final app.tgz source patch differs from the locked build input: $($sourcePatch.Lock['artifact_path'])"
      }
      [pscustomobject]@{
        Path = $sourcePatch.Lock['artifact_path']
        SHA256 = $finalSourcePatchHash
        TestTarget = $sourcePatch.Lock['test_target']
      }
    }
  )
  $finalLandlockPath = Join-Path $verifyAppStage ($finalLandlockEntry.Replace('/', '\'))
  Test-ElfMachine -Path $finalLandlockPath -ExpectedMachine $runtimeLock['elf_machine']
  $finalLandlockHash = (Get-FileHash -LiteralPath $finalLandlockPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($finalLandlockHash -cne $officialLandlockHash) {
    throw 'The final app.tgz landlock-run binary differs from the locked official binary.'
  }

  $candidateArtifact = Get-Item -LiteralPath $candidatePath
  $artifactHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Move-Item -LiteralPath $candidatePath -Destination $targetPath
  $artifactCreated = $true
  $artifact = Get-Item -LiteralPath $targetPath
  $installedArtifactHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($artifact.Length -ne $candidateArtifact.Length -or $installedArtifactHash -cne $artifactHash) {
    throw 'The versioned FPK changed while it was moved from the isolated staging directory.'
  }
  $artifactValidated = $true
  [pscustomobject]@{
    AppName = $appName
    Version = $version
    Path = $artifact.FullName
    Bytes = $artifact.Length
    SHA256 = $artifactHash
    SourceRepository = $runtimeLock['upstream_repository']
    SourceCommit = $sourceCommit
    SourceTree = $sourceTreeHash
    SourcePatches = $finalSourcePatches
    RuntimeVersion = $dshPackage['version']
    RuntimeWorkspacePackages = $runtimeManifest['dependencies'].Count
    PnpmVersion = $pnpmPackage['version']
    PnpmSHA256 = $pnpmHash
    LandlockVersion = $landlockPackage['version']
    LandlockSHA256 = $landlockHash
    LandlockBinarySHA256 = $finalLandlockHash
    LandlockArchiveMode = if ($landlockArchiveExecutable) { 'executable' } else { 'restored-by-install-and-upgrade' }
    BuildInfoSHA256 = $finalBuildInfoHash
    BuildComponents = $finalBuildComponents.Count
    Platform = $runtimeLock['target']
    NativeMachine = $runtimeLock['elf_machine']
    NestedFiles = $nestedEntries.Count
    NestedRegularFiles = $finalPayloadFiles.Count
    NestedLogicalBytes = $finalPayloadBytes
  }
} catch {
  if ($artifactCreated -and -not $artifactValidated -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    Remove-Item -LiteralPath $targetPath -Force
  }
  throw
} finally {
  Remove-SafeStaging -Path $stagingPath
}
