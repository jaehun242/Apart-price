[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourceDataPath = Join-Path $repositoryDirectory 'public\data\transactions.js'
$catalogPath = Join-Path $repositoryDirectory 'config\additional-apartments.json'
$updaterPath = Join-Path $repositoryDirectory 'scripts\update-data-github.ps1'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("apart-price-deferred-matching-{0}" -f [Guid]::NewGuid().ToString('N'))
$dataPath = Join-Path $testDirectory 'transactions.js'
$logPath = Join-Path $testDirectory 'run.json'
$reportPath = Join-Path $testDirectory 'matching.md'
$backupPath = Join-Path $testDirectory 'backup.js'
$serverJob = $null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
  [IO.Directory]::CreateDirectory($testDirectory) | Out-Null
  $sourceText = [IO.File]::ReadAllText($sourceDataPath, [Text.Encoding]::UTF8)
  $sourceDataset = (($sourceText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json

  $existingComplex = $null
  $catalogEntry = $null
  foreach ($candidate in @($sourceDataset.complexes | Where-Object { $_.openApi.identityKey })) {
    $lawdCode = ([string]$candidate.id).Split('-')[1]
    $entry = @($catalog.complexes | Where-Object {
        ([string]$_.id).Split('-')[1] -eq $lawdCode -and
        -not (@($sourceDataset.complexes.id) -contains [string]$_.id)
      } | Select-Object -First 1)
    if ($entry.Count) { $existingComplex = $candidate; $catalogEntry = $entry[0]; break }
  }
  if (-not $existingComplex -or -not $catalogEntry) { throw 'Unable to build deferred catalog matching fixture.' }

  $existingRows = @($sourceDataset.records | Where-Object { $_.complexId -eq $existingComplex.id })
  if (-not $existingRows.Count) { throw 'Fixture established complex has no transaction rows.' }
  $deferredComplex = [PSCustomObject][ordered]@{
    id = [string]$catalogEntry.id
    city = [string]$catalogEntry.city
    district = [string]$catalogEntry.district
    name = [string]$catalogEntry.name
    leader = $false
    featured = $false
    tags = @('fixture')
    catalogAddedAt = [string]$catalog.version
    stats = [PSCustomObject]@{ valid = 0; cancelled = 0; recentCancelled = 0; firstDate = $null; lastDate = $null; years = 0; groups = [PSCustomObject]@{} }
    dataMode = 'transactions'
    sourceLabel = '국토교통부 실거래가'
  }
  $fixtureDataset = [ordered]@{
    meta = $sourceDataset.meta
    complexes = @($existingComplex, $deferredComplex)
    records = $existingRows
  }
  $fixtureDataset.meta.complexCount = 2
  $fixtureDataset.meta.recordCount = $existingRows.Count
  [IO.File]::WriteAllText($dataPath, ('window.APT_ARCHIVE_DATA = ' + ($fixtureDataset | ConvertTo-Json -Depth 24 -Compress) + ';' + [Environment]::NewLine), $Utf8NoBom)
  $fixtureAptSeq = [Security.SecurityElement]::Escape([string]$existingComplex.openApi.aptSeq)
  $fixtureAptName = [Security.SecurityElement]::Escape([string]$existingComplex.openApi.aptName)
  $fixtureLegalDong = [Security.SecurityElement]::Escape([string]$existingComplex.openApi.legalDong)
  $fixtureJibun = [Security.SecurityElement]::Escape([string]$existingComplex.openApi.jibun)
  $fixtureRoadName = [Security.SecurityElement]::Escape([string]$existingComplex.openApi.roadName)

  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()
  $serverJob = Start-ThreadJob -ArgumentList $port, $fixtureAptSeq, $fixtureAptName, $fixtureLegalDong, $fixtureJibun, $fixtureRoadName -ScriptBlock {
    param([int]$Port, [string]$AptSeq, [string]$AptName, [string]$LegalDong, [string]$Jibun, [string]$RoadName)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    try {
      for ($requestNumber = 1; $requestNumber -le 6; $requestNumber++) {
        $client = $listener.AcceptTcpClient()
        try {
          $stream = $client.GetStream()
          $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
          $requestLine = $reader.ReadLine()
          while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) { break }
          }
          if ($requestNumber -eq 6) {
            $body = [Text.Encoding]::UTF8.GetBytes('optional discovery outage')
            $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 503 Service Unavailable`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header, 0, $header.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Flush()
            continue
          }
          $dealYmd = if ($requestLine -match '[?&]DEAL_YMD=(\d{6})') { $matches[1] } else { (Get-Date).ToString('yyyyMM') }
          $year = $dealYmd.Substring(0, 4)
          $month = [int]$dealYmd.Substring(4, 2)
          $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<response><header><resultCode>000</resultCode><resultMsg>OK</resultMsg></header><body><items><item><aptSeq>$AptSeq</aptSeq><aptNm>$AptName</aptNm><umdNm>$LegalDong</umdNm><jibun>$Jibun</jibun><roadNm>$RoadName</roadNm><dealYear>$year</dealYear><dealMonth>$month</dealMonth><dealDay>20</dealDay><excluUseAr>84.9146</excluUseAr><dealAmount>55,000</dealAmount><floor>7</floor><aptDong>101</aptDong><dealingGbn>중개거래</dealingGbn><estateAgentSggNm>fixture</estateAgentSggNm><rgstDate></rgstDate><cdealDay></cdealDay><cdealType></cdealType></item></items><numOfRows>9999</numOfRows><pageNo>1</pageNo><totalCount>1</totalCount></body></response>
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
    if ($serverJob.State -eq 'Failed') { throw "Fixture server failed: $(Receive-Job -Job $serverJob -Keep | Out-String)" }
  } while ($serverJob.State -eq 'NotStarted' -and [DateTime]::UtcNow -lt $deadline)

  & $updaterPath `
    -DataPath $dataPath `
    -ApiKey 'fixture-secret' `
    -ApiEndpoint "http://127.0.0.1:$port/openapi" `
    -RefreshMonths 3 `
    -CatalogDiscoveryMonths 6 `
    -RequestDelayMs 0 `
    -RequestTimeoutSec 5 `
    -MaxRetries 1 `
    -ComplexIds @([string]$existingComplex.id, [string]$deferredComplex.id) `
    -LogPath $logPath `
    -BackupPath $backupPath `
    -MatchReportPath $reportPath
  if (-not $?) { throw 'Deferred matching update failed.' }

  $serverJob | Wait-Job -Timeout 10 | Out-Null
  if ($serverJob.State -ne 'Completed') { throw "Fixture server did not complete: $($serverJob.State)" }
  Receive-Job -Job $serverJob | Out-Null
  $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$log.status -ne 'success-changed') { throw "Unexpected updater status: $($log.status)" }
  if ([int]$log.complexesRequested -ne 2 -or [int]$log.complexesMatched -ne 1) { throw "Expected 1/2 matched, got $($log.complexesMatched)/$($log.complexesRequested)." }
  if ([int]$log.complexesDeferred -ne 1 -or [int]$log.criticalUnmatched -ne 0) { throw "Deferred classification failed: deferred=$($log.complexesDeferred), critical=$($log.criticalUnmatched)." }
  if ([int]$log.pairsCompleted -ne 5 -or [int]$log.pairsFailed -ne 1) { throw "Unexpected request accounting: completed=$($log.pairsCompleted), failed=$($log.pairsFailed)." }
  if (-not (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8).Contains('deferred-new-catalog')) { throw 'Matching report does not label the deferred catalog complex.' }
  $updatedText = [IO.File]::ReadAllText($dataPath, [Text.Encoding]::UTF8)
  $updated = (($updatedText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  $deferredOutput = @($updated.complexes | Where-Object { $_.id -eq $deferredComplex.id } | Select-Object -First 1)
  if (-not $deferredOutput.Count -or [string]$deferredOutput[0].openApiDiscovery.status -ne 'deferred') { throw 'Deferred discovery state was not persisted.' }
  if ([string]$deferredOutput[0].openApiDiscovery.nextAttempt -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Deferred discovery retry date was not persisted.' }
  if (@($updated.records | Where-Object { $_.complexId -eq $deferredComplex.id }).Count -ne 0) { throw 'An unmatched catalog complex received another complex transaction rows.' }
  if (-not (Test-Path -LiteralPath $backupPath)) { throw 'Successful update did not create a data backup.' }
  Write-Host 'Deferred catalog matching test passed: an unmatched new zero-history complex and an optional discovery outage are isolated without blocking or contaminating established apartment refreshes.'
} finally {
  if ($serverJob) {
    if ($serverJob.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $serverJob -ErrorAction SilentlyContinue }
    Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}
