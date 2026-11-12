#Requires -Version 5.1
<#
.SYNOPSIS
	安装/卸载 MEM.REDUCT 清理计划任务桥 — 让非提权进程 (webui / 其它项目) 也能触发真实清理。

.DESCRIPTION
	mem-clean.ps1 需要管理员令牌才能执行 NT 层清理。本脚本一次性注册:

	  MemReduct-Clean      按需任务: 任意进程可 `schtasks /run /tn MemReduct-Clean` 触发,
	                       结果 JSON 写入 %ProgramData%\memreduct\clean-result.json
	  MemReduct-DailyClean 每日任务 (可选 -Daily 23:00):
	                       若已存在旧版 (exe --clean, RunLevel=Limited, 实际从未真正清理过),
	                       将被本脚本重建为 RunLevel=Highest + mem-clean.ps1, 从此真正生效。

	以当前登录用户注册 (Interactive + Highest), 无需存储密码; 用户登录状态下即可触发。

.EXAMPLE
	# 管理员 PowerShell 中运行一次 (安装按需任务):
	powershell -ExecutionPolicy Bypass -File install_clean_task.ps1

	# 安装并同时接管每日 23:00 定时清理:
	powershell -ExecutionPolicy Bypass -File install_clean_task.ps1 -Daily 23:00

	# 安装后立即做一次端到端冒烟测试 (触发任务并等待结果):
	powershell -ExecutionPolicy Bypass -File install_clean_task.ps1 -Test

	# 卸载全部:
	powershell -ExecutionPolicy Bypass -File install_clean_task.ps1 -Uninstall
#>

[CmdletBinding()]
param (
	# 同时重建每日定时清理任务 MemReduct-DailyClean (值为本地时间, 如 23:00)
	[string]$Daily = '',

	# 安装后立即触发一次按需任务并校验结果文件
	[switch]$Test,

	[switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$TaskNameOnDemand = 'MemReduct-Clean'
$TaskNameDaily    = 'MemReduct-DailyClean'
$ScriptPath       = Join-Path $PSScriptRoot 'mem-clean.ps1'
$ResultDir        = Join-Path $env:ProgramData 'memreduct'
$ResultFile       = Join-Path $ResultDir 'clean-result.json'

# ---------- 前置检查 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ( -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) )
{
	Write-Host '错误: 本脚本需要管理员权限运行 (右键"使用管理员身份运行"PowerShell)' -ForegroundColor Red
	exit 2
}

if ( -not $Uninstall -and -not (Test-Path $ScriptPath) )
{
	Write-Host "错误: 找不到清理脚本 $ScriptPath" -ForegroundColor Red
	exit 2
}

function Remove-CleanTask
{
	param ( [string]$Name )
	if ( Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue )
	{
		Unregister-ScheduledTask -TaskName $Name -Confirm:$false
		Write-Host "  已移除旧任务: $Name" -ForegroundColor DarkGray
	}
}

# ---------- 卸载模式 ----------
if ( $Uninstall )
{
	Remove-CleanTask $TaskNameOnDemand
	Remove-CleanTask $TaskNameDaily
	Write-Host '卸载完成。' -ForegroundColor Green
	exit 0
}

# ---------- 结果目录 ----------
if ( -not (Test-Path $ResultDir) )
{
	New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null
}

# ---------- 公共设置 ----------
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
	-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
	-MultipleInstances IgnoreNew

# 占位触发器 (过去时间, 永不自动触发; 按需任务必须至少有一个触发器才能注册)
$dummyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date '1990-01-01 03:00')

# ---------- 1) 按需任务 MemReduct-Clean ----------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
	"-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Json -Quiet -ResultFile `"$ResultFile`""
)
$principalTask = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest

Remove-CleanTask $TaskNameOnDemand
Register-ScheduledTask -TaskName $TaskNameOnDemand -Action $action -Trigger $dummyTrigger -Principal $principalTask -Settings $settings -Description 'MEM.REDUCT on-demand memory clean (bridge for non-elevated callers). Result: %ProgramData%\memreduct\clean-result.json' | Out-Null
Write-Host "已注册按需清理任务: $TaskNameOnDemand (RunLevel=Highest)" -ForegroundColor Green
Write-Host "  触发方式:  schtasks /run /tn $TaskNameOnDemand"
Write-Host "  结果文件:  $ResultFile"

# ---------- 2) 每日任务 (可选) ----------
if ( $Daily )
{
	$time = $null
	try { $time = [TimeSpan]::Parse($Daily) } catch { $time = $null }
	if ( $null -eq $time )
	{
		Write-Host "错误: -Daily 时间格式不正确: $Daily (示例: 23:00)" -ForegroundColor Red
		exit 4
	}
	$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ((Get-Date).Date + $time)

	# 旧版 MemReduct-DailyClean 为 exe --clean + RunLevel Limited, 提权检查不通过, 从未真正清理 — 重建
	$old = Get-ScheduledTask -TaskName $TaskNameDaily -ErrorAction SilentlyContinue
	if ( $old )
	{
		$oldAction = ($old.Actions | Select-Object -First 1)
		$oldLevel = $old.Principal.RunLevel
		Write-Host ("发现旧每日任务 (RunLevel={0}, 命令={1} {2}) — 将重建为 Highest + mem-clean.ps1" -f $oldLevel, $oldAction.Execute, $oldAction.Arguments) -ForegroundColor Yellow
	}

	Remove-CleanTask $TaskNameDaily
	$dailyResult = Join-Path $ResultDir 'daily-result.json'
	$dailyAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
		"-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Json -Quiet -ResultFile `"$dailyResult`""
	)
	Register-ScheduledTask -TaskName $TaskNameDaily -Action $dailyAction -Trigger $dailyTrigger -Principal $principalTask -Settings $settings -Description 'MEM.REDUCT daily memory clean via mem-clean.ps1 (elevated). Result: %ProgramData%\memreduct\daily-result.json' | Out-Null
	Write-Host "已注册每日清理任务: $TaskNameDaily ($Daily, RunLevel=Highest)" -ForegroundColor Green
}

# ---------- 3) 冒烟测试 ----------
if ( $Test )
{
	Write-Host ''
	Write-Host '触发按需任务进行端到端验证...' -ForegroundColor Cyan
	$oldTs = 0
	if ( Test-Path $ResultFile )
	{
		try { $oldTs = [int64](Get-Content $ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json).ts } catch {}
	}
	Start-ScheduledTask -TaskName $TaskNameOnDemand

	$deadline = (Get-Date).AddSeconds(150)
	while ( (Get-Date) -lt $deadline )
	{
		Start-Sleep -Milliseconds 1000
		if ( Test-Path $ResultFile )
		{
			try
			{
				$r = Get-Content $ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json
				if ( [int64]$r.ts -gt $oldTs ) { break }
			} catch {}
		}
	}

	if ( Test-Path $ResultFile )
	{
		$r = Get-Content $ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json
		if ( [int64]$r.ts -gt $oldTs )
		{
			Write-Host ("冒烟测试通过: ok={0}  释放 {1} GB ({2} GB -> {3} GB)  用时 {4} ms  失败区域 {5}" -f `
				$r.ok, $r.freedGB, $r.beforeGB, $r.afterGB, $r.durationMs, $r.failedCount) -ForegroundColor Green
			exit 0
		}
	}
	Write-Host '冒烟测试超时: 150s 内未获得新结果文件, 请手动检查任务历史' -ForegroundColor Red
	exit 3
}

Write-Host ''
Write-Host '完成。其它项目接入方式参见 docs/MEM_CLEAN_SCRIPT.md' -ForegroundColor Green
exit 0
