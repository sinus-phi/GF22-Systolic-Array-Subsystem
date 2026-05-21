param(
    [string]$Sim = "verilator",
    [string]$Header = "",
    [int]$RandomHeaders = 2,
    [int]$RandomCases = 2,
    [int]$RandomSeed = 20260521,
    [switch]$FullMode5,
    [int]$FullGemmSummaryValues = 64,
    [switch]$UseNative
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..\..")).Path

if ($UseNative) {
    Set-Location $RepoRoot
    $env:SIM = $Sim
    $env:GEMM_RANDOM_HEADERS = "$RandomHeaders"
    $env:GEMM_RANDOM_CASES = "$RandomCases"
    $env:GEMM_RANDOM_SEED = "$RandomSeed"
    $env:FULL_GEMM_SUMMARY_VALUES = "$FullGemmSummaryValues"
    if ($FullMode5) {
        $env:RUN_FULL_GEMM_MODE5 = "1"
    } else {
        Remove-Item Env:\RUN_FULL_GEMM_MODE5 -ErrorAction SilentlyContinue
    }
    if ($Header -ne "") {
        $env:GEMM_HEADER = $Header
    } else {
        Remove-Item Env:\GEMM_HEADER -ErrorAction SilentlyContinue
    }
    python .\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.py
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

Write-Host "Repository : $RepoRoot"
Write-Host "WSL path   : $WslRepo"
Write-Host "Simulator  : $Sim"

$HeaderEnv = ""
if ($Header -ne "") {
    $EscapedHeader = $Header.Replace("'", "'\''")
    $HeaderEnv = "GEMM_HEADER='$EscapedHeader' "
}

$FullMode5Env = ""
if ($FullMode5) {
    $FullMode5Env = "RUN_FULL_GEMM_MODE5=1 "
}

& wsl bash -lc "cd '$EscapedRepo' && ${HeaderEnv}${FullMode5Env}FULL_GEMM_SUMMARY_VALUES=$FullGemmSummaryValues GEMM_RANDOM_HEADERS=$RandomHeaders GEMM_RANDOM_CASES=$RandomCases GEMM_RANDOM_SEED=$RandomSeed SIM=$Sim ./src/ss_integration/testbench/cocotb/run_subsystem_gemm_cocotb.sh"
exit $LASTEXITCODE
