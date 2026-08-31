[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'molit-http.ps1')
# Load exactly the production parsing/retry functions, without running a collection.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir 'update-data-github.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Updater has PowerShell syntax errors' }
foreach ($name in @('Protect-ApiKey', 'Convert-XmlItem', 'Invoke-OpenApiPage')) {
  $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Invoke-Expression $functionAst.Extent.Text
}
$ApiKey = 'fixture-key-never-log'
$ApiEndpoint = 'https://example.invalid/openapi'
$ConnectTimeoutSec = 1; $ReadTimeoutSec = 1; $MaxRetries = 6
$ok = '<response><header><resultCode>000</resultCode><resultMsg>OK</resultMsg></header><body><items></items><totalCount>0</totalCount></body></response>'
$script:delays = @(); $script:calls = 0
function Start-Sleep { param($Seconds) $script:delays += [int]$Seconds }
function Invoke-MolitHttpResponse {
  param($Uri, $ConnectTimeoutSec, $ReadTimeoutSec)
  $script:calls++
  $item = $script:responses[[Math]::Min($script:calls - 1, $script:responses.Count - 1)]
  if ($item -is [Exception]) { throw $item }
  return $item
}
function Invoke-RetryCase {
  param([string]$Name, [object[]]$Responses, [int]$Calls, [bool]$ShouldFail)
  $script:responses = $Responses; $script:calls = 0; $script:delays = @()
  $script:runLog = [ordered]@{apiAttempts=0; apiCalls=0; apiKeyRecognized=$false; failedRequest=$null}
  $failed = $false
  try { Invoke-OpenApiPage -LawdCode '11110' -DealYmd '202608' -PageNo 3 | Out-Null }
  catch {
    $failed = $true
    if ($_.Exception.Message.Contains($ApiKey)) { throw 'Secret leaked in exception' }
  }
  if ($failed -ne $ShouldFail -or $script:calls -ne $Calls) { throw "$Name failed: calls=$script:calls, failed=$failed" }
  if (($script:runLog | ConvertTo-Json -Depth 8).Contains($ApiKey)) { throw 'Secret leaked in diagnostics' }
  Write-Host "PASS $Name"
}
$success = [pscustomobject]@{StatusCode=200;Content=$ok}
Invoke-RetryCase 'D timeout then success' @([TimeoutException]::new("timeout serviceKey=$ApiKey"),$success) 2 $false
if (($script:delays -join ',') -ne '5') { throw 'Incorrect timeout backoff' }
foreach ($status in @(429,500,502,503,504)) {
  Invoke-RetryCase "HTTP $status then success" @([pscustomobject]@{StatusCode=$status;Content=''},$success) 2 $false
}
Invoke-RetryCase 'connection reset then success' @([IO.IOException]::new('connection reset'),$success) 2 $false
Invoke-RetryCase 'E exhausted timeout' @([TimeoutException]::new('timeout')) 6 $true
if (($script:delays -join ',') -ne '5,15,30,60,120') { throw 'Backoff sequence differs from policy' }
if ($script:runLog.failedRequest.page -ne 3 -or $script:runLog.failedRequest.lawdCode -ne '11110') { throw 'Missing failing request identity' }
foreach ($status in @(401,403)) {
  Invoke-RetryCase "H HTTP $status fail immediately" @([pscustomobject]@{StatusCode=$status;Content=''}) 1 $true
  if ($script:delays.Count -ne 0 -or $script:runLog.failedRequest.category -ne 'authentication') { throw 'Authentication failure was retried' }
}
$auth = '<OpenAPI_ServiceResponse><cmmMsgHeader><returnReason>30</returnReason><returnAuthMsg>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</returnAuthMsg><errMsg>authentication</errMsg></cmmMsgHeader></OpenAPI_ServiceResponse>'
Invoke-RetryCase 'H HTTP 200 ServiceKey error fail immediately' @([pscustomobject]@{StatusCode=200;Content=$auth}) 1 $true
Invoke-RetryCase 'Invalid XML is not saved' @([pscustomobject]@{StatusCode=200;Content='broken'}) 1 $true
Write-Host 'MOLIT retry classification, secret redaction, backoff and failing request diagnostics passed.'
