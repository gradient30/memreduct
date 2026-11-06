#Requires -Version 5.1
<#
	MEM.REDUCT webui — 轻量本机监控服务 (零依赖)

	- 仅使用 PowerShell 内置 TcpListener + CIM, 无需管理员权限
	- 查询结果带 TTL 缓存: stats 2s / temp 8s / drive 60s, 多标签页不放大开销
	- 无请求时完全空闲, 零 CPU 占用
	- 内存清理 (POST /api/clean): 调用 scripts/mem-clean.ps1 (与 exe --clean 同源 NT 机制, 需提权)
	  · 本服务以管理员运行 -> 直接执行
	  · 已安装计划任务桥 -> 使用 MemReduct-Clean
	  · 本机页面且无计划任务桥 -> 弹出 Windows 管理员授权后执行
	- 启动:  powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1
	- 访问:  本机 http://127.0.0.1:8765/ ; Tailnet 设备 http://<tailscale-ip>:8765/
	- Tailnet 入站需一次性放行防火墙(管理员): 运行 add_firewall_rule.ps1
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ========================= 配置 =========================
$Port         = 8765
$MemReductExe = Join-Path $PSScriptRoot '..\bin\64\memreduct.exe'
$HtmlPath     = Join-Path $PSScriptRoot 'index.html'

# 内存清理: 独立脚本 (scripts/mem-clean.ps1) 优先, 需要管理员权限才能真正清理
$CleanScript    = Join-Path $PSScriptRoot '..\scripts\mem-clean.ps1'
$CleanTaskName  = 'MemReduct-Clean'                                              # 计划任务桥 (install_clean_task.ps1 注册)
$CleanResult    = Join-Path $env:ProgramData 'memreduct\clean-result.json'       # 任务桥结果文件
$CleanTimeoutS  = 150                                                            # 清理最长等待 (秒)
$CleanElevated  = [bool](New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 跨源接入 (其它项目的 web 页面直接调用本服务):
#   $CorsOrigins — 允许跨源的页面来源; '*' = 任意 (个人机器便捷默认); 收紧示例: @('http://localhost:3000','https://myapp.example.com')
#   $ApiKey      — 非空时 /api/* 要求请求头 X-Api-Key 或查询参数 ?key= 与之相等; 空 = 不校验
$CorsOrigins = @('*')
$ApiKey      = ''
# ========================================================

$script:Cache = @{}

function Get-Cached
{
	param ( [string]$Key, [int]$Ttl, [scriptblock]$Gen )
	$now = [DateTime]::UtcNow
	if ( $script:Cache.ContainsKey($Key) -and (($now - $script:Cache[$Key].At).TotalSeconds -lt $Ttl) )
	{
		return $script:Cache[$Key].V
	}
	$v = & $Gen
	$script:Cache[$Key] = @{ At = $now; V = $v }
	return $v
}

function Get-Ts
{
	[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-MemState
{
	$os = Get-CimInstance Win32_OperatingSystem
	$t = [double]$os.TotalVisibleMemorySize
	$f = [double]$os.FreePhysicalMemory
	$used = $t - $f
	return @{
		totalGB = [math]::Round($t / 1MB, 2)
		usedGB  = [math]::Round($used / 1MB, 2)
		pct     = [math]::Round($used / $t * 100, 1)
	}
}

# ---------- CPU / 内存 ----------
function Get-Stats
{
	Get-Cached 'stats' 2 {
		$c = Get-CimInstance Win32_Processor
		$cpu = ($c | Measure-Object -Property LoadPercentage -Average).Average
		if ( $null -eq $cpu ) { $cpu = 0 }

		$name = ($c | Select-Object -First 1).Name
		if ( $name ) { $name = $name.Trim() } else { $name = 'CPU' }

		$mem = Get-MemState

		[ordered]@{
			ok         = $true
			cpu        = [int][math]::Round($cpu)
			cpuName    = $name
			memTotalGB = $mem.totalGB
			memUsedGB  = $mem.usedGB
			memPct     = $mem.pct
			ts         = Get-Ts
		}
	}
}

# ---------- 温度传感器 (多源探测, 优雅降级) ----------
function Get-Temps
{
	Get-Cached 'temp' 8 {
		$sensors = @()
		$src = [ordered]@{ acpi = $false; gpu = $false; lhm = $false; lhmfile = $false; smart = $false }

		# 1) ACPI 热区 — 主板温度, 无需管理员
		$tz = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation
		foreach ( $z in @($tz) )
		{
			if ( $z.Temperature )
			{
				$c = [math]::Round([double]$z.Temperature - 273.15, 1)
				$sensors += [ordered]@{ id = 'acpi0'; kind = 'board'; name = '主板热区 (ACPI)'; c = $c }
				$src.acpi = $true
			}
		}

		# 2) NVIDIA GPU — nvidia-smi
		if ( Get-Command nvidia-smi -ErrorAction SilentlyContinue )
		{
			$out = & nvidia-smi --query-gpu=name,temperature.gpu --format=csv,noheader,nounits 2>$null
			if ( $out )
			{
				$i = 0
				foreach ( $line in @($out) )
				{
					$p = $line -split ','
					if ( $p.Count -ge 2 )
					{
						$sensors += [ordered]@{ id = "gpu$i"; kind = 'gpu'; name = 'GPU · ' + $p[0].Trim(); c = [double]$p[1].Trim() }
						$i++
						$src.gpu = $true
					}
				}
			}
		}

		# 3) LibreHardwareMonitor / OpenHardwareMonitor WMI — CPU 核心/主板/硬盘全量传感器
		$lhmSensors = $null
		$lhmHw = @{}
		foreach ( $ns in @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor') )
		{
			try
			{
				$lhmSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -Filter "SensorType='Temperature'" -ErrorAction Stop
				Get-CimInstance -Namespace $ns -ClassName Hardware -ErrorAction Stop | ForEach-Object { $lhmHw[$_.Identifier] = $_.Name }
				if ( $lhmSensors ) { break }
			}
			catch { $lhmSensors = $null }
		}
		if ( $lhmSensors )
		{
			$src.lhm = $true
			$i = 0
			foreach ( $s in @($lhmSensors) )
			{
				$hwName = ''
				if ( $lhmHw.ContainsKey($s.Parent) ) { $hwName = $lhmHw[$s.Parent] + ' / ' }
				$kind = 'other'
				$full = ('' + $s.Parent + ' ' + $s.Name)
				if ( $full -match 'cpu' ) { $kind = 'cpu' }
				elseif ( $full -match 'gpu|graphics' ) { $kind = 'gpu' }
				elseif ( $full -match 'hdd|ssd|disk|drive|nvme' ) { $kind = 'drive' }

				$sensors += [ordered]@{ id = "lhm$i"; kind = $kind; name = ($hwName + $s.Name); c = [math]::Round([double]$s.Value, 1) }
				$i++
			}
		}

		# 3.5) lhm_temps.txt — 提权 writer (memclean-svc/lhm_writer.py) 写入的实时传感器 (CPU核心/GPU热点/硬盘, 10s 刷新)
		$lhmFile = Join-Path $env:TEMP 'lhm_temps.txt'
		if ( Test-Path $lhmFile )
		{
			$fi = Get-Item $lhmFile -ErrorAction SilentlyContinue
			if ( $fi -and ((Get-Date) - $fi.LastWriteTime).TotalSeconds -le 30 )
			{
				$pick = New-Object System.Collections.Specialized.OrderedDictionary
				foreach ( $line in @(Get-Content $lhmFile -ErrorAction SilentlyContinue) )
				{
					$p = $line -split '\|'
					if ( $p.Count -ne 3 -or $p[0] -ne 'T' ) { continue }
					$nm = $p[1].Trim()
					$val = 0.0
					if ( -not [double]::TryParse($p[2].Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val) ) { continue }
					if ( $nm -eq 'CPU Package' )      { $pick['CPU 封装温度'] = @{ kind = 'cpu'; c = [math]::Round($val, 1) } }
					elseif ( $nm -eq 'Core Max' )     { $pick['CPU 核心峰值'] = @{ kind = 'cpu'; c = [math]::Round($val, 1) } }
					elseif ( $nm -eq 'Core Average' ) { $pick['CPU 核心均值'] = @{ kind = 'cpu'; c = [math]::Round($val, 1) } }
					elseif ( $nm -eq 'GPU Hot Spot' ) { $pick['GPU 热点'] = @{ kind = 'gpu'; c = [math]::Round($val, 1) } }
					elseif ( $nm -eq 'GPU Core' -and -not $src.gpu ) { $pick['GPU 核心'] = @{ kind = 'gpu'; c = [math]::Round($val, 1) } }
					elseif ( $nm -match '^ssd_' )     { $pick['固态硬盘 ' + $nm.ToUpper()] = @{ kind = 'drive'; c = [math]::Round($val, 1) } }
					elseif ( $nm -match '^hdd_' )     { $pick['机械硬盘 ' + $nm.ToUpper()] = @{ kind = 'drive'; c = [math]::Round($val, 1) } }
				}
				foreach ( $k in @($pick.Keys) )
				{
					$sensors += [ordered]@{ id = 'lhmf_' + $sensors.Count; kind = $pick[$k].kind; name = $k; c = $pick[$k].c }
				}
				if ( $pick.Count ) { $src.lhmfile = $true }
			}
		}

		# 4) 硬盘 SMART 温度 — 需要管理员权限, 失败则静默跳过
		try
		{
			foreach ( $d in @(Get-PhysicalDisk -ErrorAction Stop) )
			{
				$rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
				if ( $rc -and $rc.Temperature )
				{
					$sensors += [ordered]@{ id = 'smart_' + $d.DeviceId; kind = 'drive'; name = '硬盘 · ' + $d.FriendlyName; c = [math]::Round([double]$rc.Temperature, 1) }
					$src.smart = $true
				}
			}
		}
		catch {}

		# 统一排序: cpu -> gpu -> board -> drive -> other (多源合并后规整展示)
		$ko = @{ cpu = 0; gpu = 1; board = 2; drive = 3; other = 4 }
		$sensors = @($sensors | Sort-Object @{ Expression = { $ko[[string]$_.kind] } }, @{ Expression = { [string]$_.name } })
		[ordered]@{ ok = $true; sensors = @($sensors); sources = $src; ts = Get-Ts }
	}
}

# ---------- 磁盘 ----------
function Get-Drives
{
	Get-Cached 'drive' 60 {
		$arr = @()
		foreach ( $d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') )
		{
			$t = [double]$d.Size
			$f = [double]$d.FreeSpace
			$arr += [ordered]@{
				letter  = $d.DeviceID
				label   = ('' + $d.VolumeName)
				totalGB = [math]::Round($t / 1GB, 1)
				freeGB  = [math]::Round($f / 1GB, 1)
				usedPct = [math]::Round(($t - $f) / $t * 100, 1)
			}
		}
		[ordered]@{ ok = $true; drives = @($arr); ts = Get-Ts }
	}
}

# ---------- 内存清理 ----------
# 本服务提权时直接运行；否则优先使用已安装的计划任务桥。
# 桥不可用时，本机同源页面可请求一次 Windows UAC 授权。
function Read-CleanResult
{
	param ( [string]$Path )
	try
	{
		if ( Test-Path $Path )
		{
			$r = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
			if ( $null -ne $r ) { return $r }
		}
	}
	catch {}
	return $null
}

function Convert-ToClient
{
	param ( $R, [string]$Mode )
	if ( $null -eq $R )
	{
		return [ordered]@{ ok = $false; err = '清理结果解析失败'; mode = $Mode; ts = Get-Ts }
	}
	return [ordered]@{
		ok       = [bool]$R.ok
		mode     = $Mode
		beforeGB = [double]$R.beforeGB
		afterGB  = [double]$R.afterGB
		freedGB  = [double]$R.freedGB
		durationMs = [int]$R.durationMs
		err      = ( '' + $R.err )
		detail   = $R
		ts       = Get-Ts
	}
}

function Invoke-Clean
{
	$runScript = {
		param ( [bool]$RequireElevation )
		$mode = if ( $RequireElevation ) { 'uac' } else { 'direct' }
		$resultPath = Join-Path $env:TEMP ('memreduct-webui-clean-' + [guid]::NewGuid().ToString('N') + '.json')

		try
		{
			$startArgs = @{
				FilePath = 'powershell.exe'
				ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $CleanScript), '-Json', '-Quiet', '-ResultFile', ('"{0}"' -f $resultPath))
				WindowStyle = 'Hidden'
				PassThru = $true
				ErrorAction = 'Stop'
			}
			if ( $RequireElevation ) { $startArgs.Verb = 'RunAs' }

			$p = Start-Process @startArgs
			if ( -not $p ) { throw '清理进程未启动' }
			if ( -not ($p.WaitForExit($CleanTimeoutS * 1000) -or $p.HasExited) )
			{
				try { $p.Kill() } catch {}
				return [ordered]@{ ok = $false; err = "清理进程在 ${CleanTimeoutS}s 内未完成"; mode = $mode; ts = Get-Ts }
			}

			$r = Read-CleanResult $resultPath
			if ( -not $r )
			{
				return [ordered]@{ ok = $false; err = "清理进程未返回有效结果 (退出码 $($p.ExitCode))"; mode = $mode; ts = Get-Ts }
			}
			if ( -not [bool]$r.elevated )
			{
				return [ordered]@{ ok = $false; err = '清理进程未获得管理员权限'; mode = $mode; ts = Get-Ts }
			}
			return Convert-ToClient $r $mode
		}
		catch
		{
			$exception = $_.Exception
			if ( $RequireElevation -and (($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) -or ($exception.InnerException -is [ComponentModel.Win32Exception] -and $exception.InnerException.NativeErrorCode -eq 1223)) )
			{
				return [ordered]@{ ok = $false; err = '已取消管理员授权，未执行清理'; mode = $mode; ts = Get-Ts }
			}
			return [ordered]@{ ok = $false; err = ('无法启动清理进程: ' + $exception.Message); mode = $mode; ts = Get-Ts }
		}
		finally
		{
			Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
			Remove-Item -LiteralPath ($resultPath + '.tmp') -Force -ErrorAction SilentlyContinue
		}
	}

	# --- 1) 直连: 本服务以管理员运行 ---
	if ( $CleanElevated -and (Test-Path $CleanScript) )
	{
		return (& $runScript $false)
	}

	# --- 2) 计划任务桥: 非提权也能触发 (管理员运行一次 scripts/install_clean_task.ps1 安装) ---
	$task = Get-ScheduledTask -TaskName $CleanTaskName -ErrorAction SilentlyContinue
	if ( $task )
	{
		$oldTs = 0
		$prev = Read-CleanResult $CleanResult
		if ( $prev ) { $oldTs = [int64]$prev.ts }

		Start-ScheduledTask -TaskName $CleanTaskName -ErrorAction SilentlyContinue

		$deadline = (Get-Date).AddSeconds($CleanTimeoutS)
		while ( (Get-Date) -lt $deadline )
		{
			Start-Sleep -Milliseconds 700
			$r = Read-CleanResult $CleanResult
			if ( $r -and ( ([int64]$r.ts) -gt $oldTs ) )
			{
				return Convert-ToClient $r 'task'
			}
		}
		return [ordered]@{ ok = $false; err = "计划任务 ${CleanTaskName} 已触发但 ${CleanTimeoutS}s 内未返回结果"; mode = 'task'; ts = Get-Ts }
	}

	# --- 3) 本机页面按需请求 UAC; 不为远程或跨源请求弹授权窗口 ---
	$localOrigins = @("http://127.0.0.1:$Port", "http://localhost:$Port", "http://[::1]:$Port")
	if ( -not $CleanElevated -and $script:ReqIsLocal -and (-not $script:ReqOrigin -or $localOrigins -contains $script:ReqOrigin) -and (Test-Path $CleanScript) )
	{
		return (& $runScript $true)
	}

	# --- 4) 回退: exe (仅当本服务提权时 exe 的清理才真正生效) ---
	if ( $CleanElevated -and (Test-Path $MemReductExe) )
	{
		$b = Get-MemState
		Start-Process -FilePath $MemReductExe -ArgumentList '--clean' -WindowStyle Hidden -Wait
		Start-Sleep -Milliseconds 400
		$a = Get-MemState
		return [ordered]@{
			ok       = $true
			mode     = 'exe'
			beforeGB = [math]::Round($b.usedGB, 2)
			afterGB  = [math]::Round($a.usedGB, 2)
			freedGB  = [math]::Round($b.usedGB - $a.usedGB, 2)
			ts       = Get-Ts
		}
	}

	# --- 均不可用 ---
	$hint = "清理功能未就绪: 请在本机监控页面执行清理并确认 Windows 管理员授权，或以管理员运行 scripts/install_clean_task.ps1 安装计划任务桥"
	return [ordered]@{ ok = $false; err = $hint; mode = 'none'; ts = Get-Ts }
}

# ---------- HTTP ----------
# 依据请求 Origin 计算 Access-Control-Allow-Origin 行 (无 Origin 或不在白名单时返回空)
function Get-CorsLine
{
	$origin = $script:ReqOrigin
	if ( -not $origin ) { return '' }
	if ( $CorsOrigins -contains '*' ) { return "Access-Control-Allow-Origin: *`r`n" }
	if ( $CorsOrigins -contains $origin ) { return "Access-Control-Allow-Origin: $origin`r`n" + "Vary: Origin`r`n" }
	return ''
}

function Send-Response
{
	param ( $Stream, [string]$Type, [byte[]]$Bytes, [int]$Code = 200 )
	$reason = 'OK'
	if ( $Code -eq 204 ) { $reason = 'No Content' }
	if ( $Code -eq 401 ) { $reason = 'Unauthorized' }
	if ( $Code -eq 403 ) { $reason = 'Forbidden' }
	if ( $Code -eq 404 ) { $reason = 'Not Found' }
	if ( $Code -eq 405 ) { $reason = 'Method Not Allowed' }
	$head = "HTTP/1.1 $Code $reason`r`nContent-Type: $Type`r`nContent-Length: $($Bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n"
	$head += (Get-CorsLine)
	$head += "`r`n"
	$hb = [Text.Encoding]::ASCII.GetBytes($head)
	$Stream.Write($hb, 0, $hb.Length)
	if ( $Bytes.Length -gt 0 ) { $Stream.Write($Bytes, 0, $Bytes.Length) }
	$Stream.Flush()
}

# CORS 预检 (浏览器在跨源 POST / 带自定义头前会先发 OPTIONS)
function Send-Preflight
{
	param ( $Stream )
	$cors = Get-CorsLine
	if ( -not $cors )
	{
		# 无 Origin 或来源不在白名单 — 不给跨源许可
		Send-Response $Stream 'text/plain' ([Text.Encoding]::ASCII.GetBytes('origin not allowed')) 403
		return
	}
	$head = "HTTP/1.1 204 No Content`r`nContent-Length: 0`r`nConnection: close`r`n" +
		$cors +
		"Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
		"Access-Control-Allow-Headers: Content-Type, X-Api-Key`r`n" +
		"Access-Control-Max-Age: 86400`r`n"
	# Private Network Access: 公网 HTTPS 页面请求本机回环地址时, 新版 Chrome 预检会要求此头
	if ( $script:ReqPna ) { $head += "Access-Control-Allow-Private-Network: true`r`n" }
	$head += "`r`n"
	$hb = [Text.Encoding]::ASCII.GetBytes($head)
	$Stream.Write($hb, 0, $hb.Length)
	$Stream.Flush()
}

# ApiKey 校验 ($ApiKey 非空时启用): 请求头 X-Api-Key 或查询参数 ?key=
function Test-ApiKey
{
	if ( -not $ApiKey ) { return $true }
	if ( $script:ReqKey -and ($script:ReqKey -eq $ApiKey) ) { return $true }
	return $false
}

function Send-Json
{
	param ( $Stream, $Obj )
	$json = [Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 6 -Compress))
	Send-Response $Stream 'application/json; charset=utf-8' $json
}

$HtmlBytes = $null
if ( Test-Path $HtmlPath ) { $HtmlBytes = [IO.File]::ReadAllBytes($HtmlPath) }

# 绑定地址: 本机回环 + Tailscale 网卡 (100.64.0.0/10 段, 不绑定局域网)
$bindIps = @([Net.IPAddress]::Loopback)
$tsIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
	Where-Object { $_.IPAddress -match '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' } |
	Select-Object -ExpandProperty IPAddress -Unique)
foreach ( $ip in $tsIps ) { $bindIps += [Net.IPAddress]::Parse($ip) }

$listeners = @()
foreach ( $ip in $bindIps )
{
	try
	{
		$l = [System.Net.Sockets.TcpListener]::new($ip, $Port)
		$l.Start()
		$listeners += $l
	}
	catch { Write-Host ("  绑定失败 {0}: {1}" -f $ip, $_.Exception.Message) -ForegroundColor DarkGray }
}

if ( -not $listeners.Count )
{
	Write-Host "端口 $Port 被占用或无法监听" -ForegroundColor Red
	exit 1
}

# 多监听: 异步等待任一地址到达的连接
$tasks = New-Object System.Collections.ArrayList
foreach ( $l in $listeners ) { [void]$tasks.Add($l.AcceptTcpClientAsync()) }

Write-Host ''
Write-Host '  MEM.REDUCT 系统监控台 — 服务已启动' -ForegroundColor Yellow
Write-Host "  本机:     http://127.0.0.1:$Port/" -ForegroundColor Yellow
foreach ( $ip in $tsIps ) { Write-Host "  Tailnet:  http://${ip}:$Port/  (仅你 Tailnet 内的设备)" -ForegroundColor Yellow }
Write-Host '  停止:  Ctrl+C' -ForegroundColor DarkGray
Write-Host ''

while ( $true )
{
	$client = $null
	$idx = [System.Threading.Tasks.Task]::WaitAny($tasks.ToArray())
	try { $client = $tasks[$idx].Result }
	catch { Write-Host '监听器故障, 服务退出' -ForegroundColor Red; exit 1 }
	try { $tasks[$idx] = $listeners[$idx].AcceptTcpClientAsync() }
	catch { Write-Host '监听器故障, 服务退出' -ForegroundColor Red; exit 1 }
	try
	{
		$stream = $client.GetStream()
		$stream.ReadTimeout = 5000
		$stream.WriteTimeout = 15000

		# 读取请求头
		$buf = New-Object byte[] 16384
		$data = ''
		while ( $data -notmatch "`r`n`r`n" )
		{
			$n = $stream.Read($buf, 0, $buf.Length)
			if ( $n -le 0 ) { break }
			$data += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
		}
		if ( -not $data ) { continue }

		$first  = ($data -split "`r`n")[0]
		$parts  = $first -split ' '
		if ( $parts.Count -lt 2 ) { continue }
		$method = $parts[0]
		$path   = ($parts[1] -split '\?')[0]

		# 跨源支持: 提取请求 Origin 与 ApiKey (头 X-Api-Key 或 ?key=)
		$script:ReqOrigin = $null
		$script:ReqKey    = $null
		$script:ReqPna    = $false
		$script:ReqIsLocal = [Net.IPAddress]::IsLoopback(([Net.IPEndPoint]$client.Client.RemoteEndPoint).Address)
		if ( $data -match '(?im)^origin:[ \t]*([^\r\n]+)' ) { $script:ReqOrigin = $Matches[1].Trim() }
		if ( $data -match '(?im)^x-api-key:[ \t]*([^\r\n]+)' ) { $script:ReqKey = $Matches[1].Trim() }
		if ( $data -match '(?im)^access-control-request-private-network:[ \t]*true' ) { $script:ReqPna = $true }
		if ( $parts[1] -match '[?&]key=([^&\s]+)' ) { $script:ReqKey = [Uri]::UnescapeDataString($Matches[1]) }

		# CORS 预检请求 — 浏览器跨源 POST 前必经
		if ( $method -eq 'OPTIONS' ) { Send-Preflight $stream; continue }

		# /api/* 在启用 $ApiKey 时校验
		if ( $path -like '/api/*' -and -not (Test-ApiKey) )
		{
			Send-Response $stream 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('{"ok":false,"err":"invalid api key"}')) 401
			continue
		}

		switch ( $path )
		{
			'/'
			{
				if ( $HtmlBytes ) { Send-Response $stream 'text/html; charset=utf-8' $HtmlBytes }
				else { Send-Response $stream 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('index.html 缺失')) 404 }
			}
			'/index.html'
			{
				if ( $HtmlBytes ) { Send-Response $stream 'text/html; charset=utf-8' $HtmlBytes }
				else { Send-Response $stream 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('index.html 缺失')) 404 }
			}
			'/favicon.ico'
			{
				$ico = [Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#0a0e12"/><rect x="3" y="3" width="10" height="10" fill="none" stroke="#ffb000" stroke-width="1.5"/><rect x="6.5" y="6.5" width="3" height="3" fill="#ffb000"/></svg>')
				Send-Response $stream 'image/svg+xml' $ico
			}
			'/api/stats' { Send-Json $stream (Get-Stats) }
			'/api/temp'  { Send-Json $stream (Get-Temps) }
			'/api/drive' { Send-Json $stream (Get-Drives) }
			'/api/clean'
			{
				if ( $method -eq 'POST' )
				{
					Write-Host ("[{0}] 触发内存清理" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
					Send-Json $stream (Invoke-Clean)
				}
				else { Send-Response $stream 'text/plain' ([Text.Encoding]::ASCII.GetBytes('POST only')) 405 }
			}
			default { Send-Response $stream 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('404 · 监控台地址是 http://127.0.0.1:' + $Port + '/ (收到路径: ' + $path + ')')) 404 }
		}
	}
	catch {}
	finally
	{
		if ( $client ) { $client.Close() }
	}
}
