[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataPath = Join-Path $repositoryDirectory 'public\data\transactions.js'
$updaterPath = Join-Path $repositoryDirectory 'scripts\update-data-github.ps1'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("apart-price-openapi-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$logPath = Join-Path $testDirectory 'run.json'
$reportPath = Join-Path $testDirectory 'matching.md'
$backupPath = Join-Path $testDirectory 'backup.js'
$serverJob = $null

function Get-FileHashText {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

try {
  [IO.Directory]::CreateDirectory($testDirectory) | Out-Null
  $beforeHash = Get-FileHashText $dataPath
  $datasetText = [IO.File]::ReadAllText($dataPath, [Text.Encoding]::UTF8)
  $dataset = (($datasetText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  $fixtureComplex = @($dataset.complexes)[0]
  if (-not $fixtureComplex) { throw 'Fixture test requires at least one apartment complex.' }
  $fixtureAptSeq = if ($fixtureComplex.openApi.aptSeq) { [string]$fixtureComplex.openApi.aptSeq } else { 'fixture-1' }
  $fixtureAptName = if ($fixtureComplex.openApi.aptName) { [string]$fixtureComplex.openApi.aptName } else { [string]$fixtureComplex.name }
  $fixtureLegalDong = if ($fixtureComplex.openApi.legalDong) { [string]$fixtureComplex.openApi.legalDong } else { 'fixture-dong' }
  $fixtureJibun = if ($fixtureComplex.openApi.jibun) { [string]$fixtureComplex.openApi.jibun } else { '123' }
  $fixtureRoadName = if ($fixtureComplex.openApi.roadName) { [string]$fixtureComplex.openApi.roadName } else { 'fixture-road' }
  $fixtureAptSeq = [Security.SecurityElement]::Escape($fixtureAptSeq)
  $fixtureAptName = [Security.SecurityElement]::Escape($fixtureAptName)
  $fixtureLegalDong = [Security.SecurityElement]::Escape($fixtureLegalDong)
  $fixtureJibun = [Security.SecurityElement]::Escape($fixtureJibun)
  $fixtureRoadName = [Security.SecurityElement]::Escape($fixtureRoadName)

  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()

  # A thread job keeps the local socket in the same process; process jobs cannot
  # reliably create listening sockets in the Windows GitHub Actions sandbox.
  $serverJob = Start-ThreadJob -ArgumentList $port, $fixtureAptSeq, $fixtureAptName, $fixtureLegalDong, $fixtureJibun, $fixtureRoadName -ScriptBlock {
    param([int]$Port, [string]$AptSeq, [string]$AptName, [string]$LegalDong, [string]$Jibun, [string]$RoadName)
    $ErrorActionPreference = 'Stop'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    try {
      for ($requestNumber = 1; $requestNumber -le 4; $requestNumber++) {
        $client = $listener.AcceptTcpClient()
        try {
          $stream = $client.GetStream()
          $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
          while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) { break }
          }
          if ($requestNumber -eq 1) {
            $body = [Text.Encoding]::UTF8.GetBytes('temporary upstream failure')
            $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 503 Service Unavailable`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header, 0, $header.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Flush()
            continue
          }
          # Keep fixture transactions safely in the past on every calendar day.
          # Fixed day-of-month values become future dates at the start of a month.
          $contractDate = (Get-Date).Date.AddDays(-10)
          $cancelledContractDate = $contractDate.AddDays(-1)
          $cancellationDate = $contractDate.AddDays(1).ToString('yyyyMMdd')
          $month = $contractDate.Month
          $year = $contractDate.Year
          $day = $contractDate.Day
          $cancelledMonth = $cancelledContractDate.Month
          $cancelledYear = $cancelledContractDate.Year
          $cancelledDay = $cancelledContractDate.Day
          $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<response>
  <header><resultCode>000</resultCode><resultMsg>OK</resultMsg></header>
  <body>
    <items>
      <item><aptSeq>$AptSeq</aptSeq><aptNm>$AptName</aptNm><umdNm>$LegalDong</umdNm><jibun>$Jibun</jibun><roadNm>$RoadName</roadNm><dealYear>$year</dealYear><dealMonth>$month</dealMonth><dealDay>$day</dealDay><excluUseAr>84.9146</excluUseAr><dealAmount>55,000</dealAmount><floor>7</floor><aptDong>101</aptDong><dealingGbn>중개거래</dealingGbn><estateAgentSggNm>부산 강서구</estateAgentSggNm><rgstDate></rgstDate><cdealDay></cdealDay><cdealType></cdealType></item>
      <item><aptSeq>$AptSeq</aptSeq><aptNm>$AptName</aptNm><umdNm>$LegalDong</umdNm><jibun>$Jibun</jibun><roadNm>$RoadName</roadNm><dealYear>$year</dealYear><dealMonth>$month</dealMonth><dealDay>$day</dealDay><excluUseAr>84.9146</excluUseAr><dealAmount>55,000</dealAmount><floor>7</floor><aptDong>101</aptDong><dealingGbn>중개거래</dealingGbn><estateAgentSggNm>부산 강서구</estateAgentSggNm><rgstDate></rgstDate><cdealDay></cdealDay><cdealType></cdealType></item>
      <item><aptSeq>$AptSeq</aptSeq><aptNm>$AptName</aptNm><umdNm>$LegalDong</umdNm><jibun>$Jibun</jibun><roadNm>$RoadName</roadNm><dealYear>$year</dealYear><dealMonth>$month</dealMonth><dealDay>$day</dealDay><excluUseAr>59.9821</excluUseAr><dealAmount>42,000</dealAmount><floor>11</floor><aptDong>103</aptDong><dealingGbn>중개거래</dealingGbn><estateAgentSggNm>부산 강서구</estateAgentSggNm><rgstDate></rgstDate><cdealDay></cdealDay><cdealType></cdealType></item>
      <item><aptSeq>$AptSeq</aptSeq><aptNm>$AptName</aptNm><umdNm>$LegalDong</umdNm><jibun>$Jibun</jibun><roadNm>$RoadName</roadNm><dealYear>$cancelledYear</dealYear><dealMonth>$cancelledMonth</dealMonth><dealDay>$cancelledDay</dealDay><excluUseAr>84.9146</excluUseAr><dealAmount>54,000</dealAmount><floor>5</floor><aptDong>102</aptDong><dealingGbn>중개거래</dealingGbn><estateAgentSggNm>부산 강서구</estateAgentSggNm><rgstDate></rgstDate><cdealDay>$cancellationDate</cdealDay><cdealType>O</cdealType></item>
    </items>
    <numOfRows>9999</numOfRows><pageNo>1</pageNo><totalCount>4</totalCount>
  </body>
</response>
"@
          $body = [Text.Encoding]::UTF8.GetBytes($xml)
          $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/xml; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
          $stream.Write($header, 0, $header.Length)
          $stream.Write($body, 0, $body.Length)
          $stream.Flush()
        } finally {
          $client.Dispose()
        }
      }
    } finally {
      $listener.Stop()
    }
  }

  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 100
    $state = $serverJob.State
    if ($state -eq 'Failed') { throw "Fixture server failed: $(Receive-Job -Job $serverJob -Keep | Out-String)" }
  } while ($state -eq 'NotStarted' -and [DateTime]::UtcNow -lt $deadline)

  & $updaterPath `
    -DataPath $dataPath `
    -ApiKey 'fixture-secret-that-must-not-be-logged' `
    -ApiEndpoint "http://127.0.0.1:$port/openapi" `
    -RefreshMonths 3 `
    -RequestDelayMs 0 `
    -RequestTimeoutSec 5 `
    -MaxRetries 3 `
    -Limit 1 `
    -LogPath $logPath `
    -BackupPath $backupPath `
    -MatchReportPath $reportPath `
    -Probe
  if (-not $?) { throw 'Updater probe failed.' }

  $serverJob | Wait-Job -Timeout 10 | Out-Null
  if ($serverJob.State -ne 'Completed') { throw "Fixture server did not complete: $($serverJob.State)" }
  Receive-Job -Job $serverJob | Out-Null

  $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$log.status -ne 'probe-success') { throw "Unexpected updater status: $($log.status)" }
  if (-not [bool]$log.apiKeyRecognized) { throw 'Fixture API key was not recognized.' }
  if ([int]$log.complexesMatched -ne 1 -or [int]$log.complexesRequested -ne 1) { throw "Fixture matching failed: $($log.complexesMatched)/$($log.complexesRequested)" }
  if ([int]$log.pairsCompleted -ne 3 -or [int]$log.apiCalls -ne 3) { throw "Fixture request count mismatch: pairs=$($log.pairsCompleted), calls=$($log.apiCalls)" }
  if ([int]$log.apiAttempts -ne 4) { throw "Expected one retry and four total attempts, got $($log.apiAttempts)." }
  if ([int]$log.validDownloaded -ne 2) { throw "Expected two distinct deduplicated valid rows, got $($log.validDownloaded)." }
  if ([int]$log.cancelledExcluded -ne 3) { throw "Expected three cancelled rows, got $($log.cancelledExcluded)." }
  if ([int]$log.duplicateRowsSkipped -ne 7) { throw "Expected seven duplicate rows, got $($log.duplicateRowsSkipped)." }
  if ((Get-Content -LiteralPath $logPath -Raw -Encoding UTF8).Contains('fixture-secret-that-must-not-be-logged')) { throw 'API key leaked into the updater log.' }
  if ((Get-FileHashText $dataPath) -ne $beforeHash) { throw 'Probe mode changed transactions.js.' }
  if (Test-Path -LiteralPath $backupPath) { throw 'Probe mode unexpectedly created a data backup.' }

  Write-Host 'OpenAPI updater integration test passed: retry, key recognition, three rolling calls, matching, cancellation, deduplication, secret redaction, and data-file preservation.'
} finally {
  if ($serverJob) {
    if ($serverJob.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $serverJob -ErrorAction SilentlyContinue }
    Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}
