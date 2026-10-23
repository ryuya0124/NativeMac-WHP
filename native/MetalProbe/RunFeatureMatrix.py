#!/usr/bin/env python3
"""Build and execute authored Metal checks locally on each macOS test host.

Run once in the reference Mac and once in the VM. Compare the JSON outputs
with --compare REFERENCE.json VM.json --output comparison.json. This does not
change feature claims, inject adapters, or treat API presence as execution.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import signal
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
SOURCES = {
    "features": ("FeatureExecutionProbe.m", []),
    "compute": ("Probe.m", []),
    "intrinsic": ("BitReverseProbe.m", []),
    "readback": ("TextureReadbackProbe.m", []),
    "argument": ("ArgumentBufferProbe.m", []),
    "heap": ("HeapProbe.m", ["IOKit"]),
    "heap-texture": ("HeapTextureProbe.m", ["IOKit"]),
    "nocopy": ("NoCopyProbe.m", ["IOKit"]),
    "mps": ("MPSGraphProbe.m", ["IOKit", "MetalPerformanceShaders", "MetalPerformanceShadersGraph"]),
    "convolution": ("MPSConvolutionProbe.m", ["MetalPerformanceShadersGraph"]),
    "mps-operations": ("MPSOperationsProbe.m", ["MetalPerformanceShadersGraph"]),
    "mps-cnn": ("MPSCNNProbe.m", ["MetalPerformanceShaders"]),
    "vector-offset": ("VectorOffsetProbe.m", []),
}
CASES = [("texture-transfer/" + name, "features", ["texture-" + name])
         for name in ("r8", "rg8", "rgba8", "bgra8", "r32uint", "rgba8uint",
                      "r32float", "rgba16float", "rgba32float")]
CASES += [("render/" + name, "features", [name]) for name in ("draw", "indirect-draw", "icb")]
CASES += [("synchronization/" + name, "features", [name]) for name in ("fence", "shared-event")]
CASES += [("binding/basic-compute", "compute", []),
          ("binding/vector-offsets", "vector-offset", []),
          ("texture-readback/mips-slices-subregions", "readback", []),
          ("intrinsic/uint4-reverse-bits", "intrinsic", []),
          ("binding/mixed-argument-buffer", "argument", []),
          ("buffer/no-copy-subpage-alias", "nocopy", ["8192", "1048576", "1536"]),
          ("mps/vector-constant-add", "mps", ["constant"]),
          ("mps/convolution-float32", "convolution", ["32", "32"]),
          ("mps/convolution-float16", "convolution", ["32", "32", "half"]),
          ("heap/private-buffer", "heap", ["0"]),
          ("heap/private-texture", "heap-texture", [])]
CASES += [("mps/" + name + "-" + kind, "mps-operations",
           [name] + (["half"] if kind == "float16" else []))
          for name in ("matmul", "matmul-transpose", "softmax", "sigmoid", "sum", "sum-exact")
          for kind in ("float32", "float16")]
CASES += [("mps/cnn-convolution", "mps-cnn", ["16", "32"]),
          ("mps/cnn-managed-readback", "mps-cnn", ["16", "32", "managed"]),
          ("mps/convolution-chain", "convolution", ["16", "32", "float", "4", "relu"]),
          ("mps/depthwise-chain", "convolution", ["16", "32", "float", "4", "relu", "16"])]

# Private addresses, encoded argument words, descriptor dumps and raw logs are
# deliberately excluded. Reports contain correctness counters, not pointers.
FIELDS = {"passed", "verified", "aliasVerified", "computeVerified", "mismatches", "checked",
          "checkedValues", "checkedBytes", "expectedValues", "atomicCount",
          "commandCompleted", "resultAvailable", "allocated", "heap", "buffer",
          "texture", "size", "align", "sameContents", "device", "stage",
          "laneMatches", "argumentBufferTier", "count", "matches", "gpuSeconds"}
FIELDS.update({"errors", "cases", "maxError", "half", "channels", "width", "layers", "groups", "outputs", "applicable", "reason"})


def run_process(argv, timeout, environment):
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, env=environment)
    try:
        stdout, _ = process.communicate(timeout=timeout)
        return process.returncode, stdout.decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, _ = process.communicate()
        return process.returncode, stdout.decode("utf-8", "replace"), True


def execute(args):
    if platform.system() != "Darwin":
        raise SystemExit("Execute on macOS; --compare can run on any host")
    output = pathlib.Path(args.output).resolve()
    build = output.parent / (output.stem + "-build")
    build.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    for key in list(environment):
        if key.startswith("NM_") or key.startswith("DYLD_"):
            del environment[key]
    binaries, errors, hashes = {}, {}, {}
    for name, (filename, frameworks) in SOURCES.items():
        source = ROOT / filename
        hashes[filename] = hashlib.sha256(source.read_bytes()).hexdigest()
        binary = build / name
        command = ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                   "-framework", "Foundation", "-framework", "Metal"]
        for framework in frameworks:
            command += ["-framework", framework]
        command += [str(source), "-o", str(binary)]
        status = subprocess.run(command, env=environment).returncode
        if status:
            errors[name] = status
        else:
            binaries[name] = binary
    report = {"schema": 1, "label": args.label, "architecture": platform.machine(),
              "macOS": platform.mac_ver()[0], "sources": hashes,
              "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "cases": []}
    stopped = False
    for case, name, arguments in CASES:
        entry = {"case": case}
        if stopped:
            entry["status"] = "not-run-after-timeout"
        elif name in errors:
            entry.update(status="build-failed", exitCode=errors[name])
        else:
            start = time.monotonic()
            status, stdout, timed_out = run_process([str(binaries[name])] + arguments,
                                                   args.timeout, environment)
            measurements = []
            for line in stdout.splitlines():
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    measurements.append({k: v for k, v in value.items() if k in FIELDS})
            entry.update(status="timeout" if timed_out else ("not-applicable" if status == 77 else ("pass" if status == 0 else "fail")),
                         exitCode=status, seconds=round(time.monotonic()-start, 3),
                         measurements=measurements)
            stopped = timed_out
        report["cases"].append(entry)
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(case + ": " + entry["status"], flush=True)


def compare(args):
    reference, guest = [json.loads(pathlib.Path(p).read_text(encoding="utf-8")) for p in args.compare]
    if reference["sources"] != guest["sources"]:
        raise SystemExit("Source hashes differ; rebuild both hosts from the same sources")
    ref = {x["case"]: x for x in reference["cases"]}
    rows = [{"case": x["case"], "reference": ref.get(x["case"], {}).get("status", "missing"),
             "vm": x["status"]} for x in guest["cases"]]
    path = pathlib.Path(args.output)
    path.write_text(json.dumps({"reference": reference["label"], "vm": guest["label"],
                                "sources": reference["sources"], "cases": rows}, indent=2)+"\n", encoding="utf-8")
    markdown = ["| Executed check | Reference | VM |", "|---|---|---|"]
    markdown += ["| {case} | {reference} | {vm} |".format(**row) for row in rows]
    path.with_suffix(".md").write_text("\n".join(markdown)+"\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="local")
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=int, default=40)
    parser.add_argument("--compare", nargs=2, metavar=("REFERENCE", "VM"))
    arguments = parser.parse_args()
    compare(arguments) if arguments.compare else execute(arguments)
