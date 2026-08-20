[CmdletBinding()]
param(
  [string]$DataPath = 'public\data\transactions.js',
  [string]$OutputPath = 'public\data\supply-areas.js',
  [string]$ReportPath = 'reports\supply-area-verification.md',
  [int]$RequestDelayMs = 350,
  [int]$MaxRetries = 3,
  [int]$Limit = 0,
  [string[]]$ComplexIds,
  [switch]$ReuseExistingTypes
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryDirectory = Split-Path -Parent $scriptDirectory
$sourceBaseUrl = 'https://asil.kr/app/apt_info.jsp?os=pc&apt='
$pyDivisor = 3.305785

function Resolve-RepositoryPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $repositoryDirectory $Path))
}

function Get-ComplexCode {
  param($Complex)
  if ($Complex.officialComplexCode) { return [string]$Complex.officialComplexCode }
  return ([string]$Complex.id).Split('-')[-1]
}

function Get-SourcePage {
  param([Parameter(Mandatory = $true)][string]$ComplexCode)
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
      return (Invoke-WebRequest -Uri ($sourceBaseUrl + $ComplexCode) -Headers @{
        Referer = 'https://asil.kr/asil/index.jsp'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36'
      } -TimeoutSec 30).Content
    } catch {
      $lastError = $_.Exception
      if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds @(2, 5, 10)[[Math]::Min($attempt - 1, 2)] }
    }
  }
  throw "Unable to read area types for complex code $ComplexCode`: $($lastError.Message)"
}

function Get-SourceTypes {
  param([Parameter(Mandatory = $true)][string]$Html)
  $floorTypes = New-Object System.Collections.Generic.List[object]
  $floorPattern = "loadFloorPlan\(this,\s*'(?<order>[^']+)',\s*'(?<path>[^']+)',\s*'(?<type>[^']*)',\s*'(?<supply>[\d.]+)',\s*'(?<exclusive>[\d.]+)'\)"
  foreach ($match in [regex]::Matches($Html, $floorPattern)) {
    $supplyArea = [double]$match.Groups['supply'].Value
    $exclusiveArea = [double]$match.Groups['exclusive'].Value
    # Korean apartment type labels conventionally use the integer part of the
    # verified supply-area pyeong value (for example 115.02㎡ -> 34평형).
    $pyeong = [int][Math]::Floor(($supplyArea / $pyDivisor) + [double]::Epsilon)
    $floorTypes.Add([PSCustomObject][ordered]@{
      type = $match.Groups['type'].Value
      exclusiveArea = $exclusiveArea
      supplyArea = $supplyArea
      pyeong = $pyeong
      group = [int]([Math]::Floor($pyeong / 10) * 10)
    })
  }

  $labelTypes = New-Object System.Collections.Generic.List[object]
  $labelPattern = "search3\(\d+,\s*'(?<exclusive>[^']+)',\s*'(?<pyeong>[^']+)'\)"
  foreach ($match in [regex]::Matches($Html, $labelPattern)) {
    $exclusiveText = $match.Groups['exclusive'].Value
    $pyeongText = $match.Groups['pyeong'].Value
    $exclusiveArea = 0.0
    $pyeong = 0
    if (-not [double]::TryParse($exclusiveText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$exclusiveArea)) { continue }
    if (-not [int]::TryParse($pyeongText, [ref]$pyeong) -or $pyeong -le 0) { continue }
    $labelTypes.Add([PSCustomObject][ordered]@{
      exclusiveArea = $exclusiveArea
      pyeong = $pyeong
      group = [int]([Math]::Floor($pyeong / 10) * 10)
    })
  }

  return [PSCustomObject]@{
    FloorTypes = @($floorTypes | Sort-Object exclusiveArea, supplyArea, type -Unique)
    LabelTypes = @($labelTypes | Sort-Object exclusiveArea, pyeong -Unique)
  }
}

function Resolve-AreaMapping {
  param(
    [Parameter(Mandatory = $true)][double]$Area,
    [Parameter(Mandatory = $true)]$SourceTypes
  )

  $floorCandidates = @($SourceTypes.FloorTypes | ForEach-Object {
    [PSCustomObject]@{ type = $_; delta = [Math]::Abs([double]$_.exclusiveArea - $Area) }
  } | Where-Object { $_.delta -le 0.03 } | Sort-Object delta)

  if ($floorCandidates.Count) {
    $minimumDelta = [double]$floorCandidates[0].delta
    $nearest = @($floorCandidates | Where-Object { [Math]::Abs([double]$_.delta - $minimumDelta) -lt 0.000001 })
    $pyeongs = @($nearest | ForEach-Object { [int]$_.type.pyeong } | Sort-Object -Unique)
    if ($pyeongs.Count -eq 1) {
      $type = $nearest[0].type
      $supplyAreas = @($nearest | ForEach-Object { [double]$_.type.supplyArea } | Sort-Object -Unique)
      $typeNames = @($nearest | ForEach-Object { [string]$_.type.type } | Sort-Object -Unique)
      return [PSCustomObject][ordered]@{
        supplyArea = $(if ($supplyAreas.Count -eq 1) { $supplyAreas[0] } else { $null })
        pyeong = [int]$type.pyeong
        group = [int]$type.group
        type = $(if ($typeNames.Count -eq 1) { $typeNames[0] } else { $null })
        sourceExclusiveArea = [double]$type.exclusiveArea
        method = $(if ($supplyAreas.Count -eq 1) { 'source-floor-plan' } else { 'source-floor-plan-pyeong' })
      }
    }
  }

  $integerArea = [int][Math]::Floor($Area)
  $labelCandidates = @($SourceTypes.LabelTypes | Where-Object { [int][Math]::Floor([double]$_.exclusiveArea) -eq $integerArea })
  $labelPyeongs = @($labelCandidates | ForEach-Object { [int]$_.pyeong } | Sort-Object -Unique)
  if ($labelPyeongs.Count -eq 1) {
    $pyeong = $labelPyeongs[0]
    return [PSCustomObject][ordered]@{
      supplyArea = $null
      pyeong = $pyeong
      group = [int]([Math]::Floor($pyeong / 10) * 10)
      type = $null
      sourceExclusiveArea = [double]$labelCandidates[0].exclusiveArea
      method = 'source-pyeong-label'
    }
  }

  return $null
}

$dataFile = Resolve-RepositoryPath -Path $DataPath
$outputFile = Resolve-RepositoryPath -Path $OutputPath
$reportFile = Resolve-RepositoryPath -Path $ReportPath
$text = [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8)
$prefix = 'window.APT_ARCHIVE_DATA = '
if (-not $text.StartsWith($prefix)) { throw 'Unexpected transaction data wrapper.' }
$json = $text.Substring($prefix.Length).Trim()
if ($json.EndsWith(';')) { $json = $json.Substring(0, $json.Length - 1) }
$dataset = $json | ConvertFrom-Json
$recordsByComplex = @{}
foreach ($record in @($dataset.records)) {
  $recordComplexId = [string]$record.complexId
  if (-not $recordsByComplex.ContainsKey($recordComplexId)) {
    $recordsByComplex[$recordComplexId] = New-Object System.Collections.Generic.List[object]
  }
  $recordsByComplex[$recordComplexId].Add($record)
}

$sourceCache = $null
if ($ReuseExistingTypes) {
  if (-not (Test-Path -LiteralPath $outputFile)) { throw "Existing supply-area map not found: $outputFile" }
  $cacheText = [IO.File]::ReadAllText($outputFile, [Text.Encoding]::UTF8)
  $cachePrefix = 'window.APT_SUPPLY_AREA_DATA='
  if (-not $cacheText.StartsWith($cachePrefix)) { throw 'Unexpected supply-area cache wrapper.' }
  $cacheJson = $cacheText.Substring($cachePrefix.Length).Trim()
  if ($cacheJson.EndsWith(';')) { $cacheJson = $cacheJson.Substring(0, $cacheJson.Length - 1) }
  $sourceCache = $cacheJson | ConvertFrom-Json
}

$complexes = @($dataset.complexes)
if ($ComplexIds) { $complexes = @($complexes | Where-Object { $ComplexIds -contains [string]$_.id }) }
if ($Limit -gt 0) { $complexes = @($complexes | Select-Object -First $Limit) }

$complexMap = [ordered]@{}
$reportRows = New-Object System.Collections.Generic.List[object]
$unresolvedRows = New-Object System.Collections.Generic.List[object]
$mappedAreaCount = 0
$unresolvedAreaCount = 0
$mappedRecordCount = 0
$unresolvedRecordCount = 0
$retrievedAt = [DateTimeOffset]::Now.ToString('o')

$index = 0
foreach ($complex in $complexes) {
  $index++
  $complexId = [string]$complex.id
  $complexName = $(if ($complex.displayName) { [string]$complex.displayName } else { [string]$complex.name })
  $complexCode = Get-ComplexCode -Complex $complex
  $cachedProperty = if ($sourceCache) { $sourceCache.complexes.PSObject.Properties[$complexId] } else { $null }
  if ($cachedProperty) {
    Write-Host "[$index/$($complexes.Count)] $complexName ($complexCode, cached)"
    $sourceTypes = [PSCustomObject]@{
      FloorTypes = @($cachedProperty.Value.floorTypes)
      LabelTypes = @($cachedProperty.Value.labelTypes)
    }
  } else {
    Write-Host "[$index/$($complexes.Count)] $complexName ($complexCode)"
    $html = Get-SourcePage -ComplexCode $complexCode
    $sourceTypes = Get-SourceTypes -Html $html
  }
  $records = $recordsByComplex[$complexId].ToArray()
  $areaGroups = @($records | Group-Object { ([double]$_.area).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) } | Sort-Object { [double]$_.Name })
  $areaMap = [ordered]@{}
  $complexMapped = 0
  $complexUnresolved = 0

  foreach ($areaGroup in $areaGroups) {
    $area = [double]::Parse($areaGroup.Name, [Globalization.CultureInfo]::InvariantCulture)
    $mapping = Resolve-AreaMapping -Area $area -SourceTypes $sourceTypes
    if ($mapping) {
      $areaMap[$areaGroup.Name] = $mapping
      $mappedAreaCount++
      $complexMapped++
      $mappedRecordCount += $areaGroup.Count
    } else {
      $areaMap[$areaGroup.Name] = $null
      $unresolvedAreaCount++
      $complexUnresolved++
      $unresolvedRecordCount += $areaGroup.Count
      $unresolvedRows.Add([PSCustomObject]@{
        Complex = $complexName
        ComplexId = $complexId
        Area = $areaGroup.Name
        Records = $areaGroup.Count
        SourceUrl = $sourceBaseUrl + $complexCode
      })
    }
  }

  $complexMap[$complexId] = [ordered]@{
    sourceUrl = $sourceBaseUrl + $complexCode
    floorTypes = @($sourceTypes.FloorTypes)
    labelTypes = @($sourceTypes.LabelTypes)
    areas = $areaMap
  }
  $reportRows.Add([PSCustomObject]@{
    Complex = $complexName
    Mapped = $complexMapped
    Unresolved = $complexUnresolved
    FloorTypes = $sourceTypes.FloorTypes.Count
    LabelTypes = $sourceTypes.LabelTypes.Count
  })
  if (-not $cachedProperty -and $RequestDelayMs -gt 0 -and $index -lt $complexes.Count) { Start-Sleep -Milliseconds $RequestDelayMs }
}

$output = [ordered]@{
  meta = [ordered]@{
    source = '아실 단지정보 실제 평면·평형 데이터'
    sourceBaseUrl = $sourceBaseUrl
    retrievedAt = $retrievedAt
    complexCount = $complexes.Count
    mappedAreaCount = $mappedAreaCount
    unresolvedAreaCount = $unresolvedAreaCount
    mappedRecordCount = $mappedRecordCount
    unresolvedRecordCount = $unresolvedRecordCount
    floorPlanMatchToleranceM2 = 0.03
  }
  complexes = $complexMap
}

$outputDirectory = Split-Path -Parent $outputFile
if (-not (Test-Path -LiteralPath $outputDirectory)) { [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null }
$outputJson = $output | ConvertTo-Json -Depth 16 -Compress
[IO.File]::WriteAllText($outputFile, 'window.APT_SUPPLY_AREA_DATA=' + $outputJson + ';' + [Environment]::NewLine, $Utf8NoBom)

$reportDirectory = Split-Path -Parent $reportFile
if (-not (Test-Path -LiteralPath $reportDirectory)) { [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null }
$coverage = if (($mappedRecordCount + $unresolvedRecordCount) -gt 0) { 100 * $mappedRecordCount / ($mappedRecordCount + $unresolvedRecordCount) } else { 0 }
$report = New-Object System.Collections.Generic.List[string]
$report.Add('# 공급면적 매핑 검증 보고서')
$report.Add('')
$report.Add("- 생성 시각: $retrievedAt")
$report.Add("- 출처: 아실 단지 상세의 실제 평면 공급면적/전용면적 및 평형 라벨")
$report.Add("- 처리 단지: $($complexes.Count)개")
$report.Add("- 매핑된 전용면적 값: ${mappedAreaCount}개 (${mappedRecordCount}건)")
$report.Add("- 공급면적 확인 필요 값: ${unresolvedAreaCount}개 (${unresolvedRecordCount}건)")
$report.Add(("- 거래 레코드 매핑률: {0:N2}%" -f $coverage))
$report.Add('')
$report.Add('## 단지별 결과')
$report.Add('')
$report.Add('| 단지 | 매핑 | 확인 필요 | 실제 평면 타입 | 평형 라벨 |')
$report.Add('|---|---:|---:|---:|---:|')
foreach ($row in $reportRows) { $report.Add("| $($row.Complex) | $($row.Mapped) | $($row.Unresolved) | $($row.FloorTypes) | $($row.LabelTypes) |") }
$report.Add('')
$report.Add('## 필수 단지 표본 검증')
$report.Add('')
$report.Add('| 단지 | 전용면적㎡ | 실제 공급면적㎡ | 표시 평형 | 분류 | 매핑 근거 |')
$report.Add('|---|---:|---:|---:|---:|---|')
$requiredSamples = @(
  [PSCustomObject]@{ Name = '더블유 (W)'; ComplexId = 'busan-26290-20362232'; Area = '98.9922' },
  [PSCustomObject]@{ Name = '해운대 I PARK'; ComplexId = 'busan-26350-20145382'; Area = '80.572' },
  [PSCustomObject]@{ Name = '해운대 I PARK'; ComplexId = 'busan-26350-20145382'; Area = '110.447' },
  [PSCustomObject]@{ Name = '대우트럼프월드마린'; ComplexId = 'busan-26350-20069315'; Area = '158.74' },
  [PSCustomObject]@{ Name = '대우트럼프월드마린'; ComplexId = 'busan-26350-20069315'; Area = '171.7' },
  [PSCustomObject]@{ Name = '대우트럼프월드마린'; ComplexId = 'busan-26350-20069315'; Area = '187.88' },
  [PSCustomObject]@{ Name = '대우트럼프월드마린'; ComplexId = 'busan-26350-20069315'; Area = '217.95' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드2단지'; ComplexId = 'busan-26440-20412469'; Area = '84.9584' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드2단지'; ComplexId = 'busan-26440-20412469'; Area = '99.9247' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드2단지'; ComplexId = 'busan-26440-20412469'; Area = '113.9349' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드3단지'; ComplexId = 'busan-26440-20414377'; Area = '84.9584' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드3단지'; ComplexId = 'busan-26440-20414377'; Area = '99.9247' },
  [PSCustomObject]@{ Name = '더샵명지퍼스트월드3단지'; ComplexId = 'busan-26440-20414377'; Area = '113.9349' }
)
foreach ($sample in $requiredSamples) {
  $complexEntry = $complexMap[$sample.ComplexId]
  $sampleMapping = if ($complexEntry) { $complexEntry.areas[$sample.Area] } else { $null }
  if (-not $sampleMapping) { throw "Required verification sample is unresolved: $($sample.Name) $($sample.Area)㎡" }
  $supplyAreaText = if ($null -ne $sampleMapping.supplyArea) { [string]$sampleMapping.supplyArea } else { '평형 라벨 확인' }
  $report.Add("| $($sample.Name) | $($sample.Area) | $supplyAreaText | $($sampleMapping.pyeong)평 | $($sampleMapping.group)평대 | $($sampleMapping.method) |")
}
$report.Add('')
$report.Add('## 공급면적 확인 필요')
$report.Add('')
if ($unresolvedRows.Count) {
  $report.Add('| 단지 | 전용면적㎡ | 레코드 수 | 확인 출처 |')
  $report.Add('|---|---:|---:|---|')
  foreach ($row in $unresolvedRows) { $report.Add("| $($row.Complex) | $($row.Area) | $($row.Records) | [아실 단지정보]($($row.SourceUrl)) |") }
} else {
  $report.Add('없음')
}
[IO.File]::WriteAllLines($reportFile, $report, $Utf8NoBom)

Write-Host "Mapped areas: $mappedAreaCount; unresolved areas: $unresolvedAreaCount"
Write-Host "Mapped records: $mappedRecordCount; unresolved records: $unresolvedRecordCount; coverage: $($coverage.ToString('N2'))%"
Write-Host "Wrote $outputFile"
Write-Host "Wrote $reportFile"
