[CmdletBinding()]
param(
  [string]$DataPath = 'public\data\transactions.js',
  [string]$BackupPath = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryDirectory = Split-Path -Parent $scriptDirectory
. (Join-Path $scriptDirectory 'transaction-first-seen.ps1')

function Resolve-MigrationPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $repositoryDirectory $Path))
}

function Get-KoreaDateText {
  foreach ($zoneId in @('Korea Standard Time', 'Asia/Seoul')) {
    try { return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById($zoneId)).ToString('yyyy-MM-dd') }
    catch { }
  }
  throw 'Korea time zone is unavailable.'
}

function Get-MigrationFingerprint {
  param($Dataset)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($item in @($Dataset.meta) + @($Dataset.complexes) + @($Dataset.records)) {
      $map = [ordered]@{}
      foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -in @('first_seen_at', 'firstSeenTracking')) { continue }
        $map[$property.Name] = $property.Value
      }
      $bytes = [Text.Encoding]::UTF8.GetBytes(($map | ConvertTo-Json -Depth 24 -Compress) + "`n")
      [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
    }
    [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
    return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
  } finally { $sha.Dispose() }
}

$dataFile = Resolve-MigrationPath $DataPath
if (-not (Test-Path -LiteralPath $dataFile)) { throw "Data file not found: $dataFile" }
if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Join-Path ([IO.Path]::GetTempPath()) 'apart-price-transactions.before-first-seen.js' }
$backupFile = Resolve-MigrationPath $BackupPath
$temporaryFile = $dataFile + '.first-seen.tmp'

try {
  $text = [IO.File]::ReadAllText($dataFile, [Text.Encoding]::UTF8)
  $dataset = (($text -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  if (-not $dataset.meta -or -not $dataset.complexes -or -not $dataset.records) { throw 'Unable to parse apartment dataset.' }
  $recordCountBefore = @($dataset.records).Count
  $fingerprintBefore = Get-MigrationFingerprint $dataset
  $initialized = Initialize-FirstSeenFields -Records $dataset.records

  $metaInitialized = -not $dataset.meta.PSObject.Properties['firstSeenTracking']
  if ($metaInitialized) {
    $dataset.meta | Add-Member -NotePropertyName firstSeenTracking -NotePropertyValue ([PSCustomObject][ordered]@{
      field = 'first_seen_at'
      startedAt = Get-KoreaDateText
      legacyValue = $null
      basis = '우리 시스템이 거래를 처음 발견한 한국 날짜; 추적 도입 전 거래는 null'
    })
  }

  if ($initialized -eq 0 -and -not $metaInitialized) {
    Write-Host 'First-seen migration already applied. Data file left untouched.'
    return
  }

  [IO.File]::WriteAllText($temporaryFile, ('window.APT_ARCHIVE_DATA = ' + ($dataset | ConvertTo-Json -Depth 24 -Compress) + ';' + [Environment]::NewLine), $Utf8NoBom)
  $verificationText = [IO.File]::ReadAllText($temporaryFile, [Text.Encoding]::UTF8)
  $verification = (($verificationText -replace '^\s*window\.APT_ARCHIVE_DATA\s*=\s*', '' -replace ';\s*$', '') | ConvertFrom-Json)
  if (@($verification.records).Count -ne $recordCountBefore) { throw 'Migration validation failed: record count changed.' }
  if (@($verification.records | Where-Object { -not $_.PSObject.Properties['first_seen_at'] }).Count -ne 0) { throw 'Migration validation failed: a record is missing first_seen_at.' }
  if ((Get-MigrationFingerprint $verification) -ne $fingerprintBefore) { throw 'Migration validation failed: existing dataset content changed.' }

  $backupDirectory = Split-Path -Parent $backupFile
  if (-not (Test-Path -LiteralPath $backupDirectory)) { [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null }
  Copy-Item -LiteralPath $dataFile -Destination $backupFile -Force
  Move-Item -LiteralPath $temporaryFile -Destination $dataFile -Force
  $temporaryFile = $null
  Write-Host "First-seen migration succeeded: $initialized legacy records initialized to null; backup: $backupFile"
} finally {
  if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) { Remove-Item -LiteralPath $temporaryFile -Force }
}
