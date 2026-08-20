[CmdletBinding()]
param(
  [string]$DataPath = 'public\data\transactions.js',
  [int[]]$Years,
  [int]$RequestDelayMs = 1100,
  [int]$MaxRetries = 3,
  [int]$Limit = 0,
  [string[]]$ComplexIds,
  [string]$LogPath = '',
  [string]$BackupPath = '',
  [switch]$Probe
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$MolitPageUrl = 'https://rt.molit.go.kr/pt/gis/gis.do'
$MolitDetailUrl = 'https://rt.molit.go.kr/pt/gis/ptDtl.do'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryDirectory = Split-Path -Parent $scriptDirectory
$browserProcess = $null
$browserSocket = $null
$browserProfile = $null
$lockStream = $null
$temporaryFile = $null
$script:CdpMessageId = 0

function Get-KoreaNow {
  $zone = $null
  foreach ($zoneId in @('Korea Standard Time', 'Asia/Seoul')) {
    try {
      $zone = [TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
      break
    } catch { }
  }
  if (-not $zone) { throw 'Korea time zone is unavailable.' }
  return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $zone)
}

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string]$Path, [string]$BasePath = $repositoryDirectory)
  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

$startedAt = Get-KoreaNow
$dataFile = Resolve-AbsolutePath -Path $DataPath
$dataDirectory = Split-Path -Parent $dataFile
if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $LogPath = Join-Path ([IO.Path]::GetTempPath()) 'apart-price-update-log.json'
}
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
  $BackupPath = Join-Path ([IO.Path]::GetTempPath()) 'apart-price-transactions.previous.js'
}
$logFile = Resolve-AbsolutePath -Path $LogPath -BasePath $repositoryDirectory
$backupFile = Resolve-AbsolutePath -Path $BackupPath -BasePath $repositoryDirectory
$lockFile = $dataFile + '.update.lock'

function Write-UpdateLog {
  param([System.Collections.IDictionary]$Values)
  try {
    $Values['finishedAt'] = (Get-KoreaNow).ToString('o')
    $logDirectory = Split-Path -Parent $logFile
    if (-not (Test-Path -LiteralPath $logDirectory)) { [IO.Directory]::CreateDirectory($logDirectory) | Out-Null }
    $json = $Values | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($logFile, $json + [Environment]::NewLine, $Utf8NoBom)
  } catch {
    Write-Warning "Unable to write update log: $($_.Exception.Message)"
  }
}

function Get-FreeTcpPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
  finally { $listener.Stop() }
}

function Find-BrowserExecutable {
  $candidates = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  foreach ($commandName in @('msedge', 'chrome', 'google-chrome', 'chromium', 'chromium-browser')) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  throw 'Microsoft Edge or Chromium browser executable was not found.'
}

function Start-MolitBrowser {
  $browser = Find-BrowserExecutable
  $port = Get-FreeTcpPort
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  $script:browserProfile = Join-Path $tempRoot ("apt-price-updater-" + [Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($script:browserProfile) | Out-Null

  $arguments = @(
    '--headless=new',
    '--disable-gpu',
    '--disable-gpu-compositing',
    '--no-sandbox',
    '--no-first-run',
    '--disable-extensions',
    "--remote-debugging-port=$port",
    '--remote-allow-origins=*',
    "--user-data-dir=$($script:browserProfile)",
    $MolitPageUrl
  )
  $startParameters = @{ FilePath = $browser; ArgumentList = $arguments; PassThru = $true }
  if ($env:OS -eq 'Windows_NT') { $startParameters['WindowStyle'] = 'Hidden' }
  $script:browserProcess = Start-Process @startParameters

  $target = $null
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    try {
      $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 2
      $target = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://rt.molit.go.kr/*' } | Select-Object -First 1
      if ($target) { break }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $target) { throw 'The MOLIT page did not open in the headless browser.' }

  $script:browserSocket = [Net.WebSockets.ClientWebSocket]::new()
  $script:browserSocket.ConnectAsync([uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Invoke-CdpExpression {
  param([Parameter(Mandatory = $true)][string]$Expression)
  $script:CdpMessageId++
  $messageId = $script:CdpMessageId
  $message = @{
    id = $messageId
    method = 'Runtime.evaluate'
    params = @{ expression = $Expression; awaitPromise = $true; returnByValue = $true }
  } | ConvertTo-Json -Depth 8 -Compress

  $bytes = [Text.Encoding]::UTF8.GetBytes($message)
  $browserSocket.SendAsync(
    [ArraySegment[byte]]::new($bytes),
    [Net.WebSockets.WebSocketMessageType]::Text,
    $true,
    [Threading.CancellationToken]::None
  ).GetAwaiter().GetResult() | Out-Null

  $buffer = New-Object byte[] 1048576
  do {
    $stream = [IO.MemoryStream]::new()
    try {
      do {
        $receive = $browserSocket.ReceiveAsync(
          [ArraySegment[byte]]::new($buffer),
          [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()
        if ($receive.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
          throw 'The MOLIT browser connection closed unexpectedly.'
        }
        $stream.Write($buffer, 0, $receive.Count)
      } while (-not $receive.EndOfMessage)
      $response = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
    } finally {
      $stream.Dispose()
    }
  } while ($response.id -ne $messageId)

  if ($response.result.exceptionDetails) {
    throw "Browser request failed: $($response.result.exceptionDetails.text)"
  }
  return $response.result.result.value
}

function Get-MolitYear {
  param(
    [Parameter(Mandatory = $true)][string]$ComplexCode,
    [Parameter(Mandatory = $true)][int]$Year
  )
  $parameters = [ordered]@{
    srhThingSecd = 'A'
    srhDelngSecd = '1'
    dtlLi = ''
    dtlYear = [string]$Year
    dtlMon = ''
    dtlArea = ''
    dtlAmount = ''
    dtlLfstsMtht = ''
    srhAprpnHsmpCode = $ComplexCode
    dtlGbn1 = ''
    dtlGbn2 = ''
  }
  $parameterJson = $parameters | ConvertTo-Json -Compress
  $expression = @"
(async () => {
  const parameters = $parameterJson;
  const response = await fetch('$MolitDetailUrl', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: new URLSearchParams(parameters)
  });
  const text = await response.text();
  if (!response.ok) throw new Error('HTTP ' + response.status + ': ' + text.slice(0, 160));
  const data = JSON.parse(text);
  return JSON.stringify(data);
})()
"@
  $raw = Invoke-CdpExpression -Expression $expression
  return $raw | ConvertFrom-Json
}

function Get-MolitYearWithRetry {
  param(
    [Parameter(Mandatory = $true)][string]$ComplexCode,
    [Parameter(Mandatory = $true)][int]$Year
  )
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
      $data = Get-MolitYear -ComplexCode $ComplexCode -Year $Year
      if ($data.error) { throw [Exception]::new([string]$data.error) }
      if (-not ($data.PSObject.Properties.Name -contains 'danjiList')) {
        throw 'MOLIT response does not contain danjiList.'
      }
      return $data
    } catch {
      $lastError = $_.Exception
      if ($attempt -lt $MaxRetries) {
        $pauseSeconds = @(3, 10, 30)[[Math]::Min($attempt - 1, 2)]
        Write-Warning "Retry $attempt/$MaxRetries ($ComplexCode, $Year): $($lastError.Message)"
        Start-Sleep -Seconds $pauseSeconds
      }
    }
  }
  throw "MOLIT request failed ($ComplexCode, $Year): $($lastError.Message)"
}

function Convert-MolitRow {
  param(
    [Parameter(Mandatory = $true)]$Row,
    [Parameter(Mandatory = $true)][string]$ComplexId
  )
  $dateText = ([string]$Row.cntrctDe).Trim()
  if ($dateText -notmatch '^\d{8}$') { throw "Invalid contract date: $dateText" }
  $date = "$($dateText.Substring(0,4))-$($dateText.Substring(4,2))-$($dateText.Substring(6,2))"
  $area = [double]$Row.prvuseAr
  $py = [int][Math]::Floor(($area / 3.305785) + 0.5)
  $group = [int]([Math]::Floor($py / 10) * 10)
  $amountText = ([string]$Row.thingAmount) -replace '[^0-9-]', ''
  $price = [long]$amountText
  $floor = $null
  if (-not [string]::IsNullOrWhiteSpace([string]$Row.floorCo) -and [string]$Row.floorCo -ne '-') {
    $floor = [int]$Row.floorCo
  }
  $transactionId = ([string]$Row.sttemntNo).Trim()
  return [PSCustomObject][ordered]@{
    complexId = $ComplexId
    transactionId = $transactionId
    date = $date
    area = [Math]::Round($area, 4)
    py = $py
    group = $group
    price = $price
    floor = $floor
    kind = '아파트 매매'
    dealType = $(if ([string]::IsNullOrWhiteSpace([string]$Row.brkrAt)) { '-' } else { [string]$Row.brkrAt })
    broker = $(if ([string]::IsNullOrWhiteSpace([string]$Row.brkrLedNm)) { '-' } else { [string]$Row.brkrLedNm })
    registration = $(if ([string]::IsNullOrWhiteSpace([string]$Row.rgistDe)) { '-' } else { [string]$Row.rgistDe })
    source = '국토교통부 실거래가 공개시스템'
  }
}

function Copy-PropertiesToOrderedMap {
  param($Object)
  $map = [ordered]@{}
  foreach ($property in $Object.PSObject.Properties) { $map[$property.Name] = $property.Value }
  return $map
}

function Get-RecordKey {
  param($Record)
  $statementId = ([string]$Record.transactionId).Trim()
  if ($statementId) { return "$($Record.complexId)|id|$statementId" }
  return "$($Record.complexId)|fallback|$($Record.date)|$($Record.area)|$($Record.price)|$($Record.floor)"
}

function Get-RecordSignature {
  param($Record)
  return ([ordered]@{
    complexId = $Record.complexId
    transactionId = $Record.transactionId
    date = $Record.date
    area = $Record.area
    py = $Record.py
    group = $Record.group
    price = $Record.price
    floor = $Record.floor
    kind = $Record.kind
    dealType = $Record.dealType
    broker = $Record.broker
    registration = $Record.registration
    source = $Record.source
  } | ConvertTo-Json -Compress)
}

function Get-ComplexStats {
  param($Rows, $Complex, $RefreshYears)
  $rowArray = @($Rows | Where-Object { $null -ne $_ -and ([string]$_.date).Length -ge 4 })
  $groups = [ordered]@{}
  foreach ($groupInfo in ($rowArray | Group-Object group | Sort-Object { [int]$_.Name })) {
    $groups[[string]$groupInfo.Name] = $groupInfo.Count
  }
  $dates = @($rowArray | ForEach-Object { [string]$_.date } | Sort-Object)
  $cancelledTotal = 0
  foreach ($yearProperty in $RefreshYears.PSObject.Properties) {
    $cancelledTotal += [int]$yearProperty.Value.cancelledExcluded
  }
  return [ordered]@{
    valid = $rowArray.Count
    cancelled = [int]$(if ($Complex.stats.cancelled) { $Complex.stats.cancelled } else { 0 })
    recentCancelled = $cancelledTotal
    firstDate = $(if ($dates.Count) { $dates[0] } else { $null })
    lastDate = $(if ($dates.Count) { $dates[-1] } else { $null })
    years = @($rowArray | ForEach-Object { ([string]$_.date).Substring(0,4) } | Sort-Object -Unique).Count
    groups = $groups
  }
}

function Assert-Dataset {
  param($Before, $After, [string[]]$RefreshYearStrings, [int]$ExpectedRecordCount)
  if (@($After.complexes).Count -ne @($Before.complexes).Count) { throw 'Validation failed: complex count changed.' }
  if (@($After.records).Count -ne $ExpectedRecordCount) { throw 'Validation failed: record count does not match generated output.' }
  if (-not $ComplexIds -and $Limit -le 0 -and @($After.complexes).Count -ne 134) {
    throw "Validation failed: expected 134 complexes, got $(@($After.complexes).Count)."
  }

  $complexSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($complex in @($After.complexes)) { [void]$complexSet.Add([string]$complex.id) }
  $statementSet = New-Object 'System.Collections.Generic.HashSet[string]'
  $today = (Get-KoreaNow).Date
  foreach ($record in @($After.records)) {
    if (-not $complexSet.Contains([string]$record.complexId)) { throw "Validation failed: unknown complexId $($record.complexId)." }
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact([string]$record.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
      throw "Validation failed: invalid date $($record.date)."
    }
    if ($parsedDate.Year -lt 2015 -or $parsedDate.Date -gt $today) { throw "Validation failed: out-of-range date $($record.date)." }
    if ([double]$record.area -le 0) { throw 'Validation failed: area must be positive.' }
    if ([long]$record.price -le 0) { throw 'Validation failed: price must be positive.' }
    $statementId = ([string]$record.transactionId).Trim()
    if ($statementId) {
      $key = "$($record.complexId)|$statementId"
      if (-not $statementSet.Add($key)) { throw "Validation failed: duplicate transaction id $key." }
    }
  }

  $beforeRecent = @($Before.records | Where-Object { $RefreshYearStrings -contains ([string]$_.date).Substring(0,4) }).Count
  $afterRecent = @($After.records | Where-Object { $RefreshYearStrings -contains ([string]$_.date).Substring(0,4) }).Count
  if ($beforeRecent -gt 0 -and $afterRecent -lt [Math]::Floor($beforeRecent * 0.7)) {
    throw "Validation failed: recent records dropped unexpectedly ($beforeRecent -> $afterRecent)."
  }
}

$runLog = [ordered]@{
  status = 'running'
  startedAt = $startedAt.ToString('o')
  sourceUrl = $MolitDetailUrl
  dataFile = $dataFile
  years = @()
  complexesRequested = 0
  pairsRequested = 0
  pairsCompleted = 0
  validDownloaded = 0
  cancelledExcluded = 0
  recordsBefore = 0
  recordsAfter = 0
  duplicateStatementIdsSkipped = 0
  newTransactions = 0
  cancelledOrRemoved = 0
  correctedTransactions = 0
  cancelledOrCorrected = 0
  latestContractDate = $null
  dataChanged = $false
}

try {
  if (-not (Test-Path -LiteralPath $dataFile)) { throw "Data file not found: $dataFile" }
  $lockStream = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

  $text = [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8)
  $json = $text -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', ''
  $dataset = $json | ConvertFrom-Json
  if (-not $dataset.complexes -or -not $dataset.records) { throw 'Unable to parse apartment dataset.' }

  $today = Get-KoreaNow
  if (-not $Years -or $Years.Count -eq 0) { $Years = @(($today.Year - 1), $today.Year) }
  $Years = @($Years | Where-Object { $_ -ge 2015 -and $_ -le $today.Year } | Sort-Object -Unique)
  if ($Years.Count -ne 2 -or $Years[0] -ne ($today.Year - 1) -or $Years[1] -ne $today.Year) {
    throw "The refresh must cover the current and previous years: $($today.Year - 1), $($today.Year)."
  }
  $yearStrings = @($Years | ForEach-Object { [string]$_ })

  $complexesToUpdate = @($dataset.complexes)
  if ($ComplexIds -and $ComplexIds.Count -gt 0) {
    $complexesToUpdate = @($complexesToUpdate | Where-Object { $ComplexIds -contains [string]$_.id })
    if (-not $complexesToUpdate.Count) { throw 'No requested complex IDs exist in the dataset.' }
  }
  if ($Limit -gt 0) { $complexesToUpdate = @($complexesToUpdate | Select-Object -First $Limit) }
  $runLog.years = $Years
  $runLog.complexesRequested = $complexesToUpdate.Count
  $runLog.pairsRequested = $complexesToUpdate.Count * $Years.Count
  $runLog.recordsBefore = @($dataset.records).Count

  Start-MolitBrowser
  $replacementRows = New-Object System.Collections.ArrayList
  $replacementPairs = New-Object 'System.Collections.Generic.HashSet[string]'
  $refreshByComplex = @{}
  $pairIndex = 0
  $pairTotal = $runLog.pairsRequested

  foreach ($complex in $complexesToUpdate) {
    $complexCode = ([string]$complex.id).Split('-')[-1]
    $yearMap = [ordered]@{}
    foreach ($year in $Years) {
      $pairIndex++
      Write-Host ("[{0}/{1}] {2} - {3}" -f $pairIndex, $pairTotal, $complex.name, $year)
      $data = Get-MolitYearWithRetry -ComplexCode $complexCode -Year $year
      $rawRows = @($data.danjiList | Where-Object { $null -ne $_ })
      $validRows = @($rawRows | Where-Object { [string]$_.dspsSecd -ne 'Y' })
      $cancelledRows = @($rawRows | Where-Object { [string]$_.dspsSecd -eq 'Y' })
      $seenIds = New-Object 'System.Collections.Generic.HashSet[string]'
      $yearValidCount = 0
      foreach ($row in $validRows) {
        $statementId = ([string]$row.sttemntNo).Trim()
        $dedupeKey = if ($statementId) { $statementId } else { "$($row.cntrctDe)|$($row.prvuseAr)|$($row.thingAmount)|$($row.floorCo)" }
        if (-not $seenIds.Add($dedupeKey)) {
          $runLog.duplicateStatementIdsSkipped++
          continue
        }
        [void]$replacementRows.Add((Convert-MolitRow -Row $row -ComplexId $complex.id))
        $yearValidCount++
      }
      [void]$replacementPairs.Add("$($complex.id)|$year")
      $yearMap[[string]$year] = [ordered]@{ valid = $yearValidCount; cancelledExcluded = $cancelledRows.Count }
      $runLog.validDownloaded += $yearValidCount
      $runLog.cancelledExcluded += $cancelledRows.Count
      $runLog.pairsCompleted++
      if ($RequestDelayMs -gt 0 -and $pairIndex -lt $pairTotal) { Start-Sleep -Milliseconds $RequestDelayMs }
    }
    $refreshByComplex[[string]$complex.id] = $yearMap
  }

  if ($runLog.pairsCompleted -ne $runLog.pairsRequested) { throw 'Validation failed: not all complex-year requests completed.' }
  if ($runLog.validDownloaded -le 0) { throw 'Validation failed: MOLIT returned zero valid transactions.' }

  if ($Probe) {
    $runLog.status = 'probe-success'
    $runLog.recordsAfter = $runLog.recordsBefore
    Write-UpdateLog -Values $runLog
    Write-Host ("Probe succeeded: {0} valid, {1} cancelled. Data file unchanged." -f $runLog.validDownloaded, $runLog.cancelledExcluded)
    return
  }

  $oldRefreshRows = @($dataset.records | Where-Object {
    ([string]$_.date).Length -ge 4 -and $replacementPairs.Contains("$($_.complexId)|$(([string]$_.date).Substring(0,4))")
  })
  $oldMap = @{}
  foreach ($record in $oldRefreshRows) { $oldMap[(Get-RecordKey -Record $record)] = $record }
  $newMap = @{}
  foreach ($record in @($replacementRows)) { $newMap[(Get-RecordKey -Record $record)] = $record }

  $newCount = 0
  $removedCount = 0
  $correctedCount = 0
  foreach ($key in $newMap.Keys) {
    if (-not $oldMap.ContainsKey($key)) { $newCount++ }
    elseif ((Get-RecordSignature $oldMap[$key]) -ne (Get-RecordSignature $newMap[$key])) { $correctedCount++ }
  }
  foreach ($key in $oldMap.Keys) { if (-not $newMap.ContainsKey($key)) { $removedCount++ } }

  $oldRefreshLines = New-Object System.Collections.ArrayList
  $newRefreshLines = New-Object System.Collections.ArrayList
  foreach ($complex in @($complexesToUpdate | Sort-Object id)) {
    foreach ($year in $Years) {
      $oldYear = $null
      if ($complex.refresh -and $complex.refresh.years) { $oldYear = $complex.refresh.years.PSObject.Properties[[string]$year].Value }
      [void]$oldRefreshLines.Add(("{0}|{1}|{2}|{3}" -f $complex.id, $year, [int]$oldYear.valid, [int]$oldYear.cancelledExcluded))
      $newYear = $refreshByComplex[[string]$complex.id][[string]$year]
      [void]$newRefreshLines.Add(("{0}|{1}|{2}|{3}" -f $complex.id, $year, [int]$newYear.valid, [int]$newYear.cancelledExcluded))
    }
  }
  $refreshCountsChanged = (($oldRefreshLines -join "`n") -ne ($newRefreshLines -join "`n"))
  $dataChanged = ($newCount -gt 0 -or $removedCount -gt 0 -or $correctedCount -gt 0 -or $refreshCountsChanged)

  $latestBefore = @($dataset.records | ForEach-Object { [string]$_.date } | Sort-Object | Select-Object -Last 1)
  $runLog.newTransactions = $newCount
  $runLog.cancelledOrRemoved = $removedCount
  $runLog.correctedTransactions = $correctedCount
  $runLog.cancelledOrCorrected = $removedCount + $correctedCount
  $runLog.dataChanged = $dataChanged

  if (-not $dataChanged) {
    $runLog.status = 'success-no-change'
    $runLog.recordsAfter = $runLog.recordsBefore
    $runLog.latestContractDate = $(if ($latestBefore.Count) { $latestBefore[0] } else { $null })
    Write-UpdateLog -Values $runLog
    Write-Host ("No transaction changes. Valid {0}, cancelled {1}, latest {2}." -f $runLog.validDownloaded, $runLog.cancelledExcluded, $runLog.latestContractDate)
    return
  }

  $keptRows = New-Object System.Collections.ArrayList
  foreach ($record in @($dataset.records)) {
    $recordYear = ([string]$record.date).Substring(0,4)
    if (-not $replacementPairs.Contains("$($record.complexId)|$recordYear")) { [void]$keptRows.Add($record) }
  }
  foreach ($record in $replacementRows) { [void]$keptRows.Add($record) }
  $sortedRows = @($keptRows | Sort-Object complexId, date, area, price, floor, transactionId)

  $rowsByComplex = @{}
  foreach ($recordGroup in ($sortedRows | Group-Object complexId)) { $rowsByComplex[$recordGroup.Name] = @($recordGroup.Group) }
  $completedAt = (Get-KoreaNow).ToString('o')
  $complexesOut = New-Object System.Collections.ArrayList
  foreach ($complex in @($dataset.complexes)) {
    $complexMap = Copy-PropertiesToOrderedMap $complex
    $existingYearMap = [ordered]@{}
    if ($complex.refresh -and $complex.refresh.years) {
      foreach ($property in $complex.refresh.years.PSObject.Properties) { $existingYearMap[$property.Name] = $property.Value }
    }
    if ($refreshByComplex.ContainsKey([string]$complex.id)) {
      foreach ($year in $Years) {
        $yearResult = $refreshByComplex[[string]$complex.id][[string]$year]
        $existingYearMap[[string]$year] = [ordered]@{
          valid = [int]$yearResult.valid
          cancelledExcluded = [int]$yearResult.cancelledExcluded
          refreshedAt = $completedAt
        }
      }
      $complexMap['refresh'] = [ordered]@{
        lastSuccess = $completedAt
        sourceUrl = $MolitDetailUrl
        method = 'yearly full replacement'
        years = $existingYearMap
      }
    }
    $yearMapObject = [PSCustomObject]$existingYearMap
    $complexRows = if ($rowsByComplex.ContainsKey([string]$complex.id)) { $rowsByComplex[[string]$complex.id] } else { @() }
    $complexMap['stats'] = Get-ComplexStats -Rows $complexRows -Complex $complex -RefreshYears $yearMapObject
    [void]$complexesOut.Add($complexMap)
  }

  $metaMap = Copy-PropertiesToOrderedMap $dataset.meta
  $latestDate = @($sortedRows | ForEach-Object { [string]$_.date } | Sort-Object | Select-Object -Last 1)
  $metaMap['rangeEnd'] = $(if ($latestDate.Count) { $latestDate[0] } else { $today.ToString('yyyy-MM-dd') })
  $metaMap['generatedAt'] = $today.ToString('yyyy-MM-dd')
  $metaMap['recordCount'] = $sortedRows.Count
  $metaMap['lastRefresh'] = [ordered]@{
    completedAt = $completedAt
    years = $Years
    complexes = $complexesToUpdate.Count
    validDownloaded = $runLog.validDownloaded
    cancelledExcluded = $runLog.cancelledExcluded
    sourceUrl = $MolitDetailUrl
    method = 'current and previous years full replacement'
  }

  $output = [ordered]@{ meta = $metaMap; complexes = $complexesOut; records = $sortedRows }
  $outputJson = $output | ConvertTo-Json -Depth 24 -Compress
  $outputText = "window.APT_ARCHIVE_DATA = $outputJson;" + [Environment]::NewLine
  $temporaryFile = $dataFile + '.tmp'
  [IO.File]::WriteAllText($temporaryFile, $outputText, $Utf8NoBom)

  $verificationText = [IO.File]::ReadAllText($temporaryFile, [Text.Encoding]::UTF8)
  $verificationJson = $verificationText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', ''
  $verification = $verificationJson | ConvertFrom-Json
  Assert-Dataset -Before $dataset -After $verification -RefreshYearStrings $yearStrings -ExpectedRecordCount $sortedRows.Count

  $backupDirectory = Split-Path -Parent $backupFile
  if (-not (Test-Path -LiteralPath $backupDirectory)) { [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null }
  Copy-Item -LiteralPath $dataFile -Destination $backupFile -Force
  Move-Item -LiteralPath $temporaryFile -Destination $dataFile -Force
  $temporaryFile = $null

  $runLog.status = 'success-changed'
  $runLog.recordsAfter = $sortedRows.Count
  $runLog.latestContractDate = $(if ($latestDate.Count) { $latestDate[0] } else { $null })
  Write-UpdateLog -Values $runLog
  Write-Host ("Update succeeded: {0} -> {1}; new {2}; cancelled/corrected {3}; latest {4}." -f $runLog.recordsBefore, $runLog.recordsAfter, $runLog.newTransactions, $runLog.cancelledOrCorrected, $runLog.latestContractDate)
} catch {
  $runLog.status = 'failed'
  $runLog.error = $_.Exception.Message
  Write-UpdateLog -Values $runLog
  throw
} finally {
  if ($browserSocket) { $browserSocket.Dispose() }
  if ($browserProcess -and -not $browserProcess.HasExited) { Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue }
  if ($lockStream) { $lockStream.Dispose() }
  if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
  if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue }
  if ($browserProfile) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedProfile = [IO.Path]::GetFullPath($browserProfile)
    if ($resolvedProfile.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedProfile) -like 'apt-price-updater-*') {
      Remove-Item -LiteralPath $resolvedProfile -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
