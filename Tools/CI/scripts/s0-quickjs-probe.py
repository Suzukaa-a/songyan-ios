#!/usr/bin/env python3
"""S0 probe: how much a pinned QuickJS build costs one fresh process, measured in a simulator.

The plan's S0 asks what a script engine costs a keyboard extension before the engine is built
into the product. This probe answers the measurable half of that question without touching the
app: it builds QuickJS-ng for arm64 iOS-simulator, links a small C driver and runs it through
"xcrun simctl spawn". Each measured run is a fresh process, so the footprint delta belongs to
that process instead of to pages an earlier run left behind.

A spawned simulator process is not the keyboard extension: it has a different memory limit and
no extension sandbox, so these numbers are engine-cost evidence (a lower bound), not extension
acceptance. The same engine body is therefore also compiled into an arm64 simulator dylib
(--library-out) that s0-probe.sh copies the path of into the App Group defaults; the extension
loads it with dlopen and records the engine's cold start, footprint growth and kernel-tracked
peak footprint inside the extension's own process. Both carriers run the same workloads, so the
two measurements stay comparable.

The memory-limit sweep creates several runtimes inside one process on purpose: it only records
whether a script fits under a limit, and the exception text when it does not, so an out-of-memory
failure is not mistaken for a script error. Footprints are not reported for sweep entries for
that reason.

The QuickJS tag and its recorded digest are probe inputs, not a product version pin: the engine
version for the script feature is still undecided and belongs in the iOS repository's VERSIONS
files once the C bridge exists.

Usage: s0-quickjs-probe.py [--tag v0.18.0] [--sha256 DIGEST] [--udid UDID] [--runs N] [--out DIR]
       s0-quickjs-probe.py --tag v0.18.0 --library-out PATH   (build the extension dylib only)
"""

import argparse
import hashlib
import json
import os
import pathlib
import statistics
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_TAG = "v0.18.0"
# Recorded digest of the probe-only archive. A tag without a recorded digest is refused, so a
# download that changed under the same name cannot be measured unnoticed. This is an input of
# the probe, not a product version pin.
KNOWN_SHA256 = {
    "v0.18.0": "28bcd89aa3683fd2a946537e5ce3f11cc46b5cbf3383c7561aaef3df5ff9f1dd",
}
# QuickJS-ng keeps cutils/dtoa as plain sources; quickjs-libc is left out on purpose (the probe
# measures the script environment only, and the product would not ship stdlib modules).
SOURCES = ("quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c")

DRIVER = r'''
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"

static char last_error[256];

static uint64_t footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (uint64_t)info.phys_footprint;
}

static uint64_t available_memory(void) {
    uint64_t (*fn)(void) = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "os_proc_available_memory");
    return fn == NULL ? 0 : fn();
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

/* Two representative script bodies: the small one is a polish pass over a paragraph, the large
   one pushes a document-sized string through the same operations so heap growth, not only
   engine start-up, is visible. Neither calls a host API. */
#define SCRIPT_BODY(repetitions) \
    "(() => {" \
    "  var text = '';" \
    "  for (var i = 0; i < " #repetitions "; i++) text += '\\u8fd9\\u662f\\u4e00\\u6bb5\\u7528\\u4e8e\\u6d4b\\u8bd5\\u7684\\u6bb5\\u843d\\u3002';" \
    "  var parts = text.split('\\u3002').filter(Boolean);" \
    "  var out = '';" \
    "  for (var j = 0; j < parts.length; j++) out += parts[j].replace(/[\\uff0c\\u3002]/g, '') + '\\uff0c';" \
    "  var encoded = JSON.stringify({ input: text, output: out, items: parts.slice(0, 20) });" \
    "  var parsed = JSON.parse(encoded);" \
    "  return parsed.items.length + ':' + out.length + ':' + encoded.length;" \
    "})()"

static const char *WORKLOAD_SMALL = SCRIPT_BODY(200);
static const char *WORKLOAD_LARGE = SCRIPT_BODY(20000);
static const char *BOOTSTRAP = "var __s0 = { version: 1 };";

static int eval(JSContext *ctx, const char *source, JSValue *out) {
    JSValue value = JS_Eval(ctx, source, strlen(source), "<probe>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value)) {
        JSValue exception = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, exception);
        snprintf(last_error, sizeof(last_error), "%s", text == NULL ? "exception" : text);
        if (text != NULL) JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, exception);
        JS_FreeValue(ctx, value);
        return 0;
    }
    if (out != NULL) {
        *out = value;
    } else {
        JS_FreeValue(ctx, value);
    }
    return 1;
}

static void copy_result(JSContext *ctx, JSValue value, char *buffer, size_t size) {
    const char *text = JS_ToCString(ctx, value);
    snprintf(buffer, size, "%s", text == NULL ? "unprintable" : text);
    if (text != NULL) JS_FreeCString(ctx, text);
}

/* Smallest memory limit that still lets one workload run, for each workload shape. Runs several
   runtimes in one process, so only the outcome and the error text are reported. */
static void sweep(const char *name, const char *workload) {
    static const unsigned limitsMB[] = { 2, 4, 6, 8, 12, 16, 24, 32 };
    int limitCount = (int)(sizeof(limitsMB) / sizeof(limitsMB[0]));
    printf("  \"%s\": [\n", name);
    for (int i = 0; i < limitCount; i++) {
        JSRuntime *rt = JS_NewRuntime();
        JSContext *ctx = JS_NewContext(rt);
        int ok = 0;
        last_error[0] = '\0';
        if (rt != NULL && ctx != NULL) {
            JS_SetMemoryLimit(rt, (size_t)limitsMB[i] * 1024u * 1024u);
            ok = eval(ctx, BOOTSTRAP, NULL) && eval(ctx, "typeof 1", NULL);
            if (ok) {
                JSValue value = JS_UNDEFINED;
                ok = eval(ctx, workload, &value);
                if (ok) JS_FreeValue(ctx, value);
            }
            JS_FreeContext(ctx);
            JS_FreeRuntime(rt);
        } else {
            snprintf(last_error, sizeof(last_error), "runtime allocation failed");
        }
        printf("    { \"limitMB\": %u, \"scriptRuns\": %s, \"error\": \"%s\" }%s\n",
               limitsMB[i], ok ? "true" : "false", ok ? "" : last_error,
               i + 1 < limitCount ? "," : "");
    }
    printf("  ],\n");
}

int main(void) {
    printf("json_start\n");
    printf("{\n");
    printf("  \"footprintBeforeBytes\": %llu,\n", (unsigned long long)footprint());
    printf("  \"availableBytes\": %llu,\n", (unsigned long long)available_memory());

    /* One different measurement per process: everything a fresh script environment costs. */
    uint64_t before = footprint();
    last_error[0] = '\0';
    double t0 = now_ms();
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    double t1 = now_ms();
    int crash = 0;
    double t2 = 0, t3 = 0, t4 = 0;
    int bootstrapped = 0, smallOk = 0, largeOk = 0;
    uint64_t afterContext = before, afterSmall = before, afterLarge = before;
    char smallText[96] = "-";
    char largeText[96] = "-";
    char smallError[256] = "";
    char largeError[256] = "";
    if (rt == NULL || ctx == NULL) {
        crash = 1;
        snprintf(last_error, sizeof(last_error), "runtime allocation failed");
    } else {
        JS_SetMemoryLimit(rt, 64u * 1024u * 1024u);
        bootstrapped = eval(ctx, BOOTSTRAP, NULL);
        t2 = now_ms();
        afterContext = footprint();
        JSValue small = JS_UNDEFINED;
        smallOk = eval(ctx, WORKLOAD_SMALL, &small);
        t3 = now_ms();
        afterSmall = footprint();
        if (smallOk) {
            copy_result(ctx, small, smallText, sizeof(smallText));
            JS_FreeValue(ctx, small);
        } else {
            snprintf(smallError, sizeof(smallError), "%s", last_error);
        }
        JSValue large = JS_UNDEFINED;
        largeOk = eval(ctx, WORKLOAD_LARGE, &large);
        t4 = now_ms();
        afterLarge = footprint();
        if (largeOk) {
            copy_result(ctx, large, largeText, sizeof(largeText));
            JS_FreeValue(ctx, large);
        } else {
            snprintf(largeError, sizeof(largeError), "%s", last_error);
        }
    }
    printf(
        "  \"run\": { \"newRuntimeMs\": %.3f, \"bootstrapMs\": %.3f, \"smallWorkloadMs\": %.3f, "
        "\"largeWorkloadMs\": %.3f, \"footprintBeforeBytes\": %llu, "
        "\"footprintAfterContextBytes\": %llu, \"footprintAfterSmallBytes\": %llu, "
        "\"footprintAfterLargeBytes\": %llu, \"smallResult\": \"%s\", \"largeResult\": \"%s\", "
        "\"bootstrapOk\": %s, \"smallOk\": %s, \"largeOk\": %s, \"error\": \"%s\" },\n",
        t1 - t0, crash ? 0.0 : t2 - t1, t3 - t2, t4 - t3,
        (unsigned long long)before, (unsigned long long)afterContext,
        (unsigned long long)afterSmall, (unsigned long long)afterLarge,
        smallText, largeText, bootstrapped ? "true" : "false",
        smallOk ? "true" : "false", largeOk ? "true" : "false",
        crash ? last_error : (smallError[0] != '\0' ? smallError : largeError));
    if (rt != NULL && ctx != NULL) {
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
    }
    sweep("smallWorkloadLimitSweep", WORKLOAD_SMALL);
    sweep("largeWorkloadLimitSweep", WORKLOAD_LARGE);
    printf("  \"footprintAfterBytes\": %llu\n", (unsigned long long)footprint());
    printf("}\n");
    printf("json_end\n");
    return 0;
}
'''.strip() + "\n"
# One engine body, two carriers: the driver measured here and the static archive a probe build
# links into the keyboard extension. Splitting the driver text on its first driver-only function
# keeps the workloads, the footprint readers and the eval helpers single-sourced, so both
# measurements run the same scripts and stay comparable.
ENGINE, _, DRIVER_ONLY = DRIVER.partition("static void sweep(")
DRIVER_ONLY = "static void sweep(" + DRIVER_ONLY

# Exported entry points for the keyboard extension. A probe build links this archive into the
# extension binary (see S0_QUICKJS_LDFLAGS in the Xcode project), so the code is covered by the
# extension's own signature instead of being loaded from outside the bundle, which a device
# refuses. The extension resolves these with dlsym and turns the "key=value" lines into its
# artifact. Every call builds a fresh runtime, so the first call in that process is the engine's
# cold start there.
SHIM = ENGINE + r'''
#define S0QJS_EXPORT __attribute__((visibility("default")))

#ifndef S0QJS_TAG
#define S0QJS_TAG "unrecorded"
#endif

/* Kernel-tracked peak of this process's physical footprint; the sampled value cannot see a
   spike between two calls. */
static uint64_t peak_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (uint64_t)info.ledger_phys_footprint_peak;
}

/* Engine error text can carry newlines; one line per field keeps the caller's parser simple. */
static void flatten(char *text) {
    for (char *c = text; *c != '\0'; c++) {
        if (*c == '\n' || *c == '\r') *c = ' ';
    }
}

S0QJS_EXPORT int s0qjs_abi(void) {
    return 1;
}

S0QJS_EXPORT const char *s0qjs_tag(void) {
    return S0QJS_TAG;
}

S0QJS_EXPORT int s0qjs_measure(const char *name, unsigned limit_mb, char *out, unsigned cap) {
    char text[2048];
    const char *source = NULL;
    if (name == NULL) name = "";
    if (strcmp(name, "small") == 0) source = WORKLOAD_SMALL;
    if (strcmp(name, "large") == 0) source = WORKLOAD_LARGE;
    if (name[0] != '\0' && source == NULL) {
        int written = snprintf(text, sizeof(text), "ok=0\nerror=unknown workload %s\n", name);
        if (written < 0 || (unsigned)written >= cap) return 0;
        memcpy(out, text, (size_t)written + 1);
        return written;
    }

    char result[96] = "-";
    char error[192] = "";
    int bootstrapped = 0;
    int ran = 0;
    uint64_t footprint_before = footprint();
    uint64_t peak_before = peak_footprint();
    uint64_t available_before = available_memory();
    double t0 = now_ms();
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = (rt == NULL) ? NULL : JS_NewContext(rt);
    double t1 = now_ms();
    double t2 = t1;
    double t3 = t1;
    uint64_t footprint_after_runtime = footprint();
    last_error[0] = '\0';
    if (rt == NULL || ctx == NULL) {
        snprintf(error, sizeof(error), "runtime allocation failed");
    } else {
        if (limit_mb > 0) JS_SetMemoryLimit(rt, (size_t)limit_mb * 1024u * 1024u);
        bootstrapped = eval(ctx, BOOTSTRAP, NULL);
        t2 = now_ms();
        if (bootstrapped && source != NULL) {
            JSValue value = JS_UNDEFINED;
            ran = eval(ctx, source, &value);
            if (ran) {
                copy_result(ctx, value, result, sizeof(result));
                JS_FreeValue(ctx, value);
            } else {
                snprintf(error, sizeof(error), "%s", last_error);
            }
        }
        t3 = now_ms();
    }
    uint64_t footprint_after = footprint();
    uint64_t peak_after = peak_footprint();
    uint64_t available_after = available_memory();
    if (rt != NULL) {
        if (ctx != NULL) JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
    }
    flatten(result);
    flatten(error);
    int ok = source == NULL ? bootstrapped : ran;
    int written = snprintf(
        text, sizeof(text),
        "ok=%d\n"
        "workload=%s\n"
        "limitMB=%u\n"
        "bootstrapOk=%d\n"
        "runtimeMs=%.3f\n"
        "bootstrapMs=%.3f\n"
        "workloadMs=%.3f\n"
        "footprintBeforeBytes=%llu\n"
        "footprintAfterRuntimeBytes=%llu\n"
        "footprintAfterBytes=%llu\n"
        "peakBeforeBytes=%llu\n"
        "peakAfterBytes=%llu\n"
        "availableBeforeBytes=%llu\n"
        "availableAfterBytes=%llu\n"
        "result=%s\n"
        "error=%s\n",
        ok, name, limit_mb, bootstrapped,
        t1 - t0, t2 - t1, t3 - t2,
        (unsigned long long)footprint_before,
        (unsigned long long)footprint_after_runtime,
        (unsigned long long)footprint_after,
        (unsigned long long)peak_before,
        (unsigned long long)peak_after,
        (unsigned long long)available_before,
        (unsigned long long)available_after,
        result, error);
    if (written < 0 || (unsigned)written >= cap) return 0;
    memcpy(out, text, (size_t)written + 1);
    return written;
}
'''.strip() + "\n"


def require_xcode():
    """xcode-select often points at CommandLineTools; fall back to an installed Xcode, the same
    way Tools/CI/scripts/lib/xcode.sh does, so a Makefile run works in either setup."""
    selected = os.environ.get("DEVELOPER_DIR", "")
    candidates = [selected, subprocess.run(
        ["xcode-select", "-p"], capture_output=True, text=True).stdout.strip(),
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer"]
    for candidate in candidates:
        if candidate and (pathlib.Path(candidate) / "usr/bin/xcodebuild").is_file():
            os.environ["DEVELOPER_DIR"] = candidate
            return
    raise SystemExit("a full Xcode is required; set DEVELOPER_DIR")


def run(command, **kwargs):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    return subprocess.run(command, check=True, **kwargs)


def simulator_udid(explicit):
    if explicit:
        return explicit
    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available"], check=True,
        capture_output=True, text=True).stdout
    candidates = []
    for line in listing.splitlines():
        if "(Booted)" not in line:
            continue
        stripped = line.strip()
        name = stripped.split(" (")[0]
        identifier = stripped.split("(")[-1].split(")")[0]
        candidates.append((name, identifier))
    for preferred in ("Songyan-S0P", "Songyan-Dev"):
        for name, identifier in candidates:
            if name == preferred:
                return identifier
    if candidates:
        return candidates[0][1]
    raise SystemExit("no booted simulator; run make sim-stage first")


def fetch_sources(tag, scratch):
    archive = scratch / f"quickjs-ng-{tag}.tar.gz"
    if not archive.exists():
        url = f"https://github.com/quickjs-ng/quickjs/archive/refs/tags/{tag}.tar.gz"
        print(f"download {url}", flush=True)
        urllib.request.urlretrieve(url, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    unpacked = scratch / f"quickjs-ng-{tag}"
    if not unpacked.exists():
        run(["tar", "-xzf", str(archive), "-C", str(scratch)])
        extracted = next(
            path for path in scratch.iterdir()
            if path.is_dir() and path.name.startswith("quickjs-") and path != unpacked)
        extracted.rename(unpacked)
    return digest, unpacked


def median(values):
    return round(statistics.median(values), 3) if values else None

# A probe build of the keyboard extension links this archive into its own binary, so the engine
# code is covered by the extension's signature; a dylib loaded from outside the bundle would be
# refused on a device. The simulator slice set matches what xcodebuild may ask for.
ARCHIVE_PLATFORMS = {
    "simulator": (
        "iphonesimulator",
        ("arm64-apple-ios17.0-simulator", "x86_64-apple-ios17.0-simulator"),
    ),
    "device": ("iphoneos", ("arm64-apple-ios17.0",)),
}


def build_archive(sources, scratch, tag, digest, platform, destination):
    probe_source = scratch / "s0-quickjs-engine.c"
    # The stamp below keys on the source text, not on the file's timestamp, so writing the file
    # unchanged must not look like new work either.
    if not probe_source.exists() or probe_source.read_text() != SHIM:
        probe_source.write_text(SHIM)
    sdk_name, targets = ARCHIVE_PLATFORMS[platform]
    sdk = subprocess.run(
        ["xcrun", "--sdk", sdk_name, "--show-sdk-path"],
        check=True, capture_output=True, text=True).stdout.strip()
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Rebuild only when the platform, tag, digest or probe source changed, so repeated probe
    # runs do not pay the engine compile again.
    stamp = destination.with_name(destination.name + ".stamp")
    source_digest = hashlib.sha256(SHIM.encode()).hexdigest()
    wanted = f"{platform} {tag} {digest} {source_digest}"
    if destination.exists() and stamp.exists() and stamp.read_text().strip() == wanted:
        return destination
    objects = []
    for target in targets:
        arch = target.split("-")[0]
        for name in SOURCES:
            object_path = scratch / f"{name}.{platform}.{arch}.o"
            run([
                "xcrun", "--sdk", sdk_name, "clang",
                "-target", target, "-isysroot", sdk, "-O2", "-D_GNU_SOURCE",
                "-I", str(sources), "-c", str(sources / name), "-o", str(object_path),
            ])
            objects.append(object_path)
        shim_object = scratch / f"s0qjs-engine.{platform}.{arch}.o"
        run([
            "xcrun", "--sdk", sdk_name, "clang",
            "-target", target, "-isysroot", sdk, "-O2", "-D_GNU_SOURCE",
            f'-DS0QJS_TAG="{tag}"', "-I", str(sources),
            "-c", str(probe_source), "-o", str(shim_object),
        ])
        objects.append(shim_object)
    run(["libtool", "-static", "-o", str(destination),
         *[str(item) for item in objects]])
    stamp.write_text(wanted + "\n")
    return destination


def main():
    parser = argparse.ArgumentParser(
        description="Build and run the S0 QuickJS resource probe on a simulator.")
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--sha256", default="", help="digest to require when the tag has no recorded one")
    parser.add_argument("--udid", default="")
    parser.add_argument("--runs", type=int, default=5, help="fresh simulator processes to measure")
    parser.add_argument("--out", default="")
    parser.add_argument(
        "--library-out", default="",
        help="build the probe archive the keyboard extension links, then exit")
    parser.add_argument(
        "--platform", default="simulator", choices=sorted(ARCHIVE_PLATFORMS),
        help="platform of the archive built by --library-out")
    arguments = parser.parse_args()
    require_xcode()

    scratch = ROOT / ".scratch/s0-quickjs"
    scratch.mkdir(parents=True, exist_ok=True)
    digest, sources = fetch_sources(arguments.tag, scratch)
    expected = (arguments.sha256 or KNOWN_SHA256.get(arguments.tag, "")).lower()
    if not expected:
        raise SystemExit(
            f"no recorded sha256 for {arguments.tag}; pass --sha256 <digest> to accept the archive")
    if digest != expected:
        raise SystemExit(
            f"sha256 mismatch for {arguments.tag}: expected {expected}, got {digest}; "
            "refusing to measure an archive that changed")
    print(f"source {sources}")
    print(f"sha256 {digest} (verified against {expected})")

    missing = [name for name in SOURCES if not (sources / name).exists()]
    if missing:
        raise SystemExit(f"missing QuickJS sources: {missing}")

    if arguments.library_out:
        archive = build_archive(
            sources, scratch, arguments.tag, digest, arguments.platform,
            pathlib.Path(arguments.library_out))
        print(f"archive {archive}")
        print(f"tag {arguments.tag}")
        print(f"platform {arguments.platform}")
        return

    driver = scratch / "s0-quickjs-probe.c"
    driver.write_text(DRIVER)
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                         check=True, capture_output=True, text=True).stdout.strip()
    executable = scratch / "s0-quickjs-probe"
    run([
        "xcrun", "--sdk", "iphonesimulator", "clang",
        "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
        "-O2", "-D_GNU_SOURCE",
        "-I", str(sources),
        str(driver), *[str(sources / name) for name in SOURCES],
        "-lm", "-o", str(executable),
    ])
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(executable)])

    udid = simulator_udid(arguments.udid)
    print(f"simulator {udid}")
    reports = []
    for index in range(arguments.runs):
        completed = run(["xcrun", "simctl", "spawn", udid, str(executable)],
                        capture_output=True, text=True)
        text = completed.stdout
        start = text.find("json_start")
        end = text.find("json_end")
        if start < 0 or end < 0:
            raise SystemExit("driver did not print a JSON block:\n" + text + "\n" + completed.stderr)
        report = json.loads(text[start + len("json_start"):end])
        report["simulator"] = udid
        report["tag"] = arguments.tag
        report["iteration"] = index
        # The driver writes nothing to stderr when the measurement is clean; keep it when it
        # does, so a crash or a sanitizer message is not lost.
        report["driverStderr"] = completed.stderr.strip()
        reports.append(report)

    runs = [entry["run"] for entry in reports]
    summary = {
        "processes": len(reports),
        "newRuntimeMs": sorted(round(item["newRuntimeMs"], 3) for item in runs),
        "newRuntimeMedianMs": median([item["newRuntimeMs"] for item in runs]),
        "smallWorkloadMedianMs": median([item["smallWorkloadMs"] for item in runs]),
        "largeWorkloadMedianMs": median([item["largeWorkloadMs"] for item in runs]),
        "footprintBeforeBytes": [item["footprintBeforeBytes"] for item in runs],
        "footprintAfterContextBytes": [item["footprintAfterContextBytes"] for item in runs],
        "footprintAfterLargeBytes": [item["footprintAfterLargeBytes"] for item in runs],
        "anyDriverStderr": any(entry["driverStderr"] for entry in reports),
        "failedRuns": [
            entry["iteration"] for entry in reports
            if not (entry["run"]["smallOk"] and entry["run"]["largeOk"])
        ],
    }
    print(json.dumps(summary, indent=2, sort_keys=True))

    destination = pathlib.Path(arguments.out) if arguments.out else ROOT / ".local/ci/s0-quickjs"
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / "report.json"
    output.write_text(json.dumps({
        "tag": arguments.tag,
        "archiveSha256": digest,
        "archiveSha256Verified": True,
        "simulator": udid,
        "note": (
            "one fresh simulator process per measurement; footprint deltas are that process's "
            "and are not affected by page reuse from an earlier run inside it. The memory-limit "
            "sweeps create several runtimes in one process and therefore report only whether the "
            "script runs and the exception text, not footprints. Not the keyboard extension."),
        "summary": summary,
        "reports": reports,
    }, indent=2, sort_keys=True))
    print(f"report {output}")
    if summary["anyDriverStderr"]:
        print("WARNING: driver stderr is not empty; see report", flush=True)
    if summary["failedRuns"]:
        raise SystemExit(f"script runs failed in processes: {summary['failedRuns']}")


if __name__ == "__main__":
    main()
