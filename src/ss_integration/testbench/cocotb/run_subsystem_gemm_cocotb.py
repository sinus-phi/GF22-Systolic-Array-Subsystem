"""Runner for the subsystem cocotb functional tests.

Usage from the repository root:

    python src/ss_integration/testbench/cocotb/run_subsystem_gemm_cocotb.py

The Didactic SoC student-subsystem verification flow uses Icarus Verilog with
cocotb by default.  Override with SIM=<name> only when another cocotb-supported
simulator is available and licensed.
"""

from __future__ import annotations

import os
from pathlib import Path


try:
    from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
    raise SystemExit(
        "cocotb/cocotb_tools is not installed. Install it in your Python "
        "environment first, for example: python -m pip install cocotb"
    ) from exc

try:
    from find_libpython import find_libpython
except ModuleNotFoundError:
    find_libpython = None


THIS_DIR = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parents[3]
BUILD_DIR = REPO_ROOT / "build" / "ss_integration_cocotb"
BUILD_LOG = BUILD_DIR / "subsystem_gemm_cocotb_build.log"
LOG_FILE = BUILD_DIR / "subsystem_gemm_cocotb.log"
RESULTS_XML = BUILD_DIR / "subsystem_gemm_cocotb.xml"


def _separator(char: str = "=", width: int = 86) -> str:
    return char * width


def _purpose(case: str) -> str:
    if case == "mode6_header_int8xint4_three_batches":
        return "Real mode6 header slice: one INT4 weight tile reused across three INT8 activation batches."
    if case.startswith("mode8_header_k_tile_0"):
        return "Real mode8 header slice: first K tile partial sums for INT16 activations and INT4 weights."
    if case.startswith("mode8_header_k_tile_1"):
        return "Real mode8 header slice: second K tile after reloading a different weight tile."
    if case == "mode8_two_k_tiles_firmware_accumulation":
        return "Firmware-style accumulation check across two K tiles from the same real GEMM header."
    if case == "reload_a_int4xint4":
        return "First INT4xINT4 transaction used as the baseline weight context."
    if case == "reload_b_int4xint4":
        return "Second INT4xINT4 transaction proves that reloaded weights replace the old context."
    if case.startswith("mixed_precision_case_"):
        return "Representative mixed-precision and short-tile-k datapath check."
    if case.startswith("random_header_"):
        return "Random tile/batch sequence sampled from a selected sw/gemm header."
    if case.startswith("mode5_full_gemm_tile_"):
        return "One internal firmware-style mode5 tile transaction: load INT32 weights, reuse them across M-row batches, and collect raw partial sums."
    if case == "mode5_full_gemm_8b_x_32b_32x32":
        return "Full mode5 32x32x32 GEMM: RTL tile engine plus firmware-style K accumulation, bias add, and final int32 cast."
    if case == "invalid_sequence_protection":
        return "Illegal firmware ordering should raise an APB/subsystem error instead of corrupting state."
    if case == "output_blocking_policy":
        return "Output-valid blocking policy: firmware must copy/release output before the next batch."
    return "Functional APB-level subsystem check."


def _parse_kv_field(field: str) -> tuple[str, str]:
    key, _, value = field.partition("=")
    return key, value


def _is_value_check(item: str) -> bool:
    return "_out_m" in item or "_accum_m" in item or item.startswith("final_m")


def _read_summary_data() -> tuple[dict[str, dict], str | None]:
    cases: dict[str, dict] = {}
    total_line: str | None = None

    if not LOG_FILE.exists():
        return cases, total_line

    for line in LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        if "COCOTB_SCENARIO," in line:
            payload = line.split("COCOTB_SCENARIO,", 1)[1]
            fields = payload.split(",")
            case = fields[0]
            case_info = cases.setdefault(
                case,
                {"scenario": {}, "checks": [], "case_result": "UNKNOWN"},
            )
            case_info["scenario"] = dict(_parse_kv_field(field) for field in fields[1:])
        elif "COCOTB_CHECK," in line:
            payload = line.split("COCOTB_CHECK,", 1)[1]
            fields = payload.split(",")
            if len(fields) < 5:
                continue
            case = fields[0]
            item = fields[1]
            expected = fields[2].replace("expected=", "", 1)
            actual = fields[3].replace("actual=", "", 1)
            result = fields[4]
            case_info = cases.setdefault(
                case,
                {"scenario": {}, "checks": [], "case_result": "UNKNOWN"},
            )
            case_info["checks"].append(
                {
                    "item": item,
                    "expected": expected,
                    "actual": actual,
                    "result": result,
                }
            )
        elif "COCOTB_CASE," in line:
            payload = line.split("COCOTB_CASE,", 1)[1]
            fields = payload.split(",")
            if len(fields) >= 2:
                case = fields[0]
                case_info = cases.setdefault(
                    case,
                    {"scenario": {}, "checks": [], "case_result": "UNKNOWN"},
                )
                case_info["case_result"] = fields[1]
        elif "TESTS=" in line:
            total_line = line.strip(" *")

    return cases, total_line


def print_check_summary() -> bool:
    if not LOG_FILE.exists():
        print("FINAL_RESULT: FAIL")
        return False

    sample_limit = int(os.getenv("SUMMARY_SAMPLES", "4"))
    full_gemm_sample_limit = int(os.getenv("FULL_GEMM_SUMMARY_VALUES", "64"))
    cases, total_line = _read_summary_data()
    all_pass = bool(cases)

    print()
    print(_separator())
    print("Subsystem cocotb functional verification summary")
    print(_separator())
    print(f"Build log : {BUILD_LOG}")
    print(f"Run log   : {LOG_FILE}")
    print(f"Results   : {RESULTS_XML}")
    if total_line:
        print(f"Summary   : {total_line}")
    print(_separator("-"))

    for index, (case, info) in enumerate(cases.items(), start=1):
        scenario = info["scenario"]
        checks = info["checks"]
        status_checks = [check for check in checks if not _is_value_check(check["item"])]
        value_checks = [check for check in checks if _is_value_check(check["item"])]
        failed_checks = [check for check in checks if check["result"] != "PASS"]
        case_pass = info["case_result"] == "PASS" and not failed_checks
        all_pass = all_pass and case_pass

        print(f"[{index}] {case}")
        print(f"Purpose : {_purpose(case)}")
        if scenario:
            config = ", ".join(f"{key}={value}" for key, value in scenario.items())
            print(f"Config  : {config}")

        if status_checks:
            print("Control/status checks:")
            for check in status_checks:
                print(
                    f"  [{check['result']:<4}] {check['item']}: "
                    f"expected={check['expected']} actual={check['actual']}"
                )

        if value_checks:
            case_sample_limit = (
                full_gemm_sample_limit
                if case == "mode5_full_gemm_8b_x_32b_32x32"
                else sample_limit
            )
            passed_values = sum(1 for check in value_checks if check["result"] == "PASS")
            print(
                "Output/reference checks: "
                f"{passed_values}/{len(value_checks)} matched"
            )
            samples = failed_checks if failed_checks else value_checks[:case_sample_limit]
            print("Output samples:")
            for check in samples:
                print(
                    f"  [{check['result']:<4}] {check['item']}: "
                    f"expected={check['expected']} actual={check['actual']}"
                )
            if len(value_checks) > len(samples):
                print(f"  ... {len(value_checks) - len(samples)} more value checks in the run log")

        print(f"Case result: {'PASS' if case_pass else 'FAIL'}")
        print(_separator("-"))

    print(f"FINAL_RESULT: {'PASS' if all_pass else 'FAIL'}")
    return all_pass


def main() -> None:
    try:
        sim = os.getenv("SIM", "icarus")
        runner = get_runner(sim)

        sources = [
            REPO_ROOT / "src" / "ss_integration" / "subsystem_pkg.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_apb_if.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_addr_decoder.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_regbank.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_sa_ctrl.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_input_frontend.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_pe.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_sa.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_output_buffer.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_topmodule.sv",
        ]

        build_args = []
        if sim == "icarus":
            build_args.append("-g2012")
        elif sim == "verilator":
            # Verilator is stricter than Icarus and treats style/width warnings
            # as fatal by default. Keep warnings in the build log, but allow the
            # functional cocotb run to proceed.
            build_args.append("-Wno-fatal")

        runner.build(
            hdl_library="work",
            sources=sources,
            hdl_toplevel="subsystem_topmodule",
            build_dir=BUILD_DIR,
            always=True,
            clean=True,
            build_args=build_args,
            timescale=("1ns", "1ps"),
            waves=bool(int(os.getenv("WAVES", "0"))),
            verbose=bool(int(os.getenv("VERBOSE", "0"))),
            log_file=str(BUILD_LOG),
        )

        extra_env = {
            "PYTHONPATH": str(THIS_DIR)
            + os.pathsep
            + os.environ.get("PYTHONPATH", ""),
        }
        for name in (
            "GEMM_HEADER",
            "GEMM_RANDOM_SEED",
            "GEMM_RANDOM_HEADERS",
            "GEMM_RANDOM_CASES",
            "GEMM_RANDOM_MAX_TILE_M",
            "GEMM_RANDOM_MAX_TILE_N",
            "GEMM_RANDOM_MAX_TILE_K",
            "GEMM_RANDOM_MAX_BATCHES",
            "RUN_FULL_GEMM_MODE5",
            "FULL_GEMM_SUMMARY_VALUES",
        ):
            if name in os.environ:
                extra_env[name] = os.environ[name]
        if find_libpython is not None:
            libpython = find_libpython()
            if libpython:
                extra_env["LIBPYTHON_LOC"] = libpython

        # Some cocotb runner/simulator combinations do not propagate extra_env
        # early enough for @cocotb.test(skip=...) expressions and module-level
        # environment reads.  Mirror the values into the runner process
        # environment as well so test selection and header options are stable.
        os.environ.update(extra_env)

        runner.test(
            hdl_toplevel="subsystem_topmodule",
            hdl_toplevel_library="work",
            test_module="test_subsystem_gemm_cocotb",
            test_dir=BUILD_DIR,
            build_dir=BUILD_DIR,
            results_xml=str(RESULTS_XML),
            log_file=str(LOG_FILE),
            extra_env=extra_env,
            waves=bool(int(os.getenv("WAVES", "0"))),
            verbose=bool(int(os.getenv("VERBOSE", "0"))),
        )
    except SystemExit as exc:
        if LOG_FILE.exists():
            print_check_summary()
        else:
            print(f"cocotb runner exited with code {exc.code}")
            print("FINAL_RESULT: FAIL")
        raise
    except Exception as exc:
        print(f"cocotb runner failed: {exc}")
        print(f"Build log: {BUILD_LOG}")
        print(f"Run log  : {LOG_FILE}")
        print("FINAL_RESULT: FAIL")
        raise SystemExit(1) from exc

    if not print_check_summary():
        raise SystemExit(1)


if __name__ == "__main__":
    main()
