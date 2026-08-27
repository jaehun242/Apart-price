[CmdletBinding()]
param(
  [string]$DataPath = 'public\data\transactions.js',
  [string]$ApiKey = $env:MOLIT_API_KEY,
  [string]$ApiEndpoint = 'https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev',
  [ValidateRange(3, 6)][int]$RefreshMonths = 6,
  [int]$RequestDelayMs = 150,
  [ValidateRange(5, 60)][int]$RequestTimeoutSec = 40,
  [ValidateRange(1, 5)][int]$MaxRetries = 3,
  [int]$Limit = 0,
  [string[]]$ComplexIds,
  [string]$LogPath = '',
  [string]$BackupPath = '',
  [string]$MatchReportPath = 'reports\molit-openapi-matching.md',
  [switch]$Probe
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryDirectory = Split-Path -Parent $scriptDirectory
. (Join-Path $scriptDirectory 'transaction-first-seen.ps1')
$lockStream = $null
$temporaryFile = $null

function Get-KoreaNow {
  foreach ($zoneId in @('Korea Standard Time', 'Asia/Seoul')) {
    try { return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById($zoneId)) }
    catch { }
  }
  throw 'Korea time zone is unavailable.'
}

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string]$Path, [string]$BasePath = $repositoryDirectory)
  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Copy-PropertiesToOrderedMap {
  param($Object)
  $map = [ordered]@{}
  foreach ($property in $Object.PSObject.Properties) { $map[$property.Name] = $property.Value }
  return $map
}

function Get-Field {
  param($Row, [Parameter(Mandatory = $true)][string[]]$Names)
  foreach ($name in $Names) {
    $property = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($property -and $null -ne $property.Value) { return ([string]$property.Value).Trim() }
  }
  return ''
}

function Convert-XmlItem {
  param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][string]$LawdCode, [Parameter(Mandatory = $true)][string]$DealYmd)
  $map = [ordered]@{}
  foreach ($child in @($Item.ChildNodes)) {
    if ($child.NodeType -eq [Xml.XmlNodeType]::Element) { $map[$child.Name] = [string]$child.InnerText }
  }
  $map['_lawdCode'] = $LawdCode
  $map['_dealYmd'] = $DealYmd
  return [PSCustomObject]$map
}

function Normalize-ApartmentName {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $value = $Name.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
  $value = $value -replace 'i\s*[- ]?\s*park', '아이파크'
  $value = $value -replace 'sk\s*view', '에스케이뷰'
  $value = $value -replace '아파트$', ''
  return ($value -replace '[^0-9a-z가-힣]', '')
}

function Get-ComplexNameAliases {
  param($Complex)
  $values = New-Object System.Collections.Generic.List[string]
  foreach ($name in @([string]$Complex.name, [string]$Complex.displayName)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $values.Add($name)
    $values.Add(($name -replace '\([^)]*\)', ''))
  }
  return @($values | ForEach-Object { Normalize-ApartmentName $_ } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-OpenApiIdentity {
  param($Row)
  $lawdCode = Get-Field $Row @('_lawdCode', 'sggCd')
  $aptSeq = Get-Field $Row @('aptSeq')
  if ($aptSeq) { return "$lawdCode|seq|$aptSeq" }
  $aptName = Normalize-ApartmentName (Get-Field $Row @('aptNm'))
  $legalDong = Normalize-ApartmentName (Get-Field $Row @('umdNm'))
  $jibun = (Get-Field $Row @('jibun')) -replace '\s', ''
  return "$lawdCode|address|$aptName|$legalDong|$jibun"
}

function Get-OpenApiDate {
  param($Row)
  $year = Get-Field $Row @('dealYear')
  $month = Get-Field $Row @('dealMonth')
  $day = Get-Field $Row @('dealDay')
  if ($year -notmatch '^\d{4}$' -or $month -notmatch '^\d{1,2}$' -or $day -notmatch '^\d{1,2}$') { throw "Invalid OpenAPI contract date: $year-$month-$day" }
  return ('{0}-{1:D2}-{2:D2}' -f [int]$year, [int]$month, [int]$day)
}

function Get-OpenApiArea {
  param($Row)
  $text = Get-Field $Row @('excluUseAr')
  $value = 0.0
  if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -le 0) { throw "Invalid OpenAPI exclusive area: $text" }
  return [Math]::Round($value, 4)
}

function Get-OpenApiPrice {
  param($Row)
  $text = (Get-Field $Row @('dealAmount')) -replace '[^0-9-]', ''
  $value = 0L
  if (-not [long]::TryParse($text, [ref]$value) -or $value -le 0) { throw "Invalid OpenAPI deal amount: $text" }
  return $value
}

function Get-OpenApiFloor {
  param($Row)
  $text = Get-Field $Row @('floor')
  if ([string]::IsNullOrWhiteSpace($text) -or $text -eq '-') { return $null }
  $value = 0
  if (-not [int]::TryParse($text, [ref]$value)) { throw "Invalid OpenAPI floor: $text" }
  return $value
}

function Test-OpenApiCancelled {
  param($Row)
  $cancelDay = Get-Field $Row @('cdealDay')
  $cancelType = Get-Field $Row @('cdealType')
  return (-not [string]::IsNullOrWhiteSpace($cancelDay)) -or ($cancelType -match '^(O|Y|1|해제|취소)$')
}

function Get-Sha256Text {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()) }
  finally { $sha.Dispose() }
}

function Protect-ApiKey {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($ApiKey)) { return $Message }
  $protected = [string]$Message
  $forms = New-Object System.Collections.Generic.List[string]
  $forms.Add([string]$ApiKey)
  try { $forms.Add([Uri]::EscapeDataString([string]$ApiKey)) } catch { }
  try { $forms.Add([Uri]::UnescapeDataString([string]$ApiKey)) } catch { }
  foreach ($form in @($forms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object Length -Descending -Unique)) {
    $protected = $protected -replace [regex]::Escape($form), '[REDACTED]'
  }
  return $protected
}

function Get-OpenApiTransactionSignature {
  param($Row)
  $floorValue = Get-OpenApiFloor $Row
  $parts = @(
    (Get-OpenApiIdentity $Row)
    (Get-OpenApiDate $Row)
    ((Get-OpenApiArea $Row).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture))
    (Get-OpenApiPrice $Row)
    $(if ($null -eq $floorValue) { '' } else { $floorValue })
    (Get-Field $Row @('aptDong'))
    (Get-Field $Row @('dealingGbn'))
    (Get-Field $Row @('estateAgentSggNm'))
    (Get-Field $Row @('rgstDate'))
    (Get-Field $Row @('buyerGbn'))
    (Get-Field $Row @('slerGbn'))
    (Get-Field $Row @('landLeaseholdGbn'))
  )
  return $parts -join '|'
}

function Get-ComparableSignature {
  param($Record)
  $area = [Math]::Round([double]$Record.area, 2).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
  $floor = if ($null -eq $Record.floor) { '' } else { [string]$Record.floor }
  return "$($Record.date)|$area|$($Record.price)|$floor"
}

function Get-ApiComparableSignature {
  param($Row)
  $area = [Math]::Round((Get-OpenApiArea $Row), 2).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
  $floorValue = Get-OpenApiFloor $Row
  $floor = if ($null -eq $floorValue) { '' } else { [string]$floorValue }
  return "$(Get-OpenApiDate $Row)|$area|$(Get-OpenApiPrice $Row)|$floor"
}

function Convert-OpenApiRow {
  param($Row, [Parameter(Mandatory = $true)][string]$ComplexId)
  $area = Get-OpenApiArea $Row
  $exclusivePy = $area / 3.305785
  $signature = Get-OpenApiTransactionSignature $Row
  return [PSCustomObject][ordered]@{
    complexId = $ComplexId
    transactionId = 'openapi-' + (Get-Sha256Text $signature).Substring(0, 24)
    date = Get-OpenApiDate $Row
    area = $area
    py = [Math]::Round($exclusivePy, 1, [MidpointRounding]::AwayFromZero)
    group = [int]([Math]::Floor(($exclusivePy + [double]::Epsilon) / 10) * 10)
    price = Get-OpenApiPrice $Row
    floor = Get-OpenApiFloor $Row
    kind = '아파트 매매'
    dealType = $(if (Get-Field $Row @('dealingGbn')) { Get-Field $Row @('dealingGbn') } else { '-' })
    broker = $(if (Get-Field $Row @('estateAgentSggNm')) { Get-Field $Row @('estateAgentSggNm') } else { '-' })
    registration = $(if (Get-Field $Row @('rgstDate')) { Get-Field $Row @('rgstDate') } else { '-' })
    apartmentDong = $(if (Get-Field $Row @('aptDong')) { Get-Field $Row @('aptDong') } else { '-' })
    tracking_key = $null
    first_seen_at = $null
    source = '국토교통부 실거래가 OpenAPI'
  }
}

function Get-ComplexStats {
  param($Rows, $Complex, [int]$RecentCancelled)
  $rowArray = @($Rows | Where-Object { $null -ne $_ -and ([string]$_.date).Length -ge 4 })
  $groups = [ordered]@{}
  foreach ($groupInfo in ($rowArray | Group-Object group | Sort-Object { [int]$_.Name })) { $groups[[string]$groupInfo.Name] = $groupInfo.Count }
  $dates = @($rowArray | ForEach-Object { [string]$_.date } | Sort-Object)
  return [ordered]@{
    valid = $rowArray.Count
    cancelled = [int]$(if ($Complex.stats.cancelled) { $Complex.stats.cancelled } else { 0 })
    recentCancelled = $RecentCancelled
    firstDate = $(if ($dates.Count) { $dates[0] } else { $null })
    lastDate = $(if ($dates.Count) { $dates[-1] } else { $null })
    years = @($rowArray | ForEach-Object { ([string]$_.date).Substring(0,4) } | Sort-Object -Unique).Count
    groups = $groups
  }
}

$startedAt = Get-KoreaNow
$dataFile = Resolve-AbsolutePath $DataPath
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path ([IO.Path]::GetTempPath()) 'apart-price-update-log.json' }
if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Join-Path ([IO.Path]::GetTempPath()) 'apart-price-transactions.previous.js' }
$logFile = Resolve-AbsolutePath $LogPath
$backupFile = Resolve-AbsolutePath $BackupPath
$matchReportFile = Resolve-AbsolutePath $MatchReportPath
$lockFile = $dataFile + '.update.lock'

$runLog = [ordered]@{
  status = 'running'; startedAt = $startedAt.ToString('o'); sourceUrl = $ApiEndpoint; apiKeyRecognized = $false
  refreshMonths = $RefreshMonths; refreshStart = $null; refreshEnd = $null; regionsRequested = 0
  basePairsRequested = 0; discoveryPairsRequested = 0; pairsRequested = 0; pairsCompleted = 0
  apiCalls = 0; apiAttempts = 0; complexesRequested = 0; complexesMatched = 0; unmatchedComplexes = @()
  validDownloaded = 0; cancelledExcluded = 0; duplicateRowsSkipped = 0; recordsBefore = 0; recordsAfter = 0
  newTransactions = 0; cancelledOrRemoved = 0; correctedTransactions = 0; cancelledOrCorrected = 0
  latestContractDate = $null; firstSeenFieldsInitialized = 0; dataChanged = $false
}

function Write-UpdateLog {
  param([System.Collections.IDictionary]$Values)
  try {
    $Values['finishedAt'] = (Get-KoreaNow).ToString('o')
    $directory = Split-Path -Parent $logFile
    if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    [IO.File]::WriteAllText($logFile, (($Values | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $Utf8NoBom)
  } catch { Write-Warning "Unable to write update log: $($_.Exception.Message)" }
}

function Invoke-OpenApiPage {
  param([Parameter(Mandatory = $true)][string]$LawdCode, [Parameter(Mandatory = $true)][string]$DealYmd, [int]$PageNo = 1)
  $encodedKey = if ($ApiKey -match '%[0-9A-Fa-f]{2}') { $ApiKey } else { [Uri]::EscapeDataString($ApiKey) }
  $uri = "${ApiEndpoint}?serviceKey=$encodedKey&LAWD_CD=$LawdCode&DEAL_YMD=$DealYmd&pageNo=$PageNo&numOfRows=9999"
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    $runLog.apiAttempts++
    try {
      $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $RequestTimeoutSec -UseBasicParsing
      $runLog.apiCalls++
      if ([int]$response.StatusCode -ne 200) { throw "HTTP $([int]$response.StatusCode)" }
      try { [xml]$xml = $response.Content } catch { throw "HTTP 200 invalid XML: $($_.Exception.Message)" }
      if ($xml.OpenAPI_ServiceResponse) {
        $reason = [string]$xml.OpenAPI_ServiceResponse.cmmMsgHeader.returnReason
        $code = [string]$xml.OpenAPI_ServiceResponse.cmmMsgHeader.returnAuthMsg
        $detail = [string]$xml.OpenAPI_ServiceResponse.cmmMsgHeader.errMsg
        throw "HTTP 200 OpenAPI authentication error: $code $reason $detail".Trim()
      }
      $resultCode = [string]$xml.response.header.resultCode
      $resultMessage = [string]$xml.response.header.resultMsg
      if ($resultCode -notin @('00', '000')) { throw "HTTP 200 OpenAPI result $resultCode`: $resultMessage" }
      $runLog.apiKeyRecognized = $true
      $rows = New-Object System.Collections.ArrayList
      foreach ($item in @($xml.response.body.items.item | Where-Object { $null -ne $_ })) { [void]$rows.Add((Convert-XmlItem -Item $item -LawdCode $LawdCode -DealYmd $DealYmd)) }
      $totalCount = 0
      [void][int]::TryParse([string]$xml.response.body.totalCount, [ref]$totalCount)
      return [PSCustomObject]@{ Rows = @($rows); TotalCount = $totalCount; StatusCode = 200 }
    } catch {
      $lastError = $_.Exception
      $statusText = 'network'
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $statusText = [string][int]$_.Exception.Response.StatusCode }
      $message = Protect-ApiKey $lastError.Message
      if ($attempt -lt $MaxRetries) {
        $pauseSeconds = @(3, 10, 20)[[Math]::Min($attempt - 1, 2)]
        Write-Warning "OpenAPI retry $attempt/$MaxRetries ($LawdCode, $DealYmd, page $PageNo, HTTP $statusText): $message"
        Start-Sleep -Seconds $pauseSeconds
      }
    }
  }
  $finalMessage = Protect-ApiKey $lastError.Message
  throw "OpenAPI request failed after $MaxRetries attempts ($LawdCode, $DealYmd, page $PageNo): $finalMessage"
}

function Get-OpenApiPair {
  param([Parameter(Mandatory = $true)][string]$LawdCode, [Parameter(Mandatory = $true)][string]$DealYmd)
  $rows = New-Object System.Collections.ArrayList
  $pageNo = 1
  do {
    $page = Invoke-OpenApiPage -LawdCode $LawdCode -DealYmd $DealYmd -PageNo $pageNo
    $pageRows = @($page.Rows)
    if ($pageRows.Count -eq 0 -and $rows.Count -lt $page.TotalCount) {
      throw "OpenAPI pagination returned no rows before totalCount was reached ($LawdCode, $DealYmd, page $pageNo, $($rows.Count)/$($page.TotalCount))."
    }
    foreach ($row in $pageRows) { [void]$rows.Add($row) }
    $pageNo++
    if ($pageNo -gt 1000) { throw "OpenAPI pagination exceeded 1000 pages ($LawdCode, $DealYmd)." }
    if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds $RequestDelayMs }
  } while ($rows.Count -lt $page.TotalCount)
  return @($rows)
}

$script:pairCache = @{}
function Ensure-OpenApiPair {
  param([Parameter(Mandatory = $true)][string]$LawdCode, [Parameter(Mandatory = $true)][string]$DealYmd, [switch]$Discovery)
  $key = "$LawdCode|$DealYmd"
  if ($script:pairCache.ContainsKey($key)) { return }
  if ($Discovery) { $runLog.discoveryPairsRequested++ }
  $runLog.pairsRequested++
  Write-Host ("[{0}] OpenAPI {1} {2}{3}" -f $runLog.pairsRequested, $LawdCode, $DealYmd, $(if ($Discovery) { ' (matching discovery)' } else { '' }))
  $script:pairCache[$key] = @(Get-OpenApiPair -LawdCode $LawdCode -DealYmd $DealYmd)
  $runLog.pairsCompleted++
}

function Get-ApiGroups {
  $groups = @{}
  foreach ($pairRows in $script:pairCache.Values) {
    foreach ($row in @($pairRows)) {
      $identity = Get-OpenApiIdentity $row
      if (-not $groups.ContainsKey($identity)) { $groups[$identity] = New-Object System.Collections.ArrayList }
      [void]$groups[$identity].Add($row)
    }
  }
  return $groups
}

function Get-CandidateScore {
  param($Complex, $Rows, $ExistingRows)
  $aliases = @(Get-ComplexNameAliases $Complex)
  $first = @($Rows)[0]
  $apiName = Normalize-ApartmentName (Get-Field $first @('aptNm'))
  $nameMatch = $aliases -contains $apiName
  $existingSignatures = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($record in @($ExistingRows)) { [void]$existingSignatures.Add((Get-ComparableSignature $record)) }
  $signatureMatches = 0
  foreach ($row in @($Rows | Where-Object { -not (Test-OpenApiCancelled $_) })) { if ($existingSignatures.Contains((Get-ApiComparableSignature $row))) { $signatureMatches++ } }
  $existingAreas = @($ExistingRows | ForEach-Object { [double]$_.area } | Sort-Object -Unique)
  $apiAreas = @($Rows | ForEach-Object { Get-OpenApiArea $_ } | Sort-Object -Unique)
  $areaMatches = 0
  foreach ($area in $existingAreas) { if (@($apiAreas | Where-Object { [Math]::Abs($_ - $area) -le 0.05 }).Count) { $areaMatches++ } }
  return [PSCustomObject]@{ NameMatch = $nameMatch; SignatureMatches = $signatureMatches; AreaMatches = $areaMatches; ApiName = (Get-Field $first @('aptNm')) }
}

function Resolve-ComplexMapping {
  param($Complex, $Groups, $ExistingRows)
  $lawdCode = ([string]$Complex.id).Split('-')[1]
  if ($Complex.openApi -and $Complex.openApi.identityKey) { return [PSCustomObject]@{ Success = $true; Identity = [string]$Complex.openApi.identityKey; Method = 'cached-verified'; Score = $null; Reason = '' } }
  $candidates = New-Object System.Collections.ArrayList
  foreach ($entry in $Groups.GetEnumerator()) {
    if (-not $entry.Key.StartsWith("$lawdCode|", [StringComparison]::Ordinal)) { continue }
    $score = Get-CandidateScore -Complex $Complex -Rows @($entry.Value) -ExistingRows $ExistingRows
    [void]$candidates.Add([PSCustomObject]@{ Identity = $entry.Key; Rows = @($entry.Value); Score = $score })
  }
  $nameMatches = @($candidates | Where-Object { $_.Score.NameMatch })
  if ($nameMatches.Count -eq 1) { return [PSCustomObject]@{ Success = $true; Identity = $nameMatches[0].Identity; Method = 'unique-normalized-name'; Score = $nameMatches[0].Score; Reason = '' } }
  $pool = if ($nameMatches.Count -gt 1) { $nameMatches } else { @($candidates) }
  $ranked = @($pool | Sort-Object @{Expression={$_.Score.SignatureMatches};Descending=$true}, @{Expression={$_.Score.AreaMatches};Descending=$true})
  if ($ranked.Count -gt 0 -and $ranked[0].Score.SignatureMatches -gt 0) {
    $top = $ranked[0]
    $ties = @($ranked | Where-Object { $_.Score.SignatureMatches -eq $top.Score.SignatureMatches -and $_.Score.AreaMatches -eq $top.Score.AreaMatches })
    if ($ties.Count -eq 1) { return [PSCustomObject]@{ Success = $true; Identity = $top.Identity; Method = 'existing-transaction-signature'; Score = $top.Score; Reason = '' } }
  }
  $descriptions = @($pool | Select-Object -First 8 | ForEach-Object { "$($_.Score.ApiName) [signatures=$($_.Score.SignatureMatches), areas=$($_.Score.AreaMatches)]" })
  $reason = if ($nameMatches.Count -gt 1) { 'multiple same-name API candidates without a unique transaction match' } else { 'no unique API candidate matched by name or existing transaction signature' }
  return [PSCustomObject]@{ Success = $false; Identity = ''; Method = ''; Score = $null; Reason = "$reason; candidates: $($descriptions -join ', ')" }
}

function New-OpenApiMetadata {
  param($Complex, [string]$Identity, [string]$Method, $Groups)
  if (-not $Groups.ContainsKey($Identity)) {
    if ($Complex.openApi -and [string]$Complex.openApi.identityKey -eq $Identity) { return $Complex.openApi }
    throw "Matched OpenAPI identity has no source row: $Identity"
  }
  $row = @($Groups[$Identity])[0]
  return [PSCustomObject][ordered]@{
    lawdCode = Get-Field $row @('_lawdCode', 'sggCd'); identityKey = $Identity; aptSeq = Get-Field $row @('aptSeq')
    aptName = Get-Field $row @('aptNm'); legalDong = Get-Field $row @('umdNm'); jibun = Get-Field $row @('jibun')
    roadName = Get-Field $row @('roadNm'); matchedBy = $Method
  }
}

function Write-MatchReport {
  param($Rows, $Unmatched)
  $directory = Split-Path -Parent $matchReportFile
  if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# MOLIT OpenAPI 단지 매칭 보고서'); $lines.Add('')
  $lines.Add("- 공식 API: $ApiEndpoint"); $lines.Add("- 대상 단지: $($runLog.complexesRequested)개")
  $lines.Add("- 매칭 성공: $($runLog.complexesMatched)개"); $lines.Add("- 매칭 확인 필요: $(@($Unmatched).Count)개")
  $lines.Add("- 기본 호출 쌍: $($runLog.basePairsRequested)개 · 보조 매칭 호출 쌍: $($runLog.discoveryPairsRequested)개")
  $lines.Add(''); $lines.Add('| 프로젝트 단지 | 지역코드 | API 단지명 | 법정동 | 지번 | aptSeq | 매칭 근거 |'); $lines.Add('|---|---:|---|---|---|---|---|')
  foreach ($row in @($Rows | Sort-Object ComplexName)) { $lines.Add("| $($row.ComplexName) | $($row.LawdCode) | $($row.AptName) | $($row.LegalDong) | $($row.Jibun) | $($row.AptSeq) | $($row.Method) |") }
  if (@($Unmatched).Count) {
    $lines.Add(''); $lines.Add('## OpenAPI 매칭 확인 필요'); $lines.Add('')
    foreach ($item in @($Unmatched)) { $lines.Add("- $($item.Name) (`$($item.Id)`): $($item.Reason)") }
  }
  [IO.File]::WriteAllLines($matchReportFile, $lines, $Utf8NoBom)
}

function Assert-Dataset {
  param($Before, $After, [int]$ExpectedRecordCount, [int]$OldRefreshCount, [int]$NewRefreshCount)
  if (@($After.complexes).Count -ne @($Before.complexes).Count) { throw 'Validation failed: complex count changed.' }
  if (@($After.records).Count -ne $ExpectedRecordCount) { throw 'Validation failed: record count does not match generated output.' }
  $complexSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($complex in @($After.complexes)) { [void]$complexSet.Add([string]$complex.id) }
  $transactionSet = New-Object 'System.Collections.Generic.HashSet[string]'
  $today = (Get-KoreaNow).Date
  foreach ($record in @($After.records)) {
    if (-not $complexSet.Contains([string]$record.complexId)) { throw "Validation failed: unknown complexId $($record.complexId)." }
    $date = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact([string]$record.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { throw "Validation failed: invalid date $($record.date)." }
    if ($date.Year -lt 2015 -or $date.Date -gt $today) { throw "Validation failed: out-of-range date $($record.date)." }
    if ([double]$record.area -le 0 -or [long]$record.price -le 0) { throw 'Validation failed: area and price must be positive.' }
    $exclusivePy = [double]$record.area / 3.305785
    $expectedPy = [Math]::Round($exclusivePy, 1, [MidpointRounding]::AwayFromZero)
    $expectedGroup = [int]([Math]::Floor(($exclusivePy + [double]::Epsilon) / 10) * 10)
    if ([Math]::Abs(([double]$record.py - $expectedPy)) -gt 0.0001 -or [int]$record.group -ne $expectedGroup) { throw "Validation failed: exclusive-area conversion mismatch for $($record.complexId)." }
    $transactionId = ([string]$record.transactionId).Trim()
    if ($transactionId -and -not $transactionSet.Add("$($record.complexId)|$transactionId")) { throw "Validation failed: duplicate transaction id $($record.complexId)|$transactionId." }
    if (-not $record.PSObject.Properties['first_seen_at']) { throw "Validation failed: missing first_seen_at for $($record.complexId)." }
    $firstSeenText = ([string]$record.first_seen_at).Trim()
    if ($firstSeenText) {
      $firstSeen = [DateTime]::MinValue
      if (-not [DateTime]::TryParseExact($firstSeenText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$firstSeen)) { throw "Validation failed: invalid first_seen_at $firstSeenText." }
      if ($firstSeen.Date -gt $today) { throw "Validation failed: future first_seen_at $firstSeenText." }
    }
  }
  if ($OldRefreshCount -ge 20 -and $NewRefreshCount -lt [Math]::Floor($OldRefreshCount * 0.65)) { throw "Validation failed: rolling-window records dropped unexpectedly ($OldRefreshCount -> $NewRefreshCount)." }
}

try {
  if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'MOLIT_API_KEY is not configured.' }
  if (-not (Test-Path -LiteralPath $dataFile)) { throw "Data file not found: $dataFile" }
  $lockStream = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $text = [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8)
  $json = $text -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', ''
  $dataset = $json | ConvertFrom-Json
  if (-not $dataset.complexes -or -not $dataset.records) { throw 'Unable to parse apartment dataset.' }
  $firstSeenFieldsInitialized = Initialize-FirstSeenFields -Records $dataset.records
  $runLog.firstSeenFieldsInitialized = $firstSeenFieldsInitialized

  $today = Get-KoreaNow
  $currentMonth = [DateTime]::new($today.Year, $today.Month, 1)
  $monthStarts = @(0..($RefreshMonths - 1) | ForEach-Object { $currentMonth.AddMonths(-$_) } | Sort-Object)
  $dealMonths = @($monthStarts | ForEach-Object { $_.ToString('yyyyMM') })
  $refreshStart = $monthStarts[0].ToString('yyyy-MM-dd'); $refreshEnd = $today.ToString('yyyy-MM-dd')
  $runLog.refreshStart = $refreshStart; $runLog.refreshEnd = $refreshEnd

  $complexesToUpdate = @($dataset.complexes)
  if ($ComplexIds -and $ComplexIds.Count) {
    $complexesToUpdate = @($complexesToUpdate | Where-Object { $ComplexIds -contains [string]$_.id })
    if (-not $complexesToUpdate.Count) { throw 'No requested complex IDs exist in the dataset.' }
  }
  if ($Limit -gt 0) { $complexesToUpdate = @($complexesToUpdate | Select-Object -First $Limit) }
  $runLog.complexesRequested = $complexesToUpdate.Count; $runLog.recordsBefore = @($dataset.records).Count
  $lawdCodes = @($complexesToUpdate | ForEach-Object { ([string]$_.id).Split('-')[1] } | Sort-Object -Unique)
  $runLog.regionsRequested = $lawdCodes.Count; $runLog.basePairsRequested = $lawdCodes.Count * $dealMonths.Count
  foreach ($lawdCode in $lawdCodes) { foreach ($dealMonth in $dealMonths) { Ensure-OpenApiPair -LawdCode $lawdCode -DealYmd $dealMonth } }

  $groups = Get-ApiGroups
  $existingActualByComplex = @{}
  foreach ($complex in $complexesToUpdate) { $existingActualByComplex[[string]$complex.id] = @($dataset.records | Where-Object { $_.complexId -eq $complex.id -and $_.kind -eq '아파트 매매' }) }
  $needsDiscovery = New-Object System.Collections.ArrayList
  foreach ($complex in $complexesToUpdate) {
    $result = Resolve-ComplexMapping -Complex $complex -Groups $groups -ExistingRows $existingActualByComplex[[string]$complex.id]
    if (-not $result.Success) { [void]$needsDiscovery.Add($complex) }
  }
  foreach ($complex in @($needsDiscovery)) {
    $latest = @($existingActualByComplex[[string]$complex.id] | Sort-Object date | Select-Object -Last 1)
    if ($latest.Count) {
      $lawdCode = ([string]$complex.id).Split('-')[1]
      $dealMonth = ([string]$latest[0].date).Substring(0, 7) -replace '-', ''
      Ensure-OpenApiPair -LawdCode $lawdCode -DealYmd $dealMonth -Discovery
    }
  }
  if ($needsDiscovery.Count) { $groups = Get-ApiGroups }

  $mappingByComplex = @{}; $matchRows = New-Object System.Collections.ArrayList; $unmatched = New-Object System.Collections.ArrayList
  foreach ($complex in $complexesToUpdate) {
    $result = Resolve-ComplexMapping -Complex $complex -Groups $groups -ExistingRows $existingActualByComplex[[string]$complex.id]
    if (-not $result.Success) { [void]$unmatched.Add([PSCustomObject]@{ Id = [string]$complex.id; Name = [string]$complex.name; Reason = $result.Reason }); continue }
    $metadata = New-OpenApiMetadata -Complex $complex -Identity $result.Identity -Method $result.Method -Groups $groups
    $mappingByComplex[[string]$complex.id] = $metadata
    [void]$matchRows.Add([PSCustomObject]@{ ComplexName = [string]$complex.name; LawdCode = $metadata.lawdCode; AptName = $metadata.aptName; LegalDong = $metadata.legalDong; Jibun = $metadata.jibun; AptSeq = $metadata.aptSeq; Method = $metadata.matchedBy })
  }
  $identityOwners = @{}
  foreach ($entry in $mappingByComplex.GetEnumerator()) {
    $identity = [string]$entry.Value.identityKey
    if ($identityOwners.ContainsKey($identity)) { [void]$unmatched.Add([PSCustomObject]@{ Id = $entry.Key; Name = $entry.Key; Reason = "API identity also matched $($identityOwners[$identity]): $identity" }) }
    else { $identityOwners[$identity] = $entry.Key }
  }
  $runLog.complexesMatched = $mappingByComplex.Count - @($unmatched).Count; $runLog.unmatchedComplexes = @($unmatched)
  Write-MatchReport -Rows $matchRows -Unmatched $unmatched
  if ($unmatched.Count -gt 0 -or $runLog.complexesMatched -ne $runLog.complexesRequested) { throw "OpenAPI complex matching failed for $($unmatched.Count) complexes. See $matchReportFile" }

  $replacementRows = New-Object System.Collections.ArrayList; $refreshStats = @{}
  foreach ($complex in $complexesToUpdate) {
    $metadata = $mappingByComplex[[string]$complex.id]; $seen = New-Object 'System.Collections.Generic.HashSet[string]'; $valid = 0; $cancelled = 0
    foreach ($dealMonth in $dealMonths) {
      $lawdCode = ([string]$complex.id).Split('-')[1]
      foreach ($row in @($script:pairCache["$lawdCode|$dealMonth"] | Where-Object { (Get-OpenApiIdentity $_) -eq [string]$metadata.identityKey })) {
        if (Test-OpenApiCancelled $row) { $cancelled++; continue }
        $signature = Get-OpenApiTransactionSignature $row
        if (-not $seen.Add($signature)) { $runLog.duplicateRowsSkipped++; continue }
        [void]$replacementRows.Add((Convert-OpenApiRow -Row $row -ComplexId ([string]$complex.id))); $valid++
      }
    }
    $refreshStats[[string]$complex.id] = [PSCustomObject]@{ Valid = $valid; Cancelled = $cancelled }
    $runLog.validDownloaded += $valid; $runLog.cancelledExcluded += $cancelled
  }
  if ($runLog.pairsCompleted -ne $runLog.pairsRequested) { throw 'Validation failed: not all OpenAPI requests completed.' }
  if (-not $runLog.apiKeyRecognized -or $runLog.validDownloaded -le 0) { throw 'Validation failed: OpenAPI key was not recognized or returned zero matched transactions.' }

  $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($complex in $complexesToUpdate) { [void]$selectedSet.Add([string]$complex.id) }
  $oldRefreshRows = @($dataset.records | Where-Object { $selectedSet.Contains([string]$_.complexId) -and $_.kind -eq '아파트 매매' -and [string]$_.date -ge $refreshStart -and [string]$_.date -le $refreshEnd })
  $trackingResult = Sync-FirstSeenForTransactions -ExistingRows $oldRefreshRows -IncomingRows @($replacementRows) -SeenDate $today.ToString('yyyy-MM-dd')
  $replacementRows = @($trackingResult.Rows)
  $newCount = [int]$trackingResult.NewCount; $removedCount = [int]$trackingResult.RemovedCount; $correctedCount = [int]$trackingResult.CorrectedCount
  $mappingChanged = $false
  foreach ($complex in $complexesToUpdate) {
    $oldMetadata = if ($complex.openApi) { $complex.openApi | ConvertTo-Json -Compress } else { '' }
    $newMetadata = $mappingByComplex[[string]$complex.id] | ConvertTo-Json -Compress
    if ($oldMetadata -ne $newMetadata) { $mappingChanged = $true; break }
  }
  $sourceMigration = ([string]$dataset.meta.lastRefresh.sourceUrl -ne $ApiEndpoint)
  $dataChanged = ($newCount -gt 0 -or $removedCount -gt 0 -or $correctedCount -gt 0 -or $mappingChanged -or $sourceMigration -or $firstSeenFieldsInitialized -gt 0)
  $runLog.newTransactions = $newCount; $runLog.cancelledOrRemoved = $removedCount; $runLog.correctedTransactions = $correctedCount
  $runLog.cancelledOrCorrected = $removedCount + $correctedCount; $runLog.dataChanged = $dataChanged
  $latestBefore = @($dataset.records | ForEach-Object { [string]$_.date } | Sort-Object | Select-Object -Last 1)

  if ($Probe) {
    $runLog.status = 'probe-success'; $runLog.recordsAfter = $runLog.recordsBefore; $runLog.latestContractDate = $(if ($latestBefore.Count) { $latestBefore[0] } else { $null })
    Write-UpdateLog $runLog; Write-Host "Probe succeeded: key recognized, $($runLog.complexesMatched) complexes matched, $($runLog.validDownloaded) valid rows. Data file unchanged."; return
  }
  if (-not $dataChanged) {
    $runLog.status = 'success-no-change'; $runLog.recordsAfter = $runLog.recordsBefore; $runLog.latestContractDate = $(if ($latestBefore.Count) { $latestBefore[0] } else { $null })
    Write-UpdateLog $runLog; Write-Host 'No OpenAPI transaction changes. Existing data file left untouched.'; return
  }

  $keptRows = New-Object System.Collections.ArrayList
  foreach ($record in @($dataset.records)) {
    $replace = $selectedSet.Contains([string]$record.complexId) -and $record.kind -eq '아파트 매매' -and [string]$record.date -ge $refreshStart -and [string]$record.date -le $refreshEnd
    if (-not $replace) { [void]$keptRows.Add($record) }
  }
  foreach ($record in @($replacementRows)) { [void]$keptRows.Add($record) }
  $sortedRows = @($keptRows | Sort-Object complexId, date, area, price, floor, transactionId)
  $rowsByComplex = @{}; foreach ($group in ($sortedRows | Group-Object complexId)) { $rowsByComplex[$group.Name] = @($group.Group) }
  $completedAt = (Get-KoreaNow).ToString('o'); $complexesOut = New-Object System.Collections.ArrayList
  foreach ($complex in @($dataset.complexes)) {
    $complexMap = Copy-PropertiesToOrderedMap $complex
    if ($mappingByComplex.ContainsKey([string]$complex.id)) {
      $complexMap['openApi'] = $mappingByComplex[[string]$complex.id]; $stats = $refreshStats[[string]$complex.id]
      $complexMap['refresh'] = [ordered]@{ lastSuccess = $completedAt; sourceUrl = $ApiEndpoint; method = "official OpenAPI rolling $RefreshMonths-month replacement"; windowStart = $refreshStart; windowEnd = $refreshEnd; valid = $stats.Valid; cancelledExcluded = $stats.Cancelled }
      $complexRows = if ($rowsByComplex.ContainsKey([string]$complex.id)) { $rowsByComplex[[string]$complex.id] } else { @() }
      $complexMap['stats'] = Get-ComplexStats -Rows $complexRows -Complex $complex -RecentCancelled $stats.Cancelled
    }
    [void]$complexesOut.Add($complexMap)
  }
  $metaMap = Copy-PropertiesToOrderedMap $dataset.meta
  $latestDate = @($sortedRows | ForEach-Object { [string]$_.date } | Sort-Object | Select-Object -Last 1)
  $metaMap['rangeEnd'] = $(if ($latestDate.Count) { $latestDate[0] } else { $refreshEnd }); $metaMap['generatedAt'] = $today.ToString('yyyy-MM-dd'); $metaMap['recordCount'] = $sortedRows.Count
  $metaMap['source'] = '국토교통부 실거래가 공식 OpenAPI · 서울 공개 아카이브 · 아실 월평균'; $metaMap['sourceUrl'] = $ApiEndpoint
  $metaMap['basis'] = "계약일 기준 · 공식 OpenAPI 최근 $RefreshMonths개월 전체 재조회 · 해제/취소 제외 · 공급면적 평형은 검증된 단지 타입 매핑 사용"
  $trackingStartedAt = if ($dataset.meta.firstSeenTracking.startedAt) { [string]$dataset.meta.firstSeenTracking.startedAt } else { $today.ToString('yyyy-MM-dd') }
  $metaMap['firstSeenTracking'] = [ordered]@{ field = 'first_seen_at'; startedAt = $trackingStartedAt; legacyValue = $null; basis = '우리 시스템이 거래를 처음 발견한 한국 날짜; 추적 도입 전 거래는 null' }
  $metaMap['lastRefresh'] = [ordered]@{ completedAt = $completedAt; months = $dealMonths; complexes = $complexesToUpdate.Count; regions = $lawdCodes.Count; validDownloaded = $runLog.validDownloaded; cancelledExcluded = $runLog.cancelledExcluded; sourceUrl = $ApiEndpoint; method = "official OpenAPI rolling $RefreshMonths-month full replacement" }
  $output = [ordered]@{ meta = $metaMap; complexes = $complexesOut; records = $sortedRows }
  $temporaryFile = $dataFile + '.tmp'
  [IO.File]::WriteAllText($temporaryFile, ("window.APT_ARCHIVE_DATA = " + ($output | ConvertTo-Json -Depth 24 -Compress) + ';' + [Environment]::NewLine), $Utf8NoBom)
  $verificationText = [IO.File]::ReadAllText($temporaryFile, [Text.Encoding]::UTF8)
  $verification = (($verificationText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  Assert-Dataset -Before $dataset -After $verification -ExpectedRecordCount $sortedRows.Count -OldRefreshCount $oldRefreshRows.Count -NewRefreshCount $replacementRows.Count
  $backupDirectory = Split-Path -Parent $backupFile
  if (-not (Test-Path -LiteralPath $backupDirectory)) { [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null }
  Copy-Item -LiteralPath $dataFile -Destination $backupFile -Force
  Move-Item -LiteralPath $temporaryFile -Destination $dataFile -Force; $temporaryFile = $null
  $runLog.status = 'success-changed'; $runLog.recordsAfter = $sortedRows.Count; $runLog.latestContractDate = $(if ($latestDate.Count) { $latestDate[0] } else { $null })
  Write-UpdateLog $runLog; Write-Host "OpenAPI update succeeded: $($runLog.recordsBefore) -> $($runLog.recordsAfter); latest $($runLog.latestContractDate)."
} catch {
  $runLog.status = 'failed'; $runLog.error = Protect-ApiKey $_.Exception.Message
  Write-UpdateLog $runLog; throw
} finally {
  if ($lockStream) { $lockStream.Dispose() }
  if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
  if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue }
}
