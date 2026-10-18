[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $projectPath '..\..')).Path
$resolverPath = Join-Path $projectPath 'scripts\resolve-upstream-source.ps1'
$temporaryRoot = Join-Path $repositoryRoot '.tmp'
$testRoot = Join-Path $temporaryRoot ('deepseek-harness-source-resolver-tests-' + [guid]::NewGuid().ToString('N'))
$submodulePath = 'vendor/upstream/deepseek-harness'
$gitCommand = (Get-Command git -ErrorAction Stop).Source
$gitExecPath = $null
$gitPosixPathPrefix = @()

function Get-GitWindowsPathPrefix {
  $gitPath = $script:gitCommand
  $gitBin = Split-Path -Parent $gitPath
  $gitRoot = $null
  if ((Split-Path -Leaf $gitBin) -ieq 'cmd') {
    $gitRoot = Split-Path -Parent $gitBin
  } elseif ((Split-Path -Leaf $gitBin) -ieq 'bin') {
    $gitRoot = Split-Path -Parent $gitBin
  }
  if (-not $gitRoot) { return @() }

  $candidates = @(
    (Join-Path $gitRoot 'cmd'),
    (Join-Path $gitRoot 'bin'),
    (Join-Path $gitRoot 'usr\bin'),
    (Join-Path $gitRoot 'mingw64\bin'),
    (Join-Path $gitRoot 'mingw64\libexec\git-core')
  )
  $script:gitExecPath = Join-Path $gitRoot 'mingw64\libexec\git-core'
  $script:gitPosixPathPrefix = @('/mingw64/libexec/git-core', '/mingw64/bin', '/usr/bin', '/bin')
  return @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

$gitPathPrefix = @(Get-GitWindowsPathPrefix)

function Invoke-GitChecked {
  param(
    [string]$WorkingDirectory,
    [string[]]$Arguments
  )
  $previousPath = $env:Path
  $previousGitExecPath = $env:GIT_EXEC_PATH
  try {
    if ($script:gitPathPrefix.Count -gt 0) {
      $env:Path = ($script:gitPosixPathPrefix + @($previousPath)) -join ':'
    }
    if ($script:gitExecPath -and (Test-Path -LiteralPath $script:gitExecPath -PathType Container)) {
      $env:GIT_EXEC_PATH = $script:gitExecPath
    }
    $output = & $script:gitCommand -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE): $(($output | Out-String).Trim())"
    }
    return (($output | Out-String).Trim())
  } finally {
    $env:Path = $previousPath
    $env:GIT_EXEC_PATH = $previousGitExecPath
  }
}

function Assert-ThrowsLike {
  param(
    [scriptblock]$Action,
    [string]$Pattern
  )
  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "Expected failure matching '$Pattern', got: $($_.Exception.Message)"
    }
    return
  }
  throw "Expected failure matching '$Pattern'."
}

function Remove-TestPath {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path.TrimEnd('\')
  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  if (-not $resolvedPath.StartsWith($resolvedTestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test cleanup target: $resolvedPath"
  }
  Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Resolve-TestSource {
  param(
    [string]$Superproject,
    [string]$ExpectedRepository,
    [string]$ExpectedCommit,
    [string]$ExpectedTree,
    [string]$SourceTree,
    [switch]$AllowDownload
  )
  $parameters = @{
    RepositoryRoot = $Superproject
    ExpectedRepository = $ExpectedRepository
    ExpectedCommit = $ExpectedCommit
    ExpectedTree = $ExpectedTree
  }
  if ($SourceTree) { $parameters.SourceTree = $SourceTree }
  if ($AllowDownload) { $parameters.AllowDownload = $true }
  return & $resolverPath @parameters
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $upstream = Join-Path $testRoot 'upstream'
  $superproject = Join-Path $testRoot 'superproject'
  $override = Join-Path $testRoot 'override'
  New-Item -ItemType Directory -Path $upstream, $superproject | Out-Null

  Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('init', '--quiet') | Out-Null
  Set-Content -LiteralPath (Join-Path $upstream 'version.txt') -Value 'one' -Encoding utf8NoBOM
  Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('add', 'version.txt') | Out-Null
  Invoke-GitChecked -WorkingDirectory $upstream -Arguments @(
    '-c', 'user.name=Source Resolver Tests', '-c', 'user.email=source-resolver@example.invalid',
    'commit', '--quiet', '-m', 'test: add first source revision'
  ) | Out-Null
  $firstCommit = Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('rev-parse', 'HEAD')
  Set-Content -LiteralPath (Join-Path $upstream 'version.txt') -Value 'two' -Encoding utf8NoBOM
  Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('add', 'version.txt') | Out-Null
  Invoke-GitChecked -WorkingDirectory $upstream -Arguments @(
    '-c', 'user.name=Source Resolver Tests', '-c', 'user.email=source-resolver@example.invalid',
    'commit', '--quiet', '-m', 'test: add locked source revision'
  ) | Out-Null
  $expectedCommit = Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('rev-parse', 'HEAD')
  $expectedTree = Invoke-GitChecked -WorkingDirectory $upstream -Arguments @('rev-parse', 'HEAD^{tree}')

  Invoke-GitChecked -WorkingDirectory $superproject -Arguments @('init', '--quiet') | Out-Null
  $submoduleRoot = Join-Path $superproject $submodulePath
  New-Item -ItemType Directory -Path (Split-Path -Parent $submoduleRoot) -Force | Out-Null
  Invoke-GitChecked -WorkingDirectory $superproject -Arguments @('clone', '--quiet', $upstream, $submodulePath) | Out-Null
  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('checkout', '--quiet', '--detach', $expectedCommit) | Out-Null
  $upstreamConfigUrl = $upstream.Replace('\', '/')
  Set-Content -LiteralPath (Join-Path $superproject '.gitmodules') -Encoding utf8NoBOM -Value @"
[submodule "deepseek-harness"]
	path = vendor/upstream/deepseek-harness
	url = $upstreamConfigUrl
"@
  Invoke-GitChecked -WorkingDirectory $superproject -Arguments @('add', '.gitmodules') | Out-Null
  Invoke-GitChecked -WorkingDirectory $superproject -Arguments @(
    'update-index', '--add', '--cacheinfo', "160000,$expectedCommit,$submodulePath"
  ) | Out-Null
  Invoke-GitChecked -WorkingDirectory $superproject -Arguments @(
    '-c', 'user.name=Source Resolver Tests', '-c', 'user.email=source-resolver@example.invalid',
    'commit', '--quiet', '-m', 'test: pin upstream submodule'
  ) | Out-Null

  $initialized = Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree
  if ($initialized.Kind -ne 'submodule' -or $initialized.Commit -ne $expectedCommit) {
    throw 'Initialized submodule resolution returned an unexpected result.'
  }

  Invoke-GitChecked -WorkingDirectory $testRoot -Arguments @('clone', '--quiet', $upstream, $override) | Out-Null
  Invoke-GitChecked -WorkingDirectory $override -Arguments @('checkout', '--quiet', '--detach', $expectedCommit) | Out-Null
  $explicit = Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree -SourceTree $override
  if ($explicit.Kind -ne 'override' -or $explicit.Commit -ne $expectedCommit) {
    throw 'Explicit SourceTree resolution returned an unexpected result.'
  }

  Add-Content -LiteralPath (Join-Path $submoduleRoot 'version.txt') -Value 'dirty'
  Assert-ThrowsLike -Pattern 'must be clean' -Action {
    Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree | Out-Null
  }
  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('restore', 'version.txt') | Out-Null

  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('remote', 'set-url', 'origin', 'https://example.invalid/wrong.git') | Out-Null
  Assert-ThrowsLike -Pattern 'Source origin mismatch' -Action {
    Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree | Out-Null
  }
  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('remote', 'set-url', 'origin', $upstream) | Out-Null

  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('checkout', '--quiet', '--detach', $firstCommit) | Out-Null
  Assert-ThrowsLike -Pattern 'Source commit mismatch' -Action {
    Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree | Out-Null
  }
  Invoke-GitChecked -WorkingDirectory $submoduleRoot -Arguments @('checkout', '--quiet', '--detach', $expectedCommit) | Out-Null

  Remove-TestPath -Path $submoduleRoot
  Assert-ThrowsLike -Pattern 'not initialized' -Action {
    Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree | Out-Null
  }
  $downloaded = Resolve-TestSource -Superproject $superproject -ExpectedRepository $upstream -ExpectedCommit $expectedCommit -ExpectedTree $expectedTree -AllowDownload
  if ($downloaded.Kind -ne 'submodule' -or $downloaded.Commit -ne $expectedCommit) {
    throw 'AllowDownload did not initialize the locked submodule.'
  }

  Write-Output 'source checkout resolver tests passed'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path.TrimEnd('\')
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if (-not $resolvedTestRoot.StartsWith($resolvedTemporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Unsafe test cleanup target: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
