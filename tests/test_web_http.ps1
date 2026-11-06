# Start an isolated copy of the real HTTP service. Elevation is simulated so
# this test never cleans memory, creates tasks, or displays a UAC prompt.
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('memreduct web test ' + [guid]::NewGuid().ToString('N'))
$webDir = Join-Path $testRoot 'webui'
$scriptsDir = Join-Path $testRoot 'scripts'
$serverProcess = $null

try {
    New-Item -ItemType Directory -Path $webDir, $scriptsDir | Out-Null
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()

    $source = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\webui\server.ps1')).Path)
    $updated = [regex]::Replace($source, '(?m)^\$Port\s*=\s*8765\s*$', ('$Port = ' + $port))
    if ($updated -eq $source) { throw 'Unable to select an isolated test port' }
    [IO.File]::WriteAllText((Join-Path $webDir 'server.ps1'), $updated, [Text.UTF8Encoding]::new($true))
    Copy-Item (Join-Path $PSScriptRoot '..\webui\index.html') (Join-Path $webDir 'index.html')
    Copy-Item (Join-Path $PSScriptRoot '..\scripts\mem-clean.ps1') (Join-Path $scriptsDir 'mem-clean.ps1')

    $wrapper = @'
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $null }
function Start-Process {
    param($FilePath, $ArgumentList, $PassThru, $WindowStyle, $Verb, $ErrorAction)
    if ($Verb -ne 'RunAs') { throw 'Expected UAC elevation' }
    if (Test-Path (Join-Path $PSScriptRoot 'deny')) { throw [ComponentModel.Win32Exception]::new(1223) }
    $index = [array]::IndexOf($ArgumentList, '-ResultFile')
    if ($index -lt 0) { throw 'Missing result file' }
    $resultPath = ([string]$ArgumentList[$index + 1]).Trim('"')
    [IO.File]::WriteAllText($resultPath, '{"ok":true,"elevated":true,"beforeGB":20,"afterGB":18,"freedGB":2,"durationMs":42,"ts":1}')
    $p = [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
    return $p
}
& (Join-Path $PSScriptRoot 'webui\server.ps1')
'@
    $wrapperPath = Join-Path $testRoot 'run.ps1'
    [IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($true))
    $serverProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $wrapperPath))

    $base = "http://127.0.0.1:$port"
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try { $null = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 2; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'Isolated HTTP server did not start' }

    $result = Invoke-RestMethod -Uri "$base/api/clean" -Method Post -Headers @{ Origin = $base } -TimeoutSec 10
    if (-not $result.ok -or $result.mode -ne 'uac' -or $result.freedGB -ne 2) { throw "Unexpected cleanup response: $($result | ConvertTo-Json -Compress)" }

    $result = Invoke-RestMethod -Uri "$base/api/clean" -Method Post -Headers @{ Origin = 'https://untrusted.example' } -TimeoutSec 10
    if ($result.ok -or $result.mode -ne 'none') { throw 'A cross-origin request triggered elevation' }

    [IO.File]::WriteAllText((Join-Path $testRoot 'deny'), '1')
    $result = Invoke-RestMethod -Uri "$base/api/clean" -Method Post -Headers @{ Origin = $base } -TimeoutSec 10
    if ($result.ok -or $result.mode -ne 'uac' -or $result.err -notmatch '取消') { throw "UAC cancellation was not reported correctly: $($result | ConvertTo-Json -Compress)" }
    Write-Host 'PASS: HTTP cleanup, same-origin boundary, UAC cancellation, and paths with spaces'
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory outside TEMP' }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
