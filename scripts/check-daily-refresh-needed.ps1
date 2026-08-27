[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('schedule', 'workflow_dispatch', 'push')][string]$EventName,
  [Parameter(Mandatory = $true)][string]$Repository,
  [string]$WorkflowFile = 'daily-update.yml',
  [long]$CurrentRunId = 0,
  [string]$GitHubToken,
  [string]$OutputPath,
  [string]$RunsJsonPath,
  [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
)

$ErrorActionPreference = 'Stop'

function Write-Decision {
  param([bool]$ShouldRun, [string]$Reason, [long]$SuccessfulRunId = 0)
  $decision = $ShouldRun.ToString().ToLowerInvariant()
  Write-Host "Daily refresh decision: should_run=$decision; reason=$Reason; successful_run_id=$SuccessfulRunId"
  if ($OutputPath) {
    "should_run=$decision" | Out-File -FilePath $OutputPath -Encoding utf8 -Append
    "reason=$Reason" | Out-File -FilePath $OutputPath -Encoding utf8 -Append
    "successful_run_id=$SuccessfulRunId" | Out-File -FilePath $OutputPath -Encoding utf8 -Append
  }
}

if ($EventName -in @('workflow_dispatch', 'push')) {
  Write-Decision -ShouldRun $true -Reason $(if ($EventName -eq 'push') { 'catalog-change' } else { 'manual-dispatch' })
  return
}

try {
  if ($RunsJsonPath) {
    $response = Get-Content -LiteralPath $RunsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } else {
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) { throw 'GitHub token is unavailable for the freshness check.' }
    $headers = @{
      Accept = 'application/vnd.github+json'
      Authorization = "Bearer $GitHubToken"
      'User-Agent' = 'Apart-price-daily-refresh'
      'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$Repository/actions/workflows/$WorkflowFile/runs?per_page=100"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30
  }

  $koreaOffset = [TimeSpan]::FromHours(9)
  $koreaDate = $NowUtc.ToOffset($koreaOffset).Date
  $dayStartUtc = [DateTimeOffset]::new($koreaDate, $koreaOffset).ToUniversalTime()
  $successfulRun = @($response.workflow_runs | Where-Object {
      [long]$_.id -ne $CurrentRunId -and
      [string]$_.conclusion -eq 'success' -and
      [string]$_.event -in @('schedule', 'workflow_dispatch') -and
      [DateTimeOffset]::Parse([string]$_.updated_at) -ge $dayStartUtc
    } | Sort-Object { [DateTimeOffset]::Parse([string]$_.updated_at) } -Descending | Select-Object -First 1)

  if ($successfulRun.Count) {
    Write-Decision -ShouldRun $false -Reason 'already-succeeded-today' -SuccessfulRunId ([long]$successfulRun[0].id)
    return
  }
  Write-Decision -ShouldRun $true -Reason 'no-success-today'
} catch {
  Write-Warning "Freshness check failed; running the updater as the safe fallback: $($_.Exception.Message)"
  Write-Decision -ShouldRun $true -Reason 'freshness-check-failed'
}
