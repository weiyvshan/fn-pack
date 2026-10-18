[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$RepositoryRoot,
  [string]$SourceTree,
  [switch]$AllowDownload,
  [Parameter(Mandatory)]
  [string]$ExpectedRepository,
  [Parameter(Mandatory)]
  [string]$ExpectedCommit,
  [Parameter(Mandatory)]
  [string]$ExpectedTree,
  [string]$SubmoduleName = 'deepseek-harness',
  [string]$SubmodulePath = 'vendor/upstream/deepseek-harness'
)

$ErrorActionPreference = 'Stop'

function Invoke-GitCapture {
  param(
    [string]$WorkingDirectory,
    [string[]]$Arguments,
    [string]$FailureMessage
  )
  $output = & git -C $WorkingDirectory @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$FailureMessage (exit $LASTEXITCODE): $(($output | Out-String).Trim())"
  }
  return (($output | Out-String).Trim())
}

function Normalize-GitRemote([string]$Url) {
  return ((($Url.Trim().Replace('\', '/') -replace '/+$', '') -replace '\.git$', '').ToLowerInvariant())
}

function Initialize-LockedSubmodule {
  param(
    [string]$RepositoryRoot,
    [string]$SubmoduleRoot,
    [string]$ExpectedRepository,
    [string]$ExpectedCommit,
    [string]$NormalizedSubmodulePath
  )

  if (Test-Path -LiteralPath $SubmoduleRoot) {
    $existingEntries = @(Get-ChildItem -LiteralPath $SubmoduleRoot -Force)
    if ($existingEntries.Count -gt 0) {
      throw "The upstream submodule path exists but is not a Git checkout: $NormalizedSubmodulePath"
    }
  } else {
    $submoduleParent = Split-Path -Parent $SubmoduleRoot
    New-Item -ItemType Directory -Path $submoduleParent -Force | Out-Null
  }

  $cloneOutput = & git -C $RepositoryRoot clone --no-checkout -- $ExpectedRepository $SubmoduleRoot 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to clone the upstream submodule (exit $LASTEXITCODE): $(($cloneOutput | Out-String).Trim())"
  }
  $checkoutOutput = & git -C $SubmoduleRoot checkout --detach $ExpectedCommit 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to checkout the locked upstream submodule commit (exit $LASTEXITCODE): $(($checkoutOutput | Out-String).Trim())"
  }
}

$resolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$normalizedSubmodulePath = $SubmodulePath.Replace('\', '/')
$sourceKind = 'override'

if ($SourceTree) {
  $resolvedSource = (Resolve-Path -LiteralPath $SourceTree).Path
} else {
  $sourceKind = 'submodule'
  $gitmodulesPath = Join-Path $resolvedRepositoryRoot '.gitmodules'
  if (-not (Test-Path -LiteralPath $gitmodulesPath -PathType Leaf)) {
    throw "The upstream submodule declaration is missing: $gitmodulesPath"
  }

  $configuredPath = (& git config -f $gitmodulesPath --get "submodule.$SubmoduleName.path" 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $configuredPath.Replace('\', '/') -cne $normalizedSubmodulePath) {
    throw "The $SubmoduleName submodule path must be $normalizedSubmodulePath."
  }
  $configuredUrl = (& git config -f $gitmodulesPath --get "submodule.$SubmoduleName.url" 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or
      (Normalize-GitRemote $configuredUrl) -cne (Normalize-GitRemote $ExpectedRepository)) {
    throw "The $SubmoduleName submodule URL must be $ExpectedRepository."
  }
  $null = & git config -f $gitmodulesPath --get "submodule.$SubmoduleName.branch" 2>$null
  if ($LASTEXITCODE -eq 0) {
    throw "The $SubmoduleName submodule must pin a commit without a tracking branch."
  }
  if ($LASTEXITCODE -ne 1) {
    throw "Unable to inspect the $SubmoduleName submodule branch declaration."
  }

  $gitlink = Invoke-GitCapture -WorkingDirectory $resolvedRepositoryRoot -Arguments @(
    'ls-files', '--stage', '--', $normalizedSubmodulePath
  ) -FailureMessage 'Unable to read the upstream submodule gitlink'
  $gitlinkMatch = [regex]::Match($gitlink, '^160000\s+([0-9a-f]{40})\s+\d+\s+')
  if (-not $gitlinkMatch.Success) {
    throw "The upstream source path is not a tracked Git submodule: $normalizedSubmodulePath"
  }
  if ($gitlinkMatch.Groups[1].Value -cne $ExpectedCommit) {
    throw "Submodule gitlink mismatch. Expected $ExpectedCommit, got $($gitlinkMatch.Groups[1].Value)"
  }

  $submoduleRoot = Join-Path $resolvedRepositoryRoot $SubmodulePath
  $gitMarker = Join-Path $submoduleRoot '.git'
  if (-not (Test-Path -LiteralPath $gitMarker)) {
    if (-not $AllowDownload) {
      throw "The upstream submodule is not initialized. Run 'git submodule update --init -- $normalizedSubmodulePath' or use -AllowDownload."
    }
    Initialize-LockedSubmodule `
      -RepositoryRoot $resolvedRepositoryRoot `
      -SubmoduleRoot $submoduleRoot `
      -ExpectedRepository $ExpectedRepository `
      -ExpectedCommit $ExpectedCommit `
      -NormalizedSubmodulePath $normalizedSubmodulePath
  }
  $resolvedSource = (Resolve-Path -LiteralPath $submoduleRoot).Path
}

if (-not (Test-Path -LiteralPath (Join-Path $resolvedSource '.git'))) {
  throw "The DeepSeek Harness source must be a Git checkout: $resolvedSource"
}
$insideWorkTree = Invoke-GitCapture -WorkingDirectory $resolvedSource -Arguments @(
  'rev-parse', '--is-inside-work-tree'
) -FailureMessage 'Unable to inspect the source checkout'
if ($insideWorkTree -cne 'true') {
  throw "The DeepSeek Harness source is not a Git working tree: $resolvedSource"
}

$sourceCommit = Invoke-GitCapture -WorkingDirectory $resolvedSource -Arguments @(
  'rev-parse', 'HEAD'
) -FailureMessage 'Unable to read the source commit'
$sourceTreeHash = Invoke-GitCapture -WorkingDirectory $resolvedSource -Arguments @(
  'rev-parse', 'HEAD^{tree}'
) -FailureMessage 'Unable to read the source tree'
$sourceRemote = Invoke-GitCapture -WorkingDirectory $resolvedSource -Arguments @(
  'remote', 'get-url', 'origin'
) -FailureMessage 'Unable to read the source origin'

if ($sourceCommit -cne $ExpectedCommit) {
  throw "Source commit mismatch. Expected $ExpectedCommit, got $sourceCommit"
}
if ($sourceTreeHash -cne $ExpectedTree) {
  throw "Source tree mismatch. Expected $ExpectedTree, got $sourceTreeHash"
}
if ((Normalize-GitRemote $sourceRemote) -cne (Normalize-GitRemote $ExpectedRepository)) {
  throw "Source origin mismatch. Expected $ExpectedRepository, got $sourceRemote"
}
if ($sourceKind -eq 'submodule') {
  $sourceBranch = (& git -C $resolvedSource symbolic-ref --quiet --short HEAD 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -eq 0) {
    throw "The upstream submodule must remain detached at $ExpectedCommit, but it is on branch $sourceBranch."
  }
  if ($LASTEXITCODE -ne 1) {
    throw 'Unable to inspect whether the upstream submodule is detached.'
  }
}

$sourceStatus = @(& git -C $resolvedSource status --porcelain=v1 --untracked-files=normal 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "Unable to inspect source working-tree status (exit $LASTEXITCODE)."
}
if ($sourceStatus.Count -ne 0) {
  $statusPreview = ($sourceStatus | Select-Object -First 10) -join '; '
  throw "The upstream source checkout must be clean because local changes are not build inputs. Store deltas in apps/deepseek-harness/patches instead. Status: $statusPreview"
}

[pscustomobject]@{
  Path = $resolvedSource
  Kind = $sourceKind
  Repository = $sourceRemote
  Commit = $sourceCommit
  Tree = $sourceTreeHash
}
