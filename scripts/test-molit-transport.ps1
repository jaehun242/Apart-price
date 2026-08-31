[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'molit-http.ps1')
# A real local HTTP socket accepts the connection but stalls the body.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$job = Start-ThreadJob -ArgumentList $listener -ScriptBlock {
  param($Listener)
  $client = $Listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
    while ($reader.ReadLine()) {}
    $headers = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 3`r`nConnection: close`r`n`r`n")
    $stream.Write($headers); $stream.Flush()
    Start-Sleep -Seconds 3
    try { $stream.Write([Text.Encoding]::ASCII.GetBytes('abc')) } catch {}
  } finally { $client.Dispose(); $Listener.Stop() }
}
try {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $failed = $false
  try { Invoke-MolitHttpResponse -Uri "http://127.0.0.1:$port/slow" -ConnectTimeoutSec 1 -ReadTimeoutSec 1 | Out-Null }
  catch { $failed = $true }
  $watch.Stop()
  if (-not $failed -or $watch.Elapsed.TotalSeconds -gt 4) { throw 'Read deadline did not stop the stalled response' }
  Write-Host "PASS actual socket read timeout: $([Math]::Round($watch.Elapsed.TotalSeconds,2))s"
} finally {
  $job | Wait-Job -Timeout 5 | Out-Null
  if ($job.State -notin @('Completed','Failed','Stopped')) { Stop-Job $job }
  Remove-Job $job -Force
  $listener.Stop()
}
