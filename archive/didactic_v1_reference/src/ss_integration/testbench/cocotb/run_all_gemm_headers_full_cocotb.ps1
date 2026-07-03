param(
    [string]$Sim = "verilator",
    [string]$HeaderGlob = "array_mode*.h",
    [int]$SummaryValues = 8,
    [switch]$PrintAllValues,
    [switch]$UseNative
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..\..")).Path

if ($UseNative) {
    Set-Location $RepoRoot
    $env:SIM = $Sim
    $env:ALL_HEADERS_GLOB = $HeaderGlob
    $env:ALL_HEADERS_SUMMARY_VALUES = "$SummaryValues"
    if ($PrintAllValues) {
        $env:ALL_HEADERS_PRINT_ALL_VALUES = "1"
    } else {
        Remove-Item Env:\ALL_HEADERS_PRINT_ALL_VALUES -ErrorAction SilentlyContinue
    }
    python .\src\ss_integration\testbench\cocotb\test_all_gemm_headers_full_cocotb.py
    exit $LASTEXITCODE
}

$WslCmd = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $WslCmd) {
    throw "WSL is not available. Install WSL, or rerun with -UseNative after installing a native cocotb-compatible simulator."
}

$Drive = $RepoRoot.Substring(0, 1).ToLowerInvariant()
$Rest = $RepoRoot.Substring(2).Replace("\", "/")
$WslRepo = "/mnt/$Drive$Rest"
$EscapedRepo = $WslRepo.Replace("'", "'\''")
$EscapedGlob = $HeaderGlob.Replace("'", "'\''")

Write-Host "Repository : $RepoRoot"
Write-Host "WSL path   : $WslRepo"
Write-Host "Simulator  : $Sim"
Write-Host "HeaderGlob : $HeaderGlob"

$PrintAllEnv = ""
if ($PrintAllValues) {
    $PrintAllEnv = "ALL_HEADERS_PRINT_ALL_VALUES=1 "
}

& wsl bash -lc "cd '$EscapedRepo' && ALL_HEADERS_GLOB='$EscapedGlob' ALL_HEADERS_SUMMARY_VALUES=$SummaryValues ${PrintAllEnv}SIM=$Sim ./src/ss_integration/testbench/cocotb/run_all_gemm_headers_full_cocotb.sh"
exit $LASTEXITCODE
