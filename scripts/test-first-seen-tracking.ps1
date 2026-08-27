[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'transaction-first-seen.ps1')

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function New-TestRecord {
  param(
    [string]$Id,
    [string]$Date = '2026-08-20',
    [long]$Price = 100000,
    [string]$Dong = '101',
    [AllowNull()]$FirstSeen = $null,
    [switch]$Legacy
  )
  $record = [PSCustomObject][ordered]@{
    complexId = 'test-complex'; transactionId = $Id; date = $Date; area = 84.99; py = 25.7; group = 20
    price = $Price; floor = 12; kind = '아파트 매매'; dealType = '중개거래'; broker = '서울 강남구'
    registration = '-'; apartmentDong = $Dong; tracking_key = $null; source = '국토교통부 실거래가 OpenAPI'
  }
  if (-not $Legacy) { $record | Add-Member -NotePropertyName first_seen_at -NotePropertyValue $FirstSeen }
  return $record
}

$legacy = New-TestRecord -Id 'legacy' -Legacy
Assert-Equal (Initialize-FirstSeenFields @($legacy)) 1 'Legacy migration count mismatch.'
if ($null -ne $legacy.first_seen_at) { throw 'Legacy first_seen_at must initialize to null.' }

$oldExact = New-TestRecord -Id 'same-id' -FirstSeen '2026-08-20'
$incomingExact = New-TestRecord -Id 'same-id'
$exactResult = Sync-FirstSeenForTransactions @($oldExact) @($incomingExact) '2026-08-26'
Assert-Equal $exactResult.NewCount 0 'An unchanged re-fetch was incorrectly marked new.'
Assert-Equal $exactResult.Rows[0].first_seen_at '2026-08-20' 'An unchanged re-fetch lost its original first_seen_at.'

$oldCorrection = New-TestRecord -Id 'old-price-id' -Price 100000 -FirstSeen '2026-08-20'
$oldCorrection.tracking_key = Get-TransactionTrackingKey $oldCorrection
$incomingCorrection = New-TestRecord -Id 'corrected-price-id' -Price 101000
$correctionResult = Sync-FirstSeenForTransactions @($oldCorrection) @($incomingCorrection) '2026-08-26'
Assert-Equal $correctionResult.NewCount 0 'A corrected transaction was incorrectly marked new.'
Assert-Equal $correctionResult.CorrectedCount 1 'A visible price correction was not counted.'
Assert-Equal $correctionResult.Rows[0].first_seen_at '2026-08-20' 'A correction did not preserve first_seen_at.'

$oldDateCorrection = New-TestRecord -Id 'old-date-id' -Date '2026-08-20' -FirstSeen '2026-08-20'
$incomingDateCorrection = New-TestRecord -Id 'corrected-date-id' -Date '2026-08-21'
$dateCorrectionResult = Sync-FirstSeenForTransactions @($oldDateCorrection) @($incomingDateCorrection) '2026-08-26'
Assert-Equal $dateCorrectionResult.NewCount 0 'A uniquely matched contract-date correction was incorrectly marked new.'
Assert-Equal $dateCorrectionResult.Rows[0].first_seen_at '2026-08-20' 'A contract-date correction did not preserve first_seen_at.'

$legacyCorrection = New-TestRecord -Id 'legacy-old-id' -Price 90000 -FirstSeen '2026-08-20'
$legacyCorrection.PSObject.Properties.Remove('apartmentDong')
$legacyCorrection.PSObject.Properties.Remove('tracking_key')
$legacyIncoming = New-TestRecord -Id 'legacy-corrected-id' -Price 91000
$legacyCorrectionResult = Sync-FirstSeenForTransactions @($legacyCorrection) @($legacyIncoming) '2026-08-26'
Assert-Equal $legacyCorrectionResult.NewCount 0 'A uniquely matched legacy correction was incorrectly marked new.'
Assert-Equal $legacyCorrectionResult.Rows[0].first_seen_at '2026-08-20' 'Legacy correction did not preserve first_seen_at.'

$newLateReport = New-TestRecord -Id 'new-late' -Date '2026-08-20'
$newSameDay = New-TestRecord -Id 'new-same-day' -Date '2026-08-26' -Dong '102'
$newResult = Sync-FirstSeenForTransactions @() @($newLateReport, $newSameDay) '2026-08-26'
Assert-Equal $newResult.NewCount 2 'New transactions were not counted.'
Assert-Equal $newResult.Rows[0].first_seen_at '2026-08-26' 'Late report did not receive discovery date.'
Assert-Equal $newResult.Rows[1].first_seen_at '2026-08-26' 'Same-day report did not receive discovery date.'

$oldDuplicateBase = New-TestRecord -Id 'existing-copy' -FirstSeen '2026-08-20'
$sameReFetch = New-TestRecord -Id 'existing-copy'
$additionalTransaction = New-TestRecord -Id 'genuinely-separate-id'
$duplicateResult = Sync-FirstSeenForTransactions @($oldDuplicateBase) @($sameReFetch, $additionalTransaction) '2026-08-26'
Assert-Equal $duplicateResult.NewCount 1 'Re-fetch and additional transaction were not distinguished.'
Assert-Equal (@($duplicateResult.Rows | Where-Object first_seen_at -eq '2026-08-20').Count) 1 'The re-fetched row did not preserve its original discovery date.'

$cancelResult = Sync-FirstSeenForTransactions @((New-TestRecord -Id 'cancelled' -FirstSeen '2026-08-20')) @() '2026-08-26'
Assert-Equal $cancelResult.RemovedCount 1 'A cancelled/removed transaction was not removed.'
Assert-Equal @($cancelResult.Rows).Count 0 'A cancelled/removed transaction remained in output.'

$catalogHistory = New-TestRecord -Id 'catalog-history' -Date '2026-06-01'
$catalogHistory.complexId = 'catalog-bootstrap'
$genuineNew = New-TestRecord -Id 'genuine-new' -Date '2026-08-26'
$genuineNew.complexId = 'existing-complex'
$bootstrapResult = Sync-FirstSeenForTransactions @() @($catalogHistory, $genuineNew) '2026-08-26'
$bootstrapResult = Protect-CatalogBootstrapTransactions $bootstrapResult @('catalog-bootstrap')
Assert-Equal $bootstrapResult.BootstrapCount 1 'Catalog bootstrap reset count mismatch.'
Assert-Equal $bootstrapResult.NewCount 1 'Catalog bootstrap protection suppressed a genuine new transaction.'
if ($null -ne $bootstrapResult.Rows[0].first_seen_at) { throw 'Catalog bootstrap history must remain excluded from weekly-new.' }
Assert-Equal $bootstrapResult.Rows[1].first_seen_at '2026-08-26' 'A genuine new transaction lost its discovery date during catalog bootstrap.'

Write-Host 'First-seen tracking tests passed: legacy migration, new discovery, exact re-fetch, price/date correction preservation, duplicate distinction, cancellation removal, and catalog-bootstrap protection.'
