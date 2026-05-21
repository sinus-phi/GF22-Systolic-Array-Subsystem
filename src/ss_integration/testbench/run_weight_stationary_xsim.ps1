param(
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$buildDir = Join-Path $repoRoot "build\ss_integration_weight_stationary_xsim"

function Require-Tool {
  param([string]$Name)

  $tool = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $tool) {
    throw "$Name was not found on PATH. Add Vivado's bin directory to PATH, then open a new terminal."
  }
}

Require-Tool "xvlog"
Require-Tool "xelab"
Require-Tool "xsim"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$sources = @(
  "src/ss_integration/subsystem_pkg.sv",
  "src/ss_integration/subsystem_apb_if.sv",
  "src/ss_integration/subsystem_addr_decoder.sv",
  "src/ss_integration/subsystem_regbank.sv",
  "src/ss_integration/subsystem_sa_ctrl.sv",
  "src/ss_integration/subsystem_input_frontend.sv",
  "src/ss_integration/subsystem_pe.sv",
  "src/ss_integration/subsystem_sa.sv",
  "src/ss_integration/subsystem_output_buffer.sv",
  "src/ss_integration/subsystem_topmodule.sv",
  "src/ss_integration/testbench/tb_subsystem_weight_stationary.sv"
) | ForEach-Object { Join-Path $repoRoot $_ }

Push-Location $buildDir
try {
  xvlog -sv @sources
  xelab tb_subsystem_weight_stationary -s tb_subsystem_weight_stationary_sim
  xsim tb_subsystem_weight_stationary_sim -runall

  if (-not $KeepArtifacts) {
    $targets = @(
      "xsim.dir",
      "xvlog.log",
      "xvlog.pb",
      "xelab.log",
      "xelab.pb",
      "xsim.log",
      "xsim.pb",
      "xsim.jou",
      ".Xil"
    )

    foreach ($target in $targets) {
      $path = Join-Path (Get-Location) $target
      if (Test-Path -LiteralPath $path) {
        $resolved = (Resolve-Path -LiteralPath $path).Path
        if ($resolved.StartsWith((Get-Location).Path)) {
          Remove-Item -LiteralPath $resolved -Recurse -Force
        }
      }
    }
  }
}
finally {
  Pop-Location
}
