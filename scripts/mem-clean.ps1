#Requires -Version 5.1
<#
.SYNOPSIS
	MEM.REDUCT 独立内存清理脚本 — 可被任意项目 / CI / Web 服务调用。

.DESCRIPTION
	与 bin/64/memreduct.exe --clean 完全同源的清理机制 (src/memory.c _app_memoryclean):
	  工作集         NtSetSystemInformation(SystemMemoryListInformation, MemoryEmptyWorkingSets)
	  系统文件缓存   NtSetSystemInformation(SystemFileCacheInformationEx, {MAXSIZE_T, MAXSIZE_T})
	  已修改文件缓存 枚举全部卷 (FindFirstVolume) -> FlushFileBuffers 逐卷刷新
	  已修改列表     NtSetSystemInformation(..., MemoryFlushModifiedList)
	  备用列表       NtSetSystemInformation(..., MemoryPurgeStandbyList)
	  备用列表优先0  NtSetSystemInformation(..., MemoryPurgeLowPriorityStandbyList)
	  注册表缓存     NtSetSystemInformation(SystemRegistryReconciliationInformation)   [Win8.1+]
	  合并内存列表   NtSetSystemInformation(SystemCombinePhysicalMemoryInformation)   [Win10+]

	零依赖: 仅 PowerShell 5.1+ 内置能力 (Add-Type + P/Invoke), 无需安装任何组件。
	权限: 需要管理员令牌 (内部自动启用 SeProfileSingleProcessPrivilege / SeIncreaseQuotaPrivilege)。
	      非提权调用时输出 ok=false 并以退出码 2 结束, 不会误报清理成功。

.EXAMPLE
	powershell -NoProfile -ExecutionPolicy Bypass -File mem-clean.ps1
	# 以默认区域 (0xE7, 同 GUI 默认) 清理, 输出人类可读结果

.EXAMPLE
	powershell -NoProfile -ExecutionPolicy Bypass -File mem-clean.ps1 -All -Json
	# 全部 8 个区域, 单行 JSON 输出 (stdout 为纯 JSON, UTF-8)

.EXAMPLE
	powershell -NoProfile -ExecutionPolicy Bypass -File mem-clean.ps1 -Regions standby,ws -Json
	# 仅清理指定区域

.NOTES
	退出码: 0=成功  2=未以管理员运行  3=部分区域失败  4=参数/环境错误
	 Mask 位: 0x01 工作集  0x02 系统文件缓存  0x04 备用列表P0  0x08 备用列表
	          0x10 已修改列表  0x20 合并内存  0x40 注册表缓存  0x80 已修改文件缓存
#>

[CmdletBinding()]
param (
	# 区域位掩码; -1 = 使用默认 0xE7 (同 GUI 默认, 不含备用列表/已修改列表这两个激进项)
	[int]$Mask = -1,

	# 区域名称列表 (逗号分隔): ws,cache,sb0,sb,mod,combine,reg,mfc — 提供时优先于 Mask
	[string]$Regions = '',

	# 清理全部 8 个区域 (等价 -Mask 255), 优先于 Mask/Regions
	[switch]$All,

	# 单行 JSON 输出到 stdout (stdout 无其它内容, 编码 UTF-8)
	[switch]$Json,

	# 静默 (不输出人类可读日志; 与 -Json 独立)
	[switch]$Quiet,

	# 将 JSON 结果原子写入指定文件 (UTF-8 无 BOM) — 供计划任务/跨进程回传结果
	[string]$ResultFile = ''
)

$ErrorActionPreference = 'Continue'

# -Json 模式下确保 stdout 重定向输出 UTF-8 字节 (调用方按 UTF-8 解码)
if ( $Json )
{
	try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
}

# ---------- 输出工具 ----------
function Write-Log
{
	param ( [string]$Message )
	if ( -not $Json -and -not $Quiet )
	{
		Write-Host $Message
	}
}

function Get-Ts
{
	[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

# ---------- 原生互操作 (与 exe 相同的 NT 调用) ----------
$NativeSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class VolumeFlushResult
{
    public int Total;
    public int Flushed;
    public string[] Errors = new string[0];
}

public static class MemCleanNative
{
    // ---- ntdll ----
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);

    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int infoClass, ref int info, int length);

    // ---- 进程/令牌/特权 ----
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES_1
    {
        public int PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privilege;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAllPrivileges, ref TOKEN_PRIVILEGES_1 newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    // ---- 内存状态 ----
    [StructLayout(LayoutKind.Sequential)]
    public class MEMORYSTATUSEX
    {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

    // ---- 卷枚举与刷新 ----
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr FindFirstVolumeW(StringBuilder volumeName, uint bufferLength);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool FindNextVolumeW(IntPtr findHandle, StringBuilder volumeName, uint bufferLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FindVolumeClose(IntPtr findHandle);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FlushFileBuffers(IntPtr handle);

    // ================= 高层封装 =================

    public static string NtStatusToHex(int status)
    {
        return "0x" + unchecked((uint)status).ToString("X8");
    }

    // 启用一项特权; 成功返回 true (权限不存在/开启失败返回 false)
    public static bool EnablePrivilege(string name)
    {
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid))
            return false;

        IntPtr token = IntPtr.Zero;
        // TOKEN_ADJUST_PRIVILEGES (0x20) | TOKEN_QUERY (0x08)
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
            return false;

        try
        {
            TOKEN_PRIVILEGES_1 tp = new TOKEN_PRIVILEGES_1();
            tp.PrivilegeCount = 1;
            tp.Privilege.Luid = luid;
            tp.Privilege.Attributes = 0x2; // SE_PRIVILEGE_ENABLED

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return false;

            // ERROR_NOT_ALL_ASSIGNED (1301) = 令牌中无此特权
            return Marshal.GetLastWin32Error() != 1301;
        }
        finally
        {
            CloseHandle(token);
        }
    }

    public static MEMORYSTATUSEX GetMemory()
    {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        GlobalMemoryStatusEx(m);
        return m;
    }

    // SystemMemoryListInformation (80)
    public static int SetMemoryListCommand(int command)
    {
        return NtSetSystemInformation(80, ref command, sizeof(int));
    }

    // SystemFileCacheInformationEx (81): SYSTEM_FILECACHE_INFORMATION (64B),
    // MinimumWorkingSet=MaximumWorkingSet=MAXSIZE_T — 与 exe 的 sfci 填法一致
    public static int SetFileCacheMax()
    {
        byte[] buf = new byte[64];
        WriteUInt64(buf, 24, ulong.MaxValue); // MinimumWorkingSet (偏移 24)
        WriteUInt64(buf, 32, ulong.MaxValue); // MaximumWorkingSet (偏移 32)

        IntPtr p = Marshal.AllocHGlobal(64);
        try
        {
            Marshal.Copy(buf, 0, p, 64);
            return NtSetSystemInformation(81, p, 64);
        }
        finally
        {
            Marshal.FreeHGlobal(p);
        }
    }

    // SystemRegistryReconciliationInformation (155)
    public static int SetRegistryReconciliation()
    {
        return NtSetSystemInformation(155, IntPtr.Zero, 0);
    }

    // SystemCombinePhysicalMemoryInformation (130): MEMORY_COMBINE_INFORMATION_EX (24B) 全零
    public static int SetCombinePhysicalMemory()
    {
        IntPtr p = Marshal.AllocHGlobal(24);
        try
        {
            for (int i = 0; i < 24; i++)
                Marshal.WriteByte(p, i, 0);
            return NtSetSystemInformation(130, p, 24);
        }
        finally
        {
            Marshal.FreeHGlobal(p);
        }
    }

    // 枚举全部卷并逐卷 FlushFileBuffers (等价 exe 的 _app_flushvolumecache)
    public static VolumeFlushResult FlushAllVolumes()
    {
        VolumeFlushResult r = new VolumeFlushResult();
        System.Collections.Generic.List<string> errs = new System.Collections.Generic.List<string>();

        StringBuilder sb = new StringBuilder(260);
        IntPtr find = FindFirstVolumeW(sb, 260);

        if (find == new IntPtr(-1))
        {
            r.Errors = new string[] { "FindFirstVolume failed: " + Marshal.GetLastWin32Error() };
            return r;
        }

        try
        {
            while (true)
            {
                // 形如 \\?\Volume{xxxxxxxx-....}\ — 去尾反斜杠得到可打开的设备路径
                string vol = sb.ToString().TrimEnd('\\');
                r.Total++;

                // GENERIC_WRITE (0x40000000), FILE_SHARE_READ|WRITE (3), OPEN_EXISTING (3)
                IntPtr h = CreateFileW(vol, 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);

                if (h == new IntPtr(-1))
                {
                    // 无文件系统/未挂载的卷打不开属正常, 仅记录
                    errs.Add(vol + ": open err " + Marshal.GetLastWin32Error());
                }
                else
                {
                    try
                    {
                        if (FlushFileBuffers(h))
                            r.Flushed++;
                        else
                            errs.Add(vol + ": flush err " + Marshal.GetLastWin32Error());
                    }
                    finally
                    {
                        CloseHandle(h);
                    }
                }

                if (!FindNextVolumeW(find, sb, 260))
                    break;
            }
        }
        finally
        {
            FindVolumeClose(find);
        }

        r.Errors = errs.ToArray();
        return r;
    }

    private static void WriteUInt64(byte[] buf, int offset, ulong value)
    {
        for (int i = 0; i < 8; i++)
            buf[offset + i] = (byte)((value >> (8 * i)) & 0xFF);
    }
}
'@

try
{
	if ( -not ('MemCleanNative' -as [type]) )
	{
		Add-Type -TypeDefinition $NativeSource -Language CSharp | Out-Null
	}
}
catch
{
	$msg = 'Add-Type 编译失败: ' + $_.Exception.Message
	if ( $Json )
	{
		Write-Output ( [ordered]@{ ok = $false; err = $msg; ts = Get-Ts } | ConvertTo-Json -Compress )
	}
	else
	{
		Write-Host $msg -ForegroundColor Red
	}
	exit 4
}

# ---------- 区域定义 ----------
$RegionBits = [ordered]@{
	ws      = 0x01   # 工作集
	cache   = 0x02   # 系统文件缓存
	sb0     = 0x04   # 备用列表优先级 0
	sb      = 0x08   # 备用列表
	mod     = 0x10   # 已修改列表
	combine = 0x20   # 合并内存列表
	reg     = 0x40   # 注册表缓存
	mfc     = 0x80   # 已修改文件缓存 (卷刷新)
}
# 名称别名 -> 规范名
$RegionAliases = @{
	workingset = 'ws';  working_set = 'ws';   workset = 'ws'
	filecache = 'cache'; systemfilecache = 'cache'; sfc = 'cache'
	standby = 'sb';      standbylist = 'sb';   standby_list = 'sb'
	standby0 = 'sb0';    priority0 = 'sb0';    standby_priority0 = 'sb0'; lowpriority = 'sb0'
	modified = 'mod';    modifiedlist = 'mod'; modified_list = 'mod'
	combinephys = 'combine'; combinememory = 'combine'; combine_memory_lists = 'combine'
	registry = 'reg';    registrycache = 'reg'
	volflush = 'mfc';    modifiedfilecache = 'mfc'; volumes = 'mfc'
}
$MaskDefault = 0xE7 # 同 REDUCT_MASK_DEFAULT

function Fail-Json
{
	param ( [string]$ErrMsg )
	if ( $Json )
	{
		[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
		Write-Output ( [ordered]@{ ok = $false; err = $ErrMsg; ts = Get-Ts } | ConvertTo-Json -Compress )
	}
	else
	{
		Write-Host "错误: $ErrMsg" -ForegroundColor Red
	}
	exit 4
}

# ---------- 解析区域掩码 ----------
$effectiveMask = 0
if ( $All )
{
	$effectiveMask = 0xFF
}
elseif ( $Regions )
{
	foreach ( $token in ($Regions -split '[,; ]+' | Where-Object { $_ }) )
	{
		$key = $token.Trim().ToLowerInvariant()
		if ( $RegionAliases.ContainsKey($key) ) { $key = $RegionAliases[$key] }
		if ( -not $RegionBits.Contains($key) ) { Fail-Json ("未知区域名称: {0} (可用: {1})" -f $token, ($RegionBits.Keys -join ',')) }
		$effectiveMask = $effectiveMask -bor $RegionBits[$key]
	}
	if ( $effectiveMask -eq 0 ) { Fail-Json 'Regions 列表为空' }
}
else
{
	if ( $Mask -lt -1 -or $Mask -gt 255 ) { Fail-Json ("Mask 超出范围 [0,255]: {0}" -f $Mask) }
	$effectiveMask = if ( $Mask -eq -1 ) { $MaskDefault } else { $Mask }
}

# ---------- 提权检查 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ( -not $isElevated )
{
	$msg = '需要管理员权限: 请从已提权的进程/计划任务调用, 或参考 docs/MEM_CLEAN_SCRIPT.md 的计划任务桥接方案'
	if ( $Json )
	{
		Write-Output ( [ordered]@{ ok = $false; elevated = $false; err = $msg; ts = Get-Ts } | ConvertTo-Json -Compress )
	}
	else
	{
		Write-Host $msg -ForegroundColor Red
	}
	exit 2
}

# ---------- 启用特权 (同 exe 的 _app_memory_init_privileges) ----------
$privOk1 = [MemCleanNative]::EnablePrivilege('SeProfileSingleProcessPrivilege')
$privOk2 = [MemCleanNative]::EnablePrivilege('SeIncreaseQuotaPrivilege')
if ( -not ($privOk1 -and $privOk2) )
{
	Write-Log ("  警告: 特权启用不完整 (SeProfileSingleProcessPrivilege={0}, SeIncreaseQuotaPrivilege={1}), 部分区域可能失败" -f $privOk1, $privOk2)
}

# ---------- OS 能力检测 (同 exe 的版本 gate) ----------
$osVer = [Environment]::OSVersion.Version
$supportRegistry = ( $osVer -ge [version]'6.3' )   # Win8.1+
$supportCombine = ( $osVer.Major -ge 10 )          # Win10+

# ---------- 内存快照 ----------
function Get-MemSnapshot
{
	$m = [MemCleanNative]::GetMemory()
	$total = [double]$m.ullTotalPhys
	$avail = [double]$m.ullAvailPhys
	@{
		totalGB = [math]::Round($total / 1GB, 2)
		usedGB  = [math]::Round(($total - $avail) / 1GB, 2)
		loadPct = [int]$m.dwMemoryLoad
	}
}

# ---------- 区域执行 ----------
$script:RegionResults = [ordered]@{}

function Record-Region
{
	param ( [string]$Key, [string]$State, [string]$StatusHex = '0x00000000', [string]$Note = '' )
	$script:RegionResults[$Key] = [ordered]@{
		state  = $State    # success | failed | skipped | not_run
		status = $StatusHex
		note   = $Note
	}
	if ( $State -eq 'failed' ) { Write-Log ("    [失败] {0}  status={1} {2}" -f $Key, $StatusHex, $Note) }
	elseif ( $State -eq 'success' ) { Write-Log ("    [成功] {0} {1}" -f $Key, $Note) }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$before = Get-MemSnapshot
Write-Log ("MEM.REDUCT 清理开始  mask=0x{0:X2}  内存占用 {1} GB / 共 {2} GB" -f $effectiveMask, $before.usedGB, $before.totalGB)

# 执行顺序与 exe _app_memoryclean 完全一致: ws -> cache -> mfc -> mod -> sb -> sb0 -> reg -> combine

# 1. 工作集
if ( $effectiveMask -band 0x01 )
{
	$status = [MemCleanNative]::SetMemoryListCommand(2) # MemoryEmptyWorkingSets
	$hex = [MemCleanNative]::NtStatusToHex($status)
	if ( $status -eq 0 ) { Record-Region 'workingSet' 'success' $hex }
	else { Record-Region 'workingSet' 'failed' $hex 'MemoryEmptyWorkingSets' }
}
else { Record-Region 'workingSet' 'not_run' }

# 2. 系统文件缓存
if ( $effectiveMask -band 0x02 )
{
	$status = [MemCleanNative]::SetFileCacheMax()
	$hex = [MemCleanNative]::NtStatusToHex($status)
	if ( $status -eq 0 ) { Record-Region 'systemFileCache' 'success' $hex }
	else { Record-Region 'systemFileCache' 'failed' $hex 'SystemFileCacheInformationEx' }
}
else { Record-Region 'systemFileCache' 'not_run' }

# 3. 已修改文件缓存 (逐卷刷新)
if ( $effectiveMask -band 0x80 )
{
	$vf = [MemCleanNative]::FlushAllVolumes()
	$note = ( 'flushed {0}/{1} volumes' -f $vf.Flushed, $vf.Total )
	# 只要成功刷新过至少一卷即视为成功 (个别无文件系统卷打不开属正常)
	if ( $vf.Flushed -gt 0 ) { Record-Region 'modifiedFileCache' 'success' '0x00000000' $note }
	else { Record-Region 'modifiedFileCache' 'failed' '0x00000000' ( $note + '; ' + ($vf.Errors -join '; ') ) }
}
else { Record-Region 'modifiedFileCache' 'not_run' }

# 4. 已修改列表
if ( $effectiveMask -band 0x10 )
{
	$status = [MemCleanNative]::SetMemoryListCommand(3) # MemoryFlushModifiedList
	$hex = [MemCleanNative]::NtStatusToHex($status)
	if ( $status -eq 0 ) { Record-Region 'modifiedList' 'success' $hex }
	else { Record-Region 'modifiedList' 'failed' $hex 'MemoryFlushModifiedList' }
}
else { Record-Region 'modifiedList' 'not_run' }

# 5. 备用列表
if ( $effectiveMask -band 0x08 )
{
	$status = [MemCleanNative]::SetMemoryListCommand(4) # MemoryPurgeStandbyList
	$hex = [MemCleanNative]::NtStatusToHex($status)
	if ( $status -eq 0 ) { Record-Region 'standbyList' 'success' $hex }
	else { Record-Region 'standbyList' 'failed' $hex 'MemoryPurgeStandbyList' }
}
else { Record-Region 'standbyList' 'not_run' }

# 6. 备用列表优先级 0
if ( $effectiveMask -band 0x04 )
{
	$status = [MemCleanNative]::SetMemoryListCommand(5) # MemoryPurgeLowPriorityStandbyList
	$hex = [MemCleanNative]::NtStatusToHex($status)
	if ( $status -eq 0 ) { Record-Region 'standbyPriority0' 'success' $hex }
	else { Record-Region 'standbyPriority0' 'failed' $hex 'MemoryPurgeLowPriorityStandbyList' }
}
else { Record-Region 'standbyPriority0' 'not_run' }

# 7. 注册表缓存 (Win8.1+)
if ( $effectiveMask -band 0x40 )
{
	if ( $supportRegistry )
	{
		$status = [MemCleanNative]::SetRegistryReconciliation()
		$hex = [MemCleanNative]::NtStatusToHex($status)
		if ( $status -eq 0 ) { Record-Region 'registryCache' 'success' $hex }
		else { Record-Region 'registryCache' 'failed' $hex 'SystemRegistryReconciliationInformation' }
	}
	else { Record-Region 'registryCache' 'skipped' '0x00000000' 'requires Win8.1+' }
}
else { Record-Region 'registryCache' 'not_run' }

# 8. 合并内存列表 (Win10+)
if ( $effectiveMask -band 0x20 )
{
	if ( $supportCombine )
	{
		$status = [MemCleanNative]::SetCombinePhysicalMemory()
		$hex = [MemCleanNative]::NtStatusToHex($status)
		if ( $status -eq 0 ) { Record-Region 'combineMemoryLists' 'success' $hex }
		else { Record-Region 'combineMemoryLists' 'failed' $hex 'SystemCombinePhysicalMemoryInformation' }
	}
	else { Record-Region 'combineMemoryLists' 'skipped' '0x00000000' 'requires Win10+' }
}
else { Record-Region 'combineMemoryLists' 'not_run' }

$sw.Stop()
$after = Get-MemSnapshot
$freed = [math]::Round([math]::Max(0, $before.usedGB - $after.usedGB), 2)

$failedCount = 0
foreach ( $k in $script:RegionResults.Keys ) { if ( $script:RegionResults[$k].state -eq 'failed' ) { $failedCount++ } }
$allOk = ( $failedCount -eq 0 )

# ---------- 输出 ----------
$result = [ordered]@{
	ok            = $allOk
	elevated      = $true
	mask          = $effectiveMask
	maskHex       = ('0x{0:X2}' -f $effectiveMask)
	beforeGB      = $before.usedGB
	afterGB       = $after.usedGB
	freedGB       = $freed
	memLoadBefore = $before.loadPct
	memLoadAfter  = $after.loadPct
	durationMs    = [int]$sw.ElapsedMilliseconds
	failedCount   = $failedCount
	regions       = $script:RegionResults
	ts            = Get-Ts
}
$jsonText = $result | ConvertTo-Json -Depth 5 -Compress

if ( $ResultFile )
{
	try
	{
		$dir = Split-Path -Parent $ResultFile
		if ( $dir -and -not (Test-Path $dir) ) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
		$tmp = "$ResultFile.tmp"
		[IO.File]::WriteAllText($tmp, $jsonText, (New-Object Text.UTF8Encoding $false))
		Move-Item -LiteralPath $tmp -Destination $ResultFile -Force
	}
	catch
	{
		Write-Log ("  警告: ResultFile 写入失败: {0}" -f $_.Exception.Message)
	}
}

if ( $Json )
{
	# 确保 stdout 重定向时为 UTF-8 字节, 避免调用方按 UTF-8 解码乱码
	[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
	Write-Output $jsonText
}
elseif ( -not $Quiet )
{
	Write-Host ''
	Write-Host ("清理完成: {0} GB -> {1} GB   释放 {2} GB   用时 {3} ms" -f $before.usedGB, $after.usedGB, $freed, [int]$sw.ElapsedMilliseconds) -ForegroundColor $( if ($allOk) { 'Green' } else { 'Yellow' } )
	if ( $failedCount -gt 0 ) { Write-Host "失败区域数: $failedCount" -ForegroundColor Yellow }
}

if ( -not $allOk ) { exit 3 }
exit 0
