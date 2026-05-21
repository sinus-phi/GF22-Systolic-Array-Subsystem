import os
from pathlib import Path

from cocotb_tools.runner import get_runner

def setup_runner(test_file, sources, top, parameters, testcase=None):
    # defining simulator
    sim = os.getenv("SIM", "icarus")

    # defining paths
    root_path = Path(__file__).resolve().parents[2]
    test_path = root_path / "sim"
    build_path = root_path / "sim_build"
    rtl_path = root_path / "src" / "ss"
    output_name = testcase if testcase is not None else test_file
    # per-test waveform path
    wave_file = build_path / f"{output_name}.fst"
    # SV source files
    source_files = [rtl_path / source for source in sources]

    runner = get_runner(sim)
    runner.build(
        # defining the hdl sources
        sources = source_files,
        # defining the top level
        hdl_toplevel = top,
        # always run the build-step
        always = True,
        # timescale for the simulation (some problems with this)
        timescale = ("1ps", "1ps"),
        # generating waveforms - must be set in both build() and test()
        waves = True,
        # compilation parameters in form of a dictionary
        parameters = parameters,
        # defining the path for sim_build/
        build_dir = build_path
    )

    runner.test(
        # defining, again, top-module
        hdl_toplevel = top,
        # defining test to run
        test_module = test_file,
        testcase = testcase,
        # defining path for which the test is being run
        # it will also be the level for which python imports are referenced
        test_dir = test_path,
        # defining the path for sim_build/
        build_dir = build_path,
        # results_xml files:
        results_xml= str(build_path / f"{output_name}.xml"),
        # define log_files for each test
        log_file = str(build_path / f"{output_name}.log"),
        verbose=True,
        # generating waveforms
        plusargs=[f"+dumpfile_path={wave_file}"],
        waves = True
    )
