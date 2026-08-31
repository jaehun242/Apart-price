[CmdletBinding()]
param([switch]$FailDiscovery)

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

  $complexIdsWithRows = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($record in @($sourceDataset.records)) { [void]$complexIdsWithRows.Add([string]$record.complexId) }
  $existingComplex = @($sourceDataset.complexes | Where-Object {
      $_.openApi.identityKey -and $complexIdsWithRows.Contains([string]$_.id)
    } | Select-Object -First 1)
  if (-not $existingComplex.Count) { throw 'Unable to find an established OpenAPI complex for the deferred matching fixture.' }
  $existingComplex = $existingComplex[0]

  $existingRows = @($sourceDataset.records | Where-Object { $_.complexId -eq $existingComplex.id })
  if (-not $existingRows.Count) { throw 'Fixture established complex has no transaction rows.' }
  $deferredComplex = [PSCustomObject][ordered]@{
    id = "fixture-$([string]$existingComplex.openApi.lawdCode)-catalog-deferred"
    city = [string]$existingComplex.city
    district = [string]$existingComplex.district
    name = '미매칭신규단지픽스처'
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
  $beforeHash = (Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash
  $serverJob = Start-ThreadJob -ArgumentList $port, $fixtureAptSeq, $fixtureAptName, $fixtureLegalDong, $fixtureJibun, $fixtureRoadName, ([bool]$FailDiscovery) -ScriptBlock {
    param([int]$Port, [string]$AptSeq, [string]$AptName, [string]$LegalDong, [string]$Jibun, [string]$RoadName, [bool]$FailDiscovery)
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
          if ($requestNumber -eq 6 -and $FailDiscovery) {
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

  $apiFailed = $false
  try { & $updaterPath `
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
  } catch {
    $apiFailed = $true
    if (-not $FailDiscovery) { throw }
  }

  $serverJob | Wait-Job -Timeout 10 | Out-Null
  if ($serverJob.State -ne 'Completed') { throw "Fixture server did not complete: $($serverJob.State)" }
  Receive-Job -Job $serverJob | Out-Null
  $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($FailDiscovery) {
    if (-not $apiFailed -or $log.status -ne 'failed' -or -not $log.dataPreserved) { throw 'Partial discovery failure was treated as success.' }
    if ((Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash -ne $beforeHash) { throw 'API failure overwrote existing data.' }
    if (Test-Path -LiteralPath $backupPath) { throw 'Failed collection unexpectedly entered the write stage.' }
    Write-Host 'E PASS: incomplete collection fails and preserves the original file byte-for-byte.'
    return
  }
  if ([string]$log.status -ne 'success-changed') { throw "Unexpected updater status: $($log.status)" }
  if ([int]$log.complexesRequested -ne 2 -or [int]$log.complexesMatched -ne 1) { throw "Expected 1/2 matched, got $($log.complexesMatched)/$($log.complexesRequested)." }
  if ([int]$log.complexesDeferred -ne 1 -or [int]$log.criticalUnmatched -ne 0) { throw "Deferred classification failed: deferred=$($log.complexesDeferred), critical=$($log.criticalUnmatched)." }
  if ([int]$log.pairsCompleted -ne 6 -or [int]$log.pairsFailed -ne 0) { throw "Unexpected request accounting: completed=$($log.pairsCompleted), failed=$($log.pairsFailed)." }
  if (-not (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8).Contains('deferred-new-catalog')) { throw 'Matching report does not label the deferred catalog complex.' }
  $updatedText = [IO.File]::ReadAllText($dataPath, [Text.Encoding]::UTF8)
  $updated = (($updatedText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  $deferredOutput = @($updated.complexes | Where-Object { $_.id -eq $deferredComplex.id } | Select-Object -First 1)
  if (-not $deferredOutput.Count -or [string]$deferredOutput[0].openApiDiscovery.status -ne 'deferred') { throw 'Deferred discovery state was not persisted.' }
  if ([string]$deferredOutput[0].openApiDiscovery.nextAttempt -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Deferred discovery retry date was not persisted.' }
  if (@($updated.records | Where-Object { $_.complexId -eq $deferredComplex.id }).Count -ne 0) { throw 'An unmatched catalog complex received another complex transaction rows.' }
  if (-not (Test-Path -LiteralPath $backupPath)) { throw 'Successful update did not create a data backup.' }
  Write-Host 'Deferred catalog matching test passed: all requests complete; unmatched zero-history catalog remains deferred without contaminating established apartments.'
} finally {
  if ($serverJob) {
    if ($serverJob.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $serverJob -ErrorAction SilentlyContinue }
    Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}
