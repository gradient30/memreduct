# Exercise the real Invoke-Clean function with a simulated Windows elevation.
# No memory is cleaned and no scheduled task is created by this test.
$ErrorActionPreference = 'Stop'
$server = Join-Path $PSScriptRoot '..\webui\server.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $server).Path, [ref]$tokens, [ref]$errors)
if ($errors) { throw "Unable to parse server.ps1: $errors" }
foreach ($name in @('Get-Ts', 'Read-CleanResult', 'Convert-ToClient', 'Invoke-Clean')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ScheduledTask {
    param($TaskName, $ErrorAction)
    if ($script:TaskAvailable) { return [pscustomobject]@{ TaskName = $TaskName } }
    return $null
}
function Start-ScheduledTask {
    param($TaskName, $ErrorAction)
    $script:TaskStarts++
    [IO.File]::WriteAllText($CleanResult, '{"ok":true,"elevated":true,"beforeGB":20,"afterGB":18,"freedGB":2,"durationMs":42,"ts":1}')
}
function Start-Sleep { param($Milliseconds) }
function Start-Process {
    param($FilePath, $ArgumentList, $PassThru, $WindowStyle, $Verb, $ErrorAction)
    $script:Calls += ,@{ FilePath = $FilePath; Arguments = $ArgumentList; Verb = $Verb }
    if ($script:DenyElevation) { throw [System.ComponentModel.Win32Exception]::new(1223) }
    $index = [array]::IndexOf($ArgumentList, '-ResultFile')
    if ($index -lt 0) { throw 'Missing -ResultFile argument' }
    $resultPath = ([string]$ArgumentList[$index + 1]).Trim('"')
    $script:CreatedResult = $resultPath
    $result = if ($script:InvalidResult) { 'invalid json' } else { '{"ok":true,"elevated":true,"beforeGB":20,"afterGB":18,"freedGB":2,"durationMs":42,"ts":1}' }
    [IO.File]::WriteAllText($resultPath, $result)
    $process = [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
    return $process
}

$Port = 8765
$CleanElevated = $false
$CleanScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\mem-clean.ps1')).Path
$CleanTaskName = 'MemReduct-Clean-Test-Does-Not-Exist'
$CleanResult = Join-Path $env:TEMP ('memreduct-task-test-' + [guid]::NewGuid().ToString('N') + '.json')
$CleanDirectOut = Join-Path $env:TEMP ('memreduct-direct-test-' + [guid]::NewGuid().ToString('N') + '.json')
$MemReductExe = Join-Path $env:TEMP 'memreduct-nonexistent-test.exe'
$CleanTimeoutS = 2
$script:ReqIsLocal = $true
$script:ReqOrigin = 'http://127.0.0.1:8765'
$script:Calls = @()
$script:DenyElevation = $false
$script:InvalidResult = $false
$script:TaskAvailable = $false
$script:TaskStarts = 0
$script:CreatedResult = $null

try {
    $result = Invoke-Clean
    Assert-True ($result.ok -and $result.mode -eq 'uac' -and $result.freedGB -eq 2) 'Missing bridge should run the cleaning script after UAC approval.'
    Assert-True ($script:Calls.Count -eq 1 -and $script:Calls[0].Verb -eq 'RunAs') 'The fallback must request Windows administrator consent.'
    Assert-True (-not (Test-Path -LiteralPath $script:CreatedResult)) 'The temporary result file should be removed.'

    $script:Calls = @()
    $script:DenyElevation = $true
    $result = Invoke-Clean
    Assert-True (-not $result.ok -and $result.err -match '取消') 'Cancelling UAC must report that cleanup did not run.'
    Assert-True ($script:Calls.Count -eq 1) 'UAC cancellation must not retry or run a different cleaner.'

    $script:Calls = @()
    $script:DenyElevation = $false
    $script:ReqOrigin = 'https://untrusted.example'
    $result = Invoke-Clean
    Assert-True (-not $result.ok -and $script:Calls.Count -eq 0) 'A cross-origin request must not trigger a local UAC prompt.'

    $script:ReqOrigin = 'http://127.0.0.1:8765'
    $script:ReqIsLocal = $false
    $result = Invoke-Clean
    Assert-True (-not $result.ok -and $script:Calls.Count -eq 0) 'A remote client must not trigger a local UAC prompt.'

    $script:ReqIsLocal = $true
    $script:TaskAvailable = $true
    $result = Invoke-Clean
    Assert-True ($result.ok -and $result.mode -eq 'task' -and $script:TaskStarts -eq 1) 'An existing task must be preferred over the UAC fallback.'
    Assert-True ($script:Calls.Count -eq 0) 'A working task must not start an elevated process.'

    $script:TaskAvailable = $false
    $CleanElevated = $true
    $result = Invoke-Clean
    Assert-True ($result.ok -and $result.mode -eq 'direct' -and -not $script:Calls[0].Verb) 'An elevated service must run the script directly.'

    $script:Calls = @()
    $script:InvalidResult = $true
    $result = Invoke-Clean
    Assert-True (-not $result.ok -and $result.err -match '结果') 'An invalid result file must not be reported as a successful cleanup.'
    Write-Host 'PASS: Web cleanup modes, UAC cancellation, request boundaries, and invalid results'
}
finally {
    if ($script:CreatedResult -and (Test-Path -LiteralPath $script:CreatedResult)) {
        Remove-Item -LiteralPath $script:CreatedResult -Force
    }
    if (Test-Path -LiteralPath $CleanResult) { Remove-Item -LiteralPath $CleanResult -Force }
}
