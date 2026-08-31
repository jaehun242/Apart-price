# PowerShell 7/.NET transport: independent connection and response deadlines.
function Invoke-MolitHttpResponse {
  param([string]$Uri, [int]$ConnectTimeoutSec, [int]$ReadTimeoutSec)
  $handler = [Net.Http.SocketsHttpHandler]::new()
  $handler.ConnectTimeout = [TimeSpan]::FromSeconds($ConnectTimeoutSec)
  $handler.AllowAutoRedirect = $false
  $handler.AutomaticDecompression = [Net.DecompressionMethods]::All
  $client = [Net.Http.HttpClient]::new($handler)
  $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
  $headerDeadline = [Threading.CancellationTokenSource]::new()
  $bodyDeadline = [Threading.CancellationTokenSource]::new()
  $response = $null
  try {
    $headerDeadline.CancelAfter([TimeSpan]::FromSeconds($ConnectTimeoutSec + $ReadTimeoutSec))
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    try {
      $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $headerDeadline.Token).GetAwaiter().GetResult()
    } finally { $request.Dispose() }
    if ([int]$response.StatusCode -in @(401,403)) {
      return [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Content = '' }
    }
    $bodyDeadline.CancelAfter([TimeSpan]::FromSeconds($ReadTimeoutSec))
    $body = $response.Content.ReadAsStringAsync($bodyDeadline.Token).GetAwaiter().GetResult()
    return [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Content = $body }
  } finally {
    if ($response) { $response.Dispose() }
    $headerDeadline.Dispose(); $bodyDeadline.Dispose(); $client.Dispose()
  }
}

function Get-MolitBackoffSeconds {
  param([int]$Attempt)
  return @(5, 15, 30, 60, 120)[[Math]::Min([Math]::Max($Attempt - 1, 0), 4)]
}
