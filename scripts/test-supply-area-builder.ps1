[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$builderPath = Join-Path $repositoryDirectory 'scripts\build-supply-area-map.ps1'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("apart-price-supply-builder-{0}" -f [Guid]::NewGuid().ToString('N'))
$dataPath = Join-Path $testDirectory 'transactions.js'
$outputPath = Join-Path $testDirectory 'supply-areas.js'
$reportPath = Join-Path $testDirectory 'report.md'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
  [IO.Directory]::CreateDirectory($testDirectory) | Out-Null
  $dataset = [ordered]@{
    meta = [ordered]@{ complexCount = 1; recordCount = 0 }
    complexes = @([ordered]@{
        id = 'seoul-11680-catalog-fixture'
        city = '서울'
        district = '강남구'
        name = '거래없는신규단지'
        supplyMapping = 'pending-source-code'
      })
    records = @()
  }
  [IO.File]::WriteAllText($dataPath, ('window.APT_ARCHIVE_DATA = ' + ($dataset | ConvertTo-Json -Depth 12 -Compress) + ';' + [Environment]::NewLine), $Utf8NoBom)
  [IO.File]::WriteAllText($outputPath, 'window.APT_SUPPLY_AREA_DATA={"meta":{"complexCount":0},"complexes":{}};' + [Environment]::NewLine, $Utf8NoBom)

  & $builderPath -DataPath $dataPath -OutputPath $outputPath -ReportPath $reportPath -ReuseExistingTypes -RequestDelayMs 0
  if (-not $?) { throw 'Supply-area fixture build failed.' }

  $text = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
  $json = $text -replace '^window\.APT_SUPPLY_AREA_DATA=', '' -replace ';\s*$', ''
  $result = $json | ConvertFrom-Json
  $entry = $result.complexes.PSObject.Properties['seoul-11680-catalog-fixture'].Value
  if (-not $entry) { throw 'Pending zero-record complex was omitted from the supply map.' }
  if ($null -ne $entry.sourceUrl) { throw 'Pending source-code complex received a fabricated source URL.' }
  if (@($entry.areas.PSObject.Properties).Count -ne 0) { throw 'Zero-record complex unexpectedly received area mappings.' }
  if ([int]$result.meta.complexCount -ne 1 -or [int]$result.meta.mappedRecordCount -ne 0 -or [int]$result.meta.unresolvedRecordCount -ne 0) { throw 'Supply-area metadata is invalid for a zero-record pending complex.' }
  Write-Host 'Supply-area builder test passed: a new pending complex with zero records is preserved without a null error or fabricated source URL.'
} finally {
  if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}
