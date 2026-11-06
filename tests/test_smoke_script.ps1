# Verify the CI smoke script using a disposable fixture, without running Mem Reduct.
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('memreduct-smoke-test-' + [guid]::NewGuid().ToString('N'))
$fixtureLog = Join-Path $testRoot 'fixture.log'
$oldLog = $env:MEMREDUCT_SMOKE_TEST_LOG
$oldStatus = $env:MEMREDUCT_SMOKE_TEST_CLEAN_STATUS

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Smoke([string]$Script, [string]$Exe) {
    $command = 'call "{0}" "{1}"' -f $Script, $Exe
    $output = @(& $env:ComSpec /d /c $command 2>&1)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

try {
    $scriptsDir = Join-Path $testRoot 'scripts'
    New-Item -ItemType Directory -Path $scriptsDir | Out-Null
    $smoke = Join-Path $scriptsDir 'smoke_test.bat'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\smoke_test.bat') -Destination $smoke

    $missing = Join-Path $testRoot 'does-not-exist.exe'
    $result = Invoke-Smoke $smoke $missing
    Assert-True ($result.ExitCode -eq 1 -and $result.Output -match 'Binary not found:') "Missing executable was not rejected: exit=$($result.ExitCode), output=$($result.Output)"

    $fixture = Join-Path $testRoot 'fixture.exe'
    $source = @'
using System;
using System.IO;
public static class SmokeFixture {
    public static int Main(string[] args) {
        File.AppendAllText(Environment.GetEnvironmentVariable("MEMREDUCT_SMOKE_TEST_LOG"),
                           string.Join(" ", args) + Environment.NewLine);
        // The real -help opens a modal dialog, so CI must never invoke it.
        if (args.Length == 1 && args[0] == "-help") return 23;
        if (args.Length == 1 && args[0] == "-clean") {
            string status = Environment.GetEnvironmentVariable("MEMREDUCT_SMOKE_TEST_CLEAN_STATUS");
            if (status == "access") return unchecked((int)0xC0000005);
            if (status == "stack") return unchecked((int)0xC0000409);
            if (status == "ordinary-error") return 2;
        }
        return 0;
    }
}
'@
    # Mem Reduct is a GUI-subsystem executable, so use the same subsystem here.
    Add-Type -TypeDefinition $source -OutputAssembly $fixture -OutputType WindowsApplication
    $env:MEMREDUCT_SMOKE_TEST_LOG = $fixtureLog
    $env:MEMREDUCT_SMOKE_TEST_CLEAN_STATUS = ''
    $result = Invoke-Smoke $smoke $fixture
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'All smoke tests passed') 'Smoke script did not complete for a working executable'
    $calls = @(Get-Content -LiteralPath $fixtureLog)
    Assert-True ($calls.Count -eq 1 -and $calls[0] -eq '-clean') 'Smoke script must run the non-interactive clean command only'

    foreach ($status in @('access', 'stack')) {
        Remove-Item -LiteralPath $fixtureLog
        $env:MEMREDUCT_SMOKE_TEST_CLEAN_STATUS = $status
        $result = Invoke-Smoke $smoke $fixture
        Assert-True ($result.ExitCode -eq 1 -and $result.Output -match '\[FAIL\] -clean crashed') "Smoke script ignored the $status crash"
        $calls = @(Get-Content -LiteralPath $fixtureLog)
        Assert-True ($calls.Count -eq 1 -and $calls[0] -eq '-clean') 'Smoke script did not execute the clean command'
    }
    $env:MEMREDUCT_SMOKE_TEST_CLEAN_STATUS = 'ordinary-error'
    $result = Invoke-Smoke $smoke $fixture
    Assert-True ($result.ExitCode -eq 0) 'Ordinary nonzero clean status should remain a non-crash result'
    Write-Host 'PASS: smoke script rejects missing binaries and executes fixture commands'
}
finally {
    $env:MEMREDUCT_SMOKE_TEST_LOG = $oldLog
    $env:MEMREDUCT_SMOKE_TEST_CLEAN_STATUS = $oldStatus
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory outside TEMP' }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
