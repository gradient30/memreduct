# Exercise the Web controller against an isolated fake Mihomo API.
# This test never switches the user's real Clash nodes.
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('memreduct clash test ' + [guid]::NewGuid().ToString('N'))
$webDir = Join-Path $testRoot 'webui'
$scriptsDir = Join-Path $testRoot 'scripts'
$serverProcess = $null
$controllerProcess = $null
$pipeProcess = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Status([int]$Expected, [scriptblock]$Request) {
    try { & $Request | Out-Null }
    catch {
        $response = $_.Exception.Response
        if ($response -and [int]$response.StatusCode -eq $Expected) { return }
        throw
    }
    throw "Expected HTTP $Expected"
}

try {
    New-Item -ItemType Directory -Path $webDir, $scriptsDir | Out-Null
    $portFile = Join-Path $testRoot 'controller-port.txt'
    $fakePath = (Resolve-Path (Join-Path $PSScriptRoot 'fake_clash_controller.py')).Path
    $controllerProcess = Start-Process -FilePath (Get-Command python.exe).Source -WindowStyle Hidden -PassThru -ArgumentList @(('"{0}"' -f $fakePath), ('"{0}"' -f $portFile))
    for ($i = 0; $i -lt 80 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $portFile)) { throw 'Fake controller failed to start' }
    $controllerPort = [int](Get-Content -LiteralPath $portFile -Raw)

    $configPath = Join-Path $testRoot 'clash-verge.yaml'
    $config = "external-controller: 127.0.0.1:$controllerPort`nexternal-controller-pipe: ''`nsecret: test-only-secret`ncfw-latency-url: https://latency.example/test`ncfw-latency-timeout: 3500`n"
    [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($true))

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $source = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\webui\server.ps1')).Path)
    $updated = [regex]::Replace($source, '(?m)^\$Port\s*=\s*8765\s*$', ('$Port = ' + $port))
    if ($updated -eq $source) { throw 'Unable to select an isolated test port' }
    [IO.File]::WriteAllText((Join-Path $webDir 'server.ps1'), $updated, [Text.UTF8Encoding]::new($true))
    Copy-Item (Join-Path $PSScriptRoot '..\webui\index.html') (Join-Path $webDir 'index.html')
    foreach ($name in @('clash.ps1', 'clash.html')) {
        $path = Join-Path $PSScriptRoot ('..\webui\' + $name)
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $webDir $name) }
    }
    Copy-Item (Join-Path $PSScriptRoot '..\scripts\mem-clean.ps1') (Join-Path $scriptsDir 'mem-clean.ps1')

    $escapedConfig = $configPath.Replace("'", "''")
    $wrapper = "`$env:MEMREDUCT_CLASH_CONFIG = '$escapedConfig'`n& (Join-Path `$PSScriptRoot 'webui\server.ps1')`n"
    $wrapperPath = Join-Path $testRoot 'run.ps1'
    [IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($true))
    $serverProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $wrapperPath))
    $base = "http://127.0.0.1:$port"
    $ready = $false
    for ($i = 0; $i -lt 80; $i++) {
        try { $null = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 2; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 150 }
    }
    if (-not $ready) { throw 'Isolated Web server did not start' }
    $monitorPage = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 5
    Assert-True ($monitorPage.Content -match 'href="/clash"') 'Monitoring page does not link to the proxy page'

    $model = Invoke-RestMethod -Uri "$base/api/clash" -TimeoutSec 10
    Assert-True ($model.ok -and $model.groups.Count -eq 1) 'Selector groups were not returned'
    Assert-True ($model.groups[0].now -eq '日本/JP' -and $model.groups[0].all.Count -eq 3) 'Wrong group or node state'
    Assert-True (($model | ConvertTo-Json -Depth 10) -notmatch 'test-only-secret') 'Controller secret leaked to browser'
    $page = Invoke-WebRequest -Uri "$base/clash" -UseBasicParsing -TimeoutSec 5
    Assert-True ($page.StatusCode -eq 200 -and $page.Content -match '代理节点') 'Proxy page unavailable'

    $group = [Uri]::EscapeDataString('节点选择')
    $auto = [Uri]::EscapeDataString('自动选择')
    $missing = [Uri]::EscapeDataString('不存在')
    $endpoint = "$base/api/clash/select?group=$group&node=$auto"
    Assert-Status 403 { Invoke-WebRequest -Uri $endpoint -Method Post -Headers @{ Origin = 'https://untrusted.example' } -UseBasicParsing -TimeoutSec 5 }
    Assert-Status 403 { Invoke-WebRequest -Uri $endpoint -Method Post -UseBasicParsing -TimeoutSec 5 }
    Assert-Status 403 { Invoke-WebRequest -Uri "$base/api/clash" -Headers @{ Origin = 'https://untrusted.example' } -UseBasicParsing -TimeoutSec 5 }
    $rebind = & curl.exe --noproxy '*' --silent --output NUL --write-out '%{http_code}' -H "Host: attacker.example:$port" -H "Origin: http://attacker.example:$port" "$base/api/clash"
    Assert-True ($rebind -eq '403') 'Untrusted Host was accepted (DNS rebinding)'
    foreach ($variant in @('/api/CLASH/select', '/API/clash/select', '/Api/ClAsH/select')) {
        $variantEndpoint = "$base${variant}?group=$group&node=$auto"
        Assert-Status 403 { Invoke-WebRequest -Uri $variantEndpoint -Method Post -Headers @{ Origin = 'https://untrusted.example' } -UseBasicParsing -TimeoutSec 5 }
        Assert-Status 403 { Invoke-WebRequest -Uri $variantEndpoint -Method Post -UseBasicParsing -TimeoutSec 5 }
        Assert-Status 403 { Invoke-WebRequest -Uri $variantEndpoint -Method Options -Headers @{ Origin = 'https://untrusted.example' } -UseBasicParsing -TimeoutSec 5 }
        $rebind = & curl.exe --noproxy '*' --silent --output NUL --write-out '%{http_code}' -H "Host: attacker.example:$port" -H "Origin: http://attacker.example:$port" $variantEndpoint
        Assert-True ($rebind -eq '403') "Untrusted Host was accepted for $variant"
    }
    # PowerShell's culture-sensitive switch can ignore embedded control bytes.
    # Reject such malformed request targets before they reach route dispatch.
    $rawClient = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    try {
        $rawClient.ReceiveTimeout = 5000
        $rawStream = $rawClient.GetStream()
        $rawPath = '/api/c' + [char]0 + "lash/select?group=$group&node=$auto"
        $rawRequest = "POST $rawPath HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nOrigin: https://untrusted.example`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($rawRequest)
        $rawStream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($rawStream, [Text.Encoding]::ASCII)
        $statusLine = $reader.ReadLine()
        Assert-True ($statusLine -match '^HTTP/1\.1 400\b') "Malformed request target was accepted: $statusLine"
    }
    finally { $rawClient.Close() }
    $unchanged = Invoke-RestMethod -Uri "$base/api/clash" -TimeoutSec 5
    Assert-True ($unchanged.groups[0].now -eq '日本/JP') 'Rejected request changed the selected node'

    $japan = [Uri]::EscapeDataString('日本/JP')
    $validVariant = Invoke-RestMethod -Uri "$base/API/ClAsH/select?group=$group&node=$japan" -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    Assert-True $validVariant.ok 'Same-origin selection with a mixed-case path failed'

    $result = Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    Assert-True $result.ok 'Valid selection failed'
    $changed = Invoke-RestMethod -Uri "$base/api/clash" -TimeoutSec 5
    Assert-True ($changed.groups[0].now -eq '自动选择') 'Controller selection was not updated'
    Assert-Status 400 { Invoke-WebRequest -Uri "$base/api/clash/select?group=$group&node=$missing" -Method Post -Headers @{ Origin = $base } -UseBasicParsing -TimeoutSec 5 }

    $slow = [Uri]::EscapeDataString('测试慢')
    $start = Invoke-RestMethod -Uri "$base/api/clash/delay/start?group=$group&node=$slow" -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    Assert-True ($start.ok -and $start.id) 'Delay test did not start'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 3
    $watch.Stop()
    Assert-True ($watch.ElapsedMilliseconds -lt 2500) 'Delay testing blocked the monitoring service'
    $done = $false
    for ($i = 0; $i -lt 120; $i++) {
        $status = Invoke-RestMethod -Uri "$base/api/clash/delay/status?id=$($start.id)" -TimeoutSec 5
        if ($status.state -eq 'done') { $done = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert-True ($done -and $status.results.Count -eq 1 -and $status.results[0].delay -eq 123) 'Delay result missing or incorrect'
    $start = Invoke-RestMethod -Uri "$base/api/clash/delay/start?group=$group&node=$slow" -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    $current = Invoke-RestMethod -Uri "$base/api/clash/delay/current" -TimeoutSec 5
    Assert-True ($current.id -eq $start.id -and $current.state -eq 'running') 'Active delay task cannot be resumed after a page refresh'
    Assert-Status 409 { Invoke-WebRequest -Uri "$base/api/clash/delay/start?group=$group&node=$slow" -Method Post -Headers @{ Origin = $base } -UseBasicParsing -TimeoutSec 5 }
    $cancel = Invoke-RestMethod -Uri "$base/api/clash/delay/cancel?id=$($start.id)" -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    Assert-True $cancel.ok 'Delay test could not be cancelled'
    $status = Invoke-RestMethod -Uri "$base/api/clash/delay/status?id=$($start.id)" -TimeoutSec 5
    Assert-True ($status.state -eq 'cancelled') 'Cancelled delay test has the wrong state'

    $start = Invoke-RestMethod -Uri "$base/api/clash/delay/start?group=$group" -Method Post -Headers @{ Origin = $base } -TimeoutSec 5
    $done = $false
    for ($i = 0; $i -lt 120; $i++) {
        $status = Invoke-RestMethod -Uri "$base/api/clash/delay/status?id=$($start.id)" -TimeoutSec 5
        if ($status.state -eq 'done') { $done = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not ($done -and $status.total -eq 3 -and $status.results.Count -eq 3)) {
        throw ('Group delay test did not return all node results: ' + ($status | ConvertTo-Json -Depth 6 -Compress))
    }
    Assert-True (@($status.results | Where-Object { $_.delay -ne 123 }).Count -eq 0) 'A group delay result was incorrect'

    $pipeName = 'memreduct-test-' + [guid]::NewGuid().ToString('N')
    $pipeReady = Join-Path $testRoot 'pipe-ready.txt'
    $pipeFixture = (Resolve-Path (Join-Path $PSScriptRoot 'fake_clash_pipe.py')).Path
    $pipeProcess = Start-Process -FilePath (Get-Command python.exe).Source -WindowStyle Hidden -PassThru -ArgumentList @(('"{0}"' -f $pipeFixture), $pipeName, $controllerPort, ('"{0}"' -f $pipeReady))
    for ($i = 0; $i -lt 80 -and -not (Test-Path -LiteralPath $pipeReady); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $pipeReady)) { throw 'Fake named pipe failed to start' }
    $pipeConfig = "external-controller: ''`nexternal-controller-pipe: \\.\pipe\$pipeName`nsecret: test-only-secret`ncfw-latency-url: https://latency.example/test`ncfw-latency-timeout: 3500`n"
    [IO.File]::WriteAllText($configPath, $pipeConfig, [Text.UTF8Encoding]::new($true))
    $pipeModel = Invoke-RestMethod -Uri "$base/api/clash" -TimeoutSec 10
    Assert-True ($pipeModel.groups[0].now -eq '自动选择') 'Named-pipe controller could not be read'
    $japan = [Uri]::EscapeDataString('日本/JP')
    $pipeSwitch = Invoke-RestMethod -Uri "$base/api/clash/select?group=$group&node=$japan" -Method Post -Headers @{ Origin = $base } -TimeoutSec 10
    Assert-True $pipeSwitch.ok 'Named-pipe node switch failed'
    $pipeModel = Invoke-RestMethod -Uri "$base/api/clash" -TimeoutSec 10
    Assert-True ($pipeModel.groups[0].now -eq '日本/JP') 'Named-pipe switch did not persist'
    Stop-Process -Id $pipeProcess.Id -Force
    $pipeProcess.WaitForExit()
    Assert-Status 503 { Invoke-WebRequest -Uri "$base/api/clash" -UseBasicParsing -TimeoutSec 8 }
    Write-Host 'PASS: proxy page, selection, asynchronous delay, authorization, and same-origin boundaries'
}
finally {
    foreach ($process in @($serverProcess, $controllerProcess, $pipeProcess)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory outside TEMP' }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
