function Get-FirstSeenPropertyValue {
  param($Record)
  $property = $Record.PSObject.Properties['first_seen_at']
  if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
  return [string]$property.Value
}

function Set-FirstSeenPropertyValue {
  param($Record, [AllowNull()]$Value)
  $property = $Record.PSObject.Properties['first_seen_at']
  if ($property) { $property.Value = $Value }
  else { $Record | Add-Member -NotePropertyName first_seen_at -NotePropertyValue $Value }
}

function Initialize-FirstSeenFields {
  param([Parameter(Mandatory = $true)]$Records)
  $added = 0
  foreach ($record in @($Records)) {
    if (-not $record.PSObject.Properties['first_seen_at']) {
      Set-FirstSeenPropertyValue -Record $record -Value $null
      $added++
    }
  }
  return $added
}

function Get-TrackingHash {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant())
  } finally { $sha.Dispose() }
}

function Get-RecordAreaText {
  param($Record)
  return ([Math]::Round([double]$Record.area, 4)).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-RecordFloorText {
  param($Record)
  if ($null -eq $Record.floor) { return '' }
  return [string]$Record.floor
}

function Get-RecordApartmentDong {
  param($Record)
  $property = $Record.PSObject.Properties['apartmentDong']
  if (-not $property) { return '' }
  $value = ([string]$property.Value).Trim()
  if ($value -eq '-') { return '' }
  return $value
}

function Get-TransactionTrackingKey {
  param($Record)
  $identity = @(
    [string]$Record.complexId
    [string]$Record.date
    (Get-RecordAreaText $Record)
    (Get-RecordFloorText $Record)
    (Get-RecordApartmentDong $Record)
  ) -join '|'
  return 'molit-' + (Get-TrackingHash $identity).Substring(0, 24)
}

function Set-TrackingKeyIfMissing {
  param($Record)
  $property = $Record.PSObject.Properties['tracking_key']
  $value = if ($property) { ([string]$property.Value).Trim() } else { '' }
  if (-not $value) {
    $value = Get-TransactionTrackingKey $Record
    if ($property) { $property.Value = $value }
    else { $Record | Add-Member -NotePropertyName tracking_key -NotePropertyValue $value }
  }
  return $value
}

function Get-RecordVisibleSignature {
  param($Record)
  $map = [ordered]@{
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
  }
  return $map | ConvertTo-Json -Compress
}

function Get-StrongCorrectionKey {
  param($Record)
  $dong = Get-RecordApartmentDong $Record
  if (-not $dong) { return $null }
  return @([string]$Record.complexId, [string]$Record.date, (Get-RecordAreaText $Record), (Get-RecordFloorText $Record), $dong) -join '|'
}

function Get-ExactComparableKey {
  param($Record)
  return @(
    [string]$Record.complexId
    [string]$Record.date
    (Get-RecordAreaText $Record)
    [string]$Record.price
    (Get-RecordFloorText $Record)
  ) -join '|'
}

function Get-LegacyCorrectionKey {
  param($Record)
  return @([string]$Record.complexId, [string]$Record.date, (Get-RecordAreaText $Record), (Get-RecordFloorText $Record)) -join '|'
}

function Get-RegistrationCorrectionKey {
  param($Record)
  $registration = ([string]$Record.registration).Trim()
  if (-not $registration -or $registration -eq '-') { return $null }
  return @([string]$Record.complexId, $registration, (Get-RecordAreaText $Record), (Get-RecordFloorText $Record), (Get-RecordApartmentDong $Record)) -join '|'
}

function Get-DateCorrectionKey {
  param($Record)
  $dong = Get-RecordApartmentDong $Record
  if (-not $dong) { return $null }
  return @([string]$Record.complexId, (Get-RecordAreaText $Record), (Get-RecordFloorText $Record), $dong, [string]$Record.price) -join '|'
}

function Sync-FirstSeenForTransactions {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$ExistingRows,
    [Parameter(Mandatory = $true)]$IncomingRows,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$SeenDate
  )

  $old = @($ExistingRows)
  $incoming = @($IncomingRows)
  [void](Initialize-FirstSeenFields -Records $old)
  [void](Initialize-FirstSeenFields -Records $incoming)
  foreach ($record in $incoming) { [void](Set-TrackingKeyIfMissing $record) }

  $matchedOld = New-Object 'System.Collections.Generic.HashSet[int]'
  $matchedIncoming = New-Object 'System.Collections.Generic.HashSet[int]'
  $pairs = New-Object System.Collections.ArrayList

  function Add-MatchPair {
    param([int]$OldIndex, [int]$IncomingIndex)
    if ($matchedOld.Add($OldIndex) -and $matchedIncoming.Add($IncomingIndex)) {
      [void]$pairs.Add([PSCustomObject]@{ OldIndex = $OldIndex; IncomingIndex = $IncomingIndex })
    }
  }

  function Match-ByKey {
    param([scriptblock]$OldKey, [scriptblock]$IncomingKey, [switch]$UniqueOnly)
    $oldGroups = @{}
    $incomingGroups = @{}
    for ($index = 0; $index -lt $old.Count; $index++) {
      if ($matchedOld.Contains($index)) { continue }
      $key = & $OldKey $old[$index]
      if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
      if (-not $oldGroups.ContainsKey($key)) { $oldGroups[$key] = New-Object System.Collections.ArrayList }
      [void]$oldGroups[$key].Add($index)
    }
    for ($index = 0; $index -lt $incoming.Count; $index++) {
      if ($matchedIncoming.Contains($index)) { continue }
      $key = & $IncomingKey $incoming[$index]
      if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
      if (-not $incomingGroups.ContainsKey($key)) { $incomingGroups[$key] = New-Object System.Collections.ArrayList }
      [void]$incomingGroups[$key].Add($index)
    }
    foreach ($key in @($incomingGroups.Keys)) {
      if (-not $oldGroups.ContainsKey($key)) { continue }
      $oldIndexes = @($oldGroups[$key]); $incomingIndexes = @($incomingGroups[$key])
      if ($UniqueOnly -and ($oldIndexes.Count -ne 1 -or $incomingIndexes.Count -ne 1)) { continue }
      $pairCount = [Math]::Min($oldIndexes.Count, $incomingIndexes.Count)
      for ($pairIndex = 0; $pairIndex -lt $pairCount; $pairIndex++) {
        Add-MatchPair -OldIndex $oldIndexes[$pairIndex] -IncomingIndex $incomingIndexes[$pairIndex]
      }
    }
  }

  Match-ByKey `
    -OldKey { param($record) $id = ([string]$record.transactionId).Trim(); if ($id) { "$($record.complexId)|$id" } } `
    -IncomingKey { param($record) $id = ([string]$record.transactionId).Trim(); if ($id) { "$($record.complexId)|$id" } }

  Match-ByKey `
    -OldKey { param($record) $property = $record.PSObject.Properties['tracking_key']; if ($property) { [string]$property.Value } } `
    -IncomingKey { param($record) [string]$record.tracking_key }

  # Preserve discovery when a provider or transaction-ID algorithm changes but
  # the visible transaction facts are identical. Multiset pairing keeps truly
  # distinct duplicate contracts separate.
  Match-ByKey -OldKey { param($record) Get-ExactComparableKey $record } -IncomingKey { param($record) Get-ExactComparableKey $record }

  Match-ByKey -OldKey { param($record) Get-StrongCorrectionKey $record } -IncomingKey { param($record) Get-StrongCorrectionKey $record }

  Match-ByKey -OldKey { param($record) Get-RegistrationCorrectionKey $record } -IncomingKey { param($record) Get-RegistrationCorrectionKey $record } -UniqueOnly

  # A contract-date correction changes the tracking key. If area, floor, building
  # and price still identify exactly one row on both sides, preserve discovery.
  Match-ByKey -OldKey { param($record) Get-DateCorrectionKey $record } -IncomingKey { param($record) Get-DateCorrectionKey $record } -UniqueOnly

  # Old archived rows did not store apartmentDong. Only use the weaker key when
  # it identifies exactly one old and one incoming row, avoiding broad guessing.
  Match-ByKey -OldKey { param($record) Get-LegacyCorrectionKey $record } -IncomingKey { param($record) Get-LegacyCorrectionKey $record } -UniqueOnly

  $correctedCount = 0
  foreach ($pair in @($pairs)) {
    $oldRecord = $old[$pair.OldIndex]
    $incomingRecord = $incoming[$pair.IncomingIndex]
    Set-FirstSeenPropertyValue -Record $incomingRecord -Value (Get-FirstSeenPropertyValue $oldRecord)
    if ((Get-RecordVisibleSignature $oldRecord) -ne (Get-RecordVisibleSignature $incomingRecord)) { $correctedCount++ }
  }

  $newCount = 0
  for ($index = 0; $index -lt $incoming.Count; $index++) {
    if ($matchedIncoming.Contains($index)) { continue }
    Set-FirstSeenPropertyValue -Record $incoming[$index] -Value $SeenDate
    $newCount++
  }

  return [PSCustomObject]@{
    Rows = $incoming
    NewCount = $newCount
    RemovedCount = $old.Count - $matchedOld.Count
    CorrectedCount = $correctedCount
    MatchedCount = $matchedOld.Count
  }
}

function Protect-CatalogBootstrapTransactions {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$TrackingResult,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$BootstrapComplexIds
  )

  $bootstrapSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($complexId in @($BootstrapComplexIds)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$complexId)) { [void]$bootstrapSet.Add([string]$complexId) }
  }
  $resetCount = 0
  foreach ($record in @($TrackingResult.Rows)) {
    if ($bootstrapSet.Contains([string]$record.complexId) -and (Get-FirstSeenPropertyValue $record)) {
      Set-FirstSeenPropertyValue -Record $record -Value $null
      $resetCount++
    }
  }
  $TrackingResult.NewCount = [Math]::Max(0, [int]$TrackingResult.NewCount - $resetCount)
  $TrackingResult | Add-Member -NotePropertyName BootstrapCount -NotePropertyValue $resetCount -Force
  return $TrackingResult
}
