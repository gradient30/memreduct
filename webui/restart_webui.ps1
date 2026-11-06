#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param()

$ErrorActionPreference = 'Stop'
$serverPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'server.ps1')).Path
$port = 8765
$listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
$listenerPids = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
if ($listenerPids.Count -gt 1) { throw "端口 $port 存在多个监听进程，请先检查。" }

$existing = $null
if ($listenerPids.Count -eq 1) {
    $existing = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $listenerPids[0])
    if (-not $existing -or $existing.Name -ne 'powershell.exe' -or -not $existing.CommandLine -or
        $existing.CommandLine.IndexOf($serverPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "端口 $port 被其他程序占用，未停止任何进程。"
    }
}

if (-not $PSCmdlet.ShouldProcess("127.0.0.1:$port", '重启 MEM.REDUCT Web 服务')) { return }
if ($existing) {
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $existing.ProcessId)
    if (-not $current -or $current.CreationDate -ne $existing.CreationDate) { throw '服务进程已变化，请重试。' }
    Stop-Process -Id $existing.ProcessId -ErrorAction Stop
    Wait-Process -Id $existing.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
}

$process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -WorkingDirectory (Split-Path -Parent $PSScriptRoot) `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $serverPath))
$ready = $false
for ($i = 0; $i -lt 80; $i++) {
    if ($process.HasExited) { throw "Web 服务已退出，退出码 $($process.ExitCode)。" }
    try {
        $page = Invoke-WebRequest -Uri "http://127.0.0.1:$port/clash" -UseBasicParsing -TimeoutSec 2
        if ($page.StatusCode -eq 200) { $ready = $true; break }
    }
    catch { Start-Sleep -Milliseconds 150 }
}
if (-not $ready) { throw 'Web 服务未在预期时间内启动，请检查端口及服务输出。' }
Write-Host "Web 服务已重启。代理节点页面：http://127.0.0.1:$port/clash" -ForegroundColor Green
