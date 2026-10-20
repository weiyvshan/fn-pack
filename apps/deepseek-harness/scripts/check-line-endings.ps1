#!/usr/bin/env pwsh
# Repository-wide line-ending guard for Windows checkouts.
#
# The POSIX implementation lives in check-line-endings.sh; this one mirrors the
# same contract for the PowerShell entry point, which cannot run the shell
# script against a Windows path.
#
# Only the working tree is checked: the Git attributes normalise the index to
# LF on every commit, so the index cannot hold CRLF. The build reads the
# working tree, which is what this guard protects.
[CmdletBinding()]
param(
  [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = (git rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Write-Output 'SKIP: not a Git work tree.'
    exit 0
  }
}
Set-Location -LiteralPath $RepositoryRoot

$status = 0
foreach ($file in @(git ls-files -z | ForEach-Object { $_ -split "`0" })) {
  if ([string]::IsNullOrWhiteSpace($file)) { continue }
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
  $attribute = (git check-attr text -- $file | Select-Object -Last 1)
  $textAttribute = ($attribute -split ': ')[-1].Trim()
  if ($textAttribute -ne 'set' -and $textAttribute -ne 'auto') { continue }
  $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $file))
  for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
    if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
      Write-Error "CRLF line endings are not allowed in tracked text files: $file" -ErrorAction Continue
      $status = 1
      break
    }
  }
}

if ($status -ne 0) {
  exit 1
}

Write-Output 'line-ending guard passed'
exit 0
