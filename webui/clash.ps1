# Local-only bridge to the Mihomo controller used by Clash Verge.
# The controller secret stays in this process and is never returned to clients.
$script:ClashModulePath = $PSCommandPath
$script:ClashDelayJob = $null
$script:ClashDelayId = ''
$script:ClashDelayState = ''
$script:ClashDelayResults = New-Object System.Collections.ArrayList
$script:ClashDelayTotal = 0

function Get-ClashConnection {
    $configPath = $env:MEMREDUCT_CLASH_CONFIG
    if (-not $configPath) {
        $configPath = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw '找不到 Clash Verge 运行配置' }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $configPath -Encoding UTF8) {
        if ($line -match '^(external-controller|external-controller-pipe|secret|cfw-latency-url|cfw-latency-timeout):\s*(.*?)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[$value.Length - 1] -eq "'") {
                $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
            }
            elseif ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
                try { $value = ConvertFrom-Json -InputObject $value -ErrorAction Stop }
                catch { throw '无法读取 Clash 控制器配置' }
            }
            else { $value = $value -replace '\s+#.*$', '' }
            $values[$key] = [string]$value
        }
    }

    $secret = [string]$values['secret']
    if ($secret -match '[^\x20-\x7e]') { throw 'Clash 控制器密钥格式不受支持' }
    $testUrl = [string]$values['cfw-latency-url']
    $parsedUrl = $null
    if (-not [Uri]::TryCreate($testUrl, [UriKind]::Absolute, [ref]$parsedUrl) -or $parsedUrl.Scheme -notin @('http', 'https')) {
        $testUrl = 'https://www.gstatic.com/generate_204'
    }
    $testTimeout = 4000
    $configuredTimeout = 0
    if ([int]::TryParse([string]$values['cfw-latency-timeout'], [ref]$configuredTimeout)) {
        $testTimeout = [Math]::Max(1000, [Math]::Min(15000, $configuredTimeout))
    }
    $address = [string]$values['external-controller']
    if ($address -match '^(127\.0\.0\.1|localhost):(\d{1,5})$|^\[::1\]:(\d{1,5})$') {
        $port = if ($Matches[2]) { [int]$Matches[2] } else { [int]$Matches[3] }
        if ($port -gt 0 -and $port -le 65535) {
            return @{ Mode = 'http'; Address = $address; Secret = $secret; TestUrl = $testUrl; TestTimeout = $testTimeout }
        }
    }

    $pipe = [string]$values['external-controller-pipe']
    if ($pipe -match '^\\\\\.\\pipe\\([A-Za-z0-9_.-]{1,220})$') {
        return @{ Mode = 'pipe'; PipeName = $Matches[1]; Secret = $secret; TestUrl = $testUrl; TestTimeout = $testTimeout }
    }
    throw 'Clash 控制接口不可用：请启动 Clash Verge 或启用仅本机访问的外部控制器'
}

function Invoke-ClashRequest {
    param (
        [Parameter(Mandatory=$true)][string]$Path,
        [ValidateSet('GET', 'PUT')][string]$Method = 'GET',
        [string]$Body = '',
        [int]$TimeoutMs = 6000
    )
    $connection = Get-ClashConnection
    if ($connection.Mode -eq 'http') {
        $request = [Net.HttpWebRequest]::Create('http://' + $connection.Address + $Path)
        $request.Method = $Method
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.Accept = 'application/json'
        if ($connection.Secret) { $request.Headers['Authorization'] = 'Bearer ' + $connection.Secret }
        if ($Method -eq 'PUT') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = 'application/json; charset=utf-8'
            $request.ContentLength = $bytes.Length
            $output = $request.GetRequestStream()
            try { $output.Write($bytes, 0, $bytes.Length) } finally { $output.Dispose() }
        }
        $response = $request.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
    }

    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $connection.PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $content = New-Object IO.MemoryStream
    try {
        $pipe.Connect([Math]::Min(2000, $TimeoutMs))
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $head = "$Method $Path HTTP/1.0`r`nHost: localhost`r`nConnection: close`r`nAccept: application/json`r`n"
        if ($connection.Secret) { $head += "Authorization: Bearer $($connection.Secret)`r`n" }
        if ($Method -eq 'PUT') { $head += "Content-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`n" }
        $headBytes = [Text.Encoding]::ASCII.GetBytes($head + "`r`n")
        $packet = New-Object byte[] ($headBytes.Length + $bodyBytes.Length)
        [Array]::Copy($headBytes, 0, $packet, 0, $headBytes.Length)
        [Array]::Copy($bodyBytes, 0, $packet, $headBytes.Length, $bodyBytes.Length)
        $remaining = [Math]::Max(1, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
        $write = $pipe.WriteAsync($packet, 0, $packet.Length)
        if (-not $write.Wait($remaining)) { throw 'Clash 控制器请求超时' }

        $buffer = New-Object byte[] 16384
        while ($true) {
            $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Clash 控制器响应超时' }
            $read = $pipe.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $read.Wait($remaining)) { throw 'Clash 控制器响应超时' }
            $count = $read.Result
            if ($count -eq 0) { break }
            $content.Write($buffer, 0, $count)
            if ($content.Length -gt 2MB) { throw 'Clash 控制器响应过大' }
        }
        $raw = [Text.Encoding]::UTF8.GetString($content.ToArray())
        $separator = $raw.IndexOf("`r`n`r`n")
        if ($separator -lt 0 -or $raw -notmatch '^HTTP/\d(?:\.\d)?\s+(\d{3})') { throw 'Clash 控制器响应无效' }
        $code = [int]$Matches[1]
        if ($code -lt 200 -or $code -ge 300) { throw "Clash 控制器返回 HTTP $code" }
        return $raw.Substring($separator + 4)
    }
    finally { $content.Dispose(); $pipe.Dispose() }
}

function ConvertFrom-ClashJson([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ConvertFrom-Json -InputObject $Json -AsHashtable -ErrorAction Stop }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 2MB
    return $serializer.DeserializeObject($Json)
}

function Get-ClashState {
    $groupResponse = ConvertFrom-ClashJson (Invoke-ClashRequest '/group')
    $proxyResponse = ConvertFrom-ClashJson (Invoke-ClashRequest '/proxies')
    if (-not $groupResponse.ContainsKey('proxies') -or -not $proxyResponse.ContainsKey('proxies')) { throw 'Clash 返回的数据不完整' }
    $proxies = $proxyResponse['proxies']
    $groups = New-Object System.Collections.ArrayList
    $nodes = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($group in @($groupResponse['proxies'])) {
        if ($group['type'] -ne 'Selector' -or -not $group['name']) { continue }
        $members = @($group['all'] | ForEach-Object { [string]$_ })
        [void]$groups.Add([ordered]@{ name = [string]$group['name']; type = 'Selector'; now = [string]$group['now']; all = $members })
        foreach ($name in $members) {
            if (-not $seen.Add($name)) { continue }
            $node = if ($proxies.ContainsKey($name)) { $proxies[$name] } else { @{} }
            $delay = $null
            $history = @($node['history'])
            if ($history.Count -gt 0 -and $history[-1]) { $delay = [int]$history[-1]['delay'] }
            [void]$nodes.Add([ordered]@{
                name = $name; type = [string]$node['type']; udp = [bool]$node['udp'];
                delay = $delay; now = [string]$node['now']
            })
        }
    }
    return [ordered]@{ ok = $true; groups = @($groups.ToArray()); nodes = @($nodes.ToArray()) }
}

function Find-ClashGroup {
    param([string]$Group, [string]$Node = '')
    if (-not $Group -or $Group.Length -gt 512 -or $Node.Length -gt 512) { return $null }
    $state = Get-ClashState
    foreach ($item in $state.groups) {
        if ($item.name -ceq $Group -and (-not $Node -or $item.all -ccontains $Node)) { return $item }
    }
    return $null
}

function Set-ClashSelection {
    param([string]$Group, [string]$Node)
    if (-not $Node -or -not (Find-ClashGroup $Group $Node)) { return $false }
    $path = '/proxies/' + [Uri]::EscapeDataString($Group)
    $body = ConvertTo-Json -InputObject @{ name = $Node } -Compress
    $null = Invoke-ClashRequest -Path $path -Method PUT -Body $body
    return $true
}

function Start-ClashDelay {
    param([string]$Group, [string]$Node = '')
    if ($script:ClashDelayJob -and $script:ClashDelayJob.State -in @('NotStarted', 'Running')) { return $null }
    $groupInfo = Find-ClashGroup $Group $Node
    if (-not $groupInfo) { return $false }
    $connection = Get-ClashConnection
    if ($script:ClashDelayJob) { Remove-Job -Job $script:ClashDelayJob -Force -ErrorAction SilentlyContinue }
    $names = if ($Node) { @($Node) } else { @($groupInfo.all) }
    if ($names.Count -eq 0 -or $names.Count -gt 500) { return $false }
    $namesJson = ConvertTo-Json -InputObject $names -Compress
    $script:ClashDelayResults = New-Object System.Collections.ArrayList
    $script:ClashDelayTotal = $names.Count
    $script:ClashDelayId = [guid]::NewGuid().ToString('N')
    $script:ClashDelayState = 'running'
    $script:ClashDelayJob = Start-Job -ArgumentList @($script:ClashModulePath, $namesJson, $connection.TestUrl, $connection.TestTimeout) -ScriptBlock {
        param($ModulePath, $NamesJson, $TestUrl, $TestTimeout)
        . $ModulePath
        $decodedNames = ConvertFrom-Json -InputObject $NamesJson
        foreach ($name in $decodedNames) {
            try {
                $encoded = [Uri]::EscapeDataString([string]$name)
                $url = [Uri]::EscapeDataString($TestUrl)
                $json = Invoke-ClashRequest -Path "/proxies/$encoded/delay?url=$url&timeout=$TestTimeout" -TimeoutMs ($TestTimeout + 2500)
                $result = ConvertFrom-ClashJson $json
                [pscustomobject]@{ name = [string]$name; delay = [int]$result['delay']; status = 'ok' }
            }
            catch {
                $status = if ($_.Exception.Message -match '504|timeout|超时') { 'timeout' } else { 'error' }
                [pscustomobject]@{ name = [string]$name; delay = 0; status = $status }
            }
        }
    }
    return $script:ClashDelayId
}

function Stop-ClashDelay([string]$Id) {
    if (-not $Id -or $Id -cne $script:ClashDelayId) { return $false }
    if ($script:ClashDelayJob) {
        foreach ($item in @(Receive-Job -Job $script:ClashDelayJob -ErrorAction SilentlyContinue)) {
            [void]$script:ClashDelayResults.Add([ordered]@{ name = [string]$item.name; delay = [int]$item.delay; status = [string]$item.status })
        }
        Stop-Job -Job $script:ClashDelayJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ClashDelayJob -Force -ErrorAction SilentlyContinue
        $script:ClashDelayJob = $null
    }
    $script:ClashDelayState = 'cancelled'
    return $true
}

function Get-ClashDelay([string]$Id) {
    if (-not $Id -or $Id -cne $script:ClashDelayId) { return $null }
    if ($script:ClashDelayJob) {
        foreach ($item in @(Receive-Job -Job $script:ClashDelayJob -ErrorAction SilentlyContinue)) {
            [void]$script:ClashDelayResults.Add([ordered]@{ name = [string]$item.name; delay = [int]$item.delay; status = [string]$item.status })
        }
        if ($script:ClashDelayJob.State -notin @('NotStarted', 'Running')) {
            $script:ClashDelayState = if ($script:ClashDelayJob.State -eq 'Completed') { 'done' } else { 'error' }
            Remove-Job -Job $script:ClashDelayJob -Force -ErrorAction SilentlyContinue
            $script:ClashDelayJob = $null
        }
    }
    return [ordered]@{ ok = $true; id = $Id; state = $script:ClashDelayState; total = $script:ClashDelayTotal; results = @($script:ClashDelayResults.ToArray()) }
}

function Get-ClashCurrentDelay {
    if (-not $script:ClashDelayId) { return [ordered]@{ ok = $true; state = 'idle'; results = @() } }
    return Get-ClashDelay $script:ClashDelayId
}
