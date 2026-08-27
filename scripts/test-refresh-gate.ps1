[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$gatePath = Join-Path $repositoryDirectory 'scripts\check-daily-refresh-needed.ps1'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("apart-price-refresh-gate-{0}" -f [Guid]::NewGuid().ToString('N'))
$now = [DateTimeOffset]::Parse('2026-08-27T03:00:00Z')

function Invoke-GateCase {
  param([string]$Name, [string]$EventName, $Runs, [long]$CurrentRunId, [bool]$ExpectedShouldRun, [string]$ExpectedReason)
  $runsPath = Join-Path $testDirectory "$Name-runs.json"
  $outputPath = Join-Path $testDirectory "$Name-output.txt"
  @{ workflow_runs = @($Runs) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runsPath -Encoding UTF8
  & $gatePath -EventName $EventName -Repository 'owner/repo' -CurrentRunId $CurrentRunId -RunsJsonPath $runsPath -OutputPath $outputPath -NowUtc $now
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $outputPath) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) { $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1) }
  }
  if ([bool]::Parse($values.should_run) -ne $ExpectedShouldRun) { throw "$Name expected should_run=$ExpectedShouldRun, got $($values.should_run)." }
  if ([string]$values.reason -ne $ExpectedReason) { throw "$Name expected reason=$ExpectedReason, got $($values.reason)." }
}

try {
  [IO.Directory]::CreateDirectory($testDirectory) | Out-Null
  $todaySuccess = [PSCustomObject]@{ id = 101; event = 'schedule'; conclusion = 'success'; updated_at = '2026-08-27T01:00:00Z' }
  $todayFailure = [PSCustomObject]@{ id = 102; event = 'schedule'; conclusion = 'failure'; updated_at = '2026-08-27T02:00:00Z' }
  $yesterdaySuccess = [PSCustomObject]@{ id = 103; event = 'schedule'; conclusion = 'success'; updated_at = '2026-08-26T14:59:59Z' }

  Invoke-GateCase -Name 'scheduled-after-success' -EventName 'schedule' -Runs @($todaySuccess) -CurrentRunId 200 -ExpectedShouldRun $false -ExpectedReason 'already-succeeded-today'
  Invoke-GateCase -Name 'scheduled-after-failure' -EventName 'schedule' -Runs @($todayFailure, $yesterdaySuccess) -CurrentRunId 200 -ExpectedShouldRun $true -ExpectedReason 'no-success-today'
  Invoke-GateCase -Name 'current-run-excluded' -EventName 'schedule' -Runs @([PSCustomObject]@{ id = 200; event = 'schedule'; conclusion = 'success'; updated_at = '2026-08-27T02:30:00Z' }) -CurrentRunId 200 -ExpectedShouldRun $true -ExpectedReason 'no-success-today'
  Invoke-GateCase -Name 'manual-always-runs' -EventName 'workflow_dispatch' -Runs @($todaySuccess) -CurrentRunId 200 -ExpectedShouldRun $true -ExpectedReason 'manual-dispatch'
  Invoke-GateCase -Name 'catalog-change-always-runs' -EventName 'push' -Runs @($todaySuccess) -CurrentRunId 200 -ExpectedShouldRun $true -ExpectedReason 'catalog-change'

  Write-Host 'Daily refresh gate tests passed: success skip, failed retry, current-run exclusion, manual override, and catalog-change override.'
} finally {
  if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}
