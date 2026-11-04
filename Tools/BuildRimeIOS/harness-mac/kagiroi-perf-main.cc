// ---------------------------------------------------------------------------
// kagiroi-perf-main.cc — development-only macOS per-key latency probe for a
// real, pinned librime 1.17.0 + librime-lua process.
//
// This is deliberately NOT a simulator process and claims nothing about the iOS
// keyboard extension. It measures one thing only: the wall time from feeding one
// key with rb_process_key() to obtaining the updated rb_snapshot with
// rb_snapshot_get() on a single thread. Snapshot copying is part of the measured
// span because a keyboard front end must read the new composition before it can
// repaint; everything else (probe, assertions, JSON) runs outside the timed
// regions.
//
// Deployment modes match the production bridge:
//   * prebuilt — rb_engine_create_prebuilt() over an immutable compiled
//     generation (the host App's published .bin directory); no maintenance runs;
//   * source   — rb_engine_create() over a shared package, i.e. a real cold
//     deployment into a fresh user directory.
//
// Usage: see kagiroi-performance-harness.sh (this binary is script-internal).
// Missing/invalid fixtures, a non-1.17.0 runtime, a schema that does not
// compose, a key the engine does not consume, and a missing expected candidate
// are hard failures (exit 2), so an empty fixture can never be mistaken for a
// passing measurement.
// ---------------------------------------------------------------------------
#include "rime_bridge.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace {

constexpr int kExitUsage = 64;
constexpr int kExitFailure = 2;

struct Options {
  std::string mode = "prebuilt";
  std::string shared;
  std::string compiled;
  std::string user;
  std::string schema;
  std::string text;
  std::string label = "run";
  std::string probe_text;
  std::string expect_candidate;
  int rounds = 10;
  int warmup = 1;
};

struct RoundSamples {
  std::vector<double> values;
};

struct ProbeResult {
  bool ran = false;
  std::string preedit;
  std::vector<std::string> candidates;
  bool expect_found = false;
};

using Clock = std::chrono::steady_clock;

[[noreturn]] void fail(const std::string& message) {
  std::fprintf(stderr, "[FAIL] %s\n", message.c_str());
  std::exit(kExitFailure);
}

[[noreturn]] void usage(const char* message) {
  std::fprintf(stderr,
               "[usage] %s\n"
               "  --mode prebuilt|source --shared DIR --schema ID --text ASCII --user DIR\n"
               "  [--compiled DIR] [--label NAME] [--probe-text ASCII] [--expect-candidate TEXT]\n"
               "  [--rounds N] [--warmup N]\n",
               message);
  std::exit(kExitUsage);
}

bool is_file(const std::string& path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool is_dir(const std::string& path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

std::string join(const std::string& dir, const std::string& name) {
  if (!dir.empty() && dir.back() == '/') return dir + name;
  return dir + "/" + name;
}

int parse_count(const char* flag, const char* value, bool allow_zero) {
  char* end = nullptr;
  long parsed = std::strtol(value, &end, 10);
  if (!end || *end != '\0' || parsed < (allow_zero ? 0 : 1) || parsed > 100000) usage(flag);
  return static_cast<int>(parsed);
}

Options parse_options(int argc, char** argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const std::string flag = argv[i];
    auto value = [&]() -> const char* {
      if (i + 1 >= argc) usage(flag.c_str());
      return argv[++i];
    };
    if (flag == "--mode") {
      options.mode = value();
    } else if (flag == "--shared") {
      options.shared = value();
    } else if (flag == "--compiled") {
      options.compiled = value();
    } else if (flag == "--user") {
      options.user = value();
    } else if (flag == "--schema") {
      options.schema = value();
    } else if (flag == "--text") {
      options.text = value();
    } else if (flag == "--label") {
      options.label = value();
    } else if (flag == "--probe-text") {
      options.probe_text = value();
    } else if (flag == "--expect-candidate") {
      options.expect_candidate = value();
    } else if (flag == "--rounds") {
      options.rounds = parse_count(flag.c_str(), value(), false);
    } else if (flag == "--warmup") {
      options.warmup = parse_count(flag.c_str(), value(), true);
    } else {
      usage(flag.c_str());
    }
  }
  if (options.mode != "prebuilt" && options.mode != "source") usage("--mode");
  if (options.shared.empty()) usage("--shared");
  if (options.schema.empty()) usage("--schema");
  if (options.text.empty()) usage("--text");
  if (options.user.empty()) usage("--user");
  if (options.mode == "prebuilt" && options.compiled.empty()) usage("--compiled");
  return options;
}

// Every fixture the engine is about to read is checked up front, so an empty or
// half-staged directory fails as a fixture error instead of an engine error.
void preflight(const Options& options) {
  if (!is_dir(options.shared)) {
    fail("fixture shared directory is missing: " + options.shared);
  }
  if (!is_file(join(options.shared, "default.yaml"))) {
    fail("fixture shared directory has no default.yaml: " + options.shared);
  }
  const std::string shared_schema = join(options.shared, options.schema + ".schema.yaml");
  if (!is_file(shared_schema)) {
    fail("fixture shared directory has no " + options.schema + ".schema.yaml: " + shared_schema);
  }
  if (!is_dir(options.user)) {
    fail("fixture user directory is missing: " + options.user);
  }
  if (options.mode == "prebuilt") {
    if (!is_dir(options.compiled)) {
      fail("fixture compiled directory is missing: " + options.compiled);
    }
    if (!is_file(join(options.compiled, "default.yaml"))) {
      fail("fixture compiled directory has no default.yaml: " + options.compiled);
    }
    if (!is_file(join(options.compiled, options.schema + ".schema.yaml"))) {
      fail("fixture compiled directory has no " + options.schema + ".schema.yaml: " +
           join(options.compiled, options.schema + ".schema.yaml"));
    }
  }
}

std::string json_escape(const std::string& text) {
  std::string out;
  out.reserve(text.size() + 8);
  for (unsigned char c : text) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

std::string json_string(const std::string& text) { return "\"" + json_escape(text) + "\""; }

// Nearest-rank percentile: the smallest sample whose rank covers p.
double percentile(const std::vector<double>& sorted, double p) {
  const size_t index = static_cast<size_t>(std::ceil(p * static_cast<double>(sorted.size())));
  return sorted.at(index - 1);
}

// Feeds one round of keys after clearing the composition. Every sample covers
// exactly rb_process_key() plus rb_snapshot_get(); the snapshot is freed outside
// the timed span for both texts in the same way.
RoundSamples run_round(rb_engine* engine, uintptr_t session, const std::string& text,
                       int* unconsumed) {
  if (!rb_clear_composition(engine, session)) {
    fail("rb_clear_composition() failed before a measured round");
  }
  rb_snapshot* cleared = rb_snapshot_get(engine, session);
  if (!cleared) fail("rb_snapshot_get() returned NULL after clearing the composition");
  if (cleared->input[0] != '\0' || cleared->is_composing) {
    fail("composition was not empty after rb_clear_composition(); rounds cannot be compared");
  }
  rb_snapshot_free(cleared);

  RoundSamples round;
  round.values.reserve(text.size());
  for (unsigned char key : text) {
    if (key < 0x20 || key > 0x7e) {
      fail("text must be printable ASCII; the harness feeds one keycode per byte");
    }
    const auto start = Clock::now();
    const int consumed = rb_process_key(engine, session, static_cast<int>(key), 0);
    rb_snapshot* snapshot = rb_snapshot_get(engine, session);
    const auto end = Clock::now();
    if (!snapshot) fail("rb_snapshot_get() returned NULL after a key");
    if (!consumed) ++(*unconsumed);
    round.values.push_back(std::chrono::duration<double, std::milli>(end - start).count());
    rb_snapshot_free(snapshot);
  }
  return round;
}

ProbeResult run_probe(rb_engine* engine, uintptr_t session, const Options& options) {
  ProbeResult result;
  if (options.probe_text.empty()) return result;
  result.ran = true;
  if (!rb_clear_composition(engine, session)) fail("rb_clear_composition() failed before the probe");
  for (unsigned char key : options.probe_text) {
    if (key < 0x20 || key > 0x7e) fail("probe text must be printable ASCII");
    if (!rb_process_key(engine, session, static_cast<int>(key), 0)) {
      fail("probe key was not consumed by the engine");
    }
  }
  rb_snapshot* snapshot = rb_snapshot_get(engine, session);
  if (!snapshot) fail("rb_snapshot_get() returned NULL after the probe");
  result.preedit = snapshot->preedit;
  for (int i = 0; i < snapshot->num_candidates; ++i) {
    result.candidates.emplace_back(snapshot->candidates[i].text);
    if (!options.expect_candidate.empty() &&
        result.candidates.back() == options.expect_candidate) {
      result.expect_found = true;
    }
  }
  rb_snapshot_free(snapshot);
  if (!options.expect_candidate.empty() && !result.expect_found) {
    fail("expected candidate " + options.expect_candidate + " is missing after probe text " +
         options.probe_text);
  }
  return result;
}

std::string number_array(const std::vector<double>& values) {
  std::string out = "[";
  char buffer[32];
  for (size_t i = 0; i < values.size(); ++i) {
    std::snprintf(buffer, sizeof(buffer), "%.3f", values[i]);
    if (i) out += ", ";
    out += buffer;
  }
  out += "]";
  return out;
}

void print_number_array(const char* name, const std::vector<double>& values, bool trailing_comma) {
  std::printf("  \"%s\": %s%s\n", name, number_array(values).c_str(), trailing_comma ? "," : "");
}

void print_string_array(const char* name, const std::vector<std::string>& values,
                        bool trailing_comma) {
  std::printf("  \"%s\": [", name);
  for (size_t i = 0; i < values.size(); ++i) {
    std::printf("%s%s", i ? ", " : "", json_string(values[i]).c_str());
  }
  std::printf("]%s\n", trailing_comma ? "," : "");
}

}  // namespace

int main(int argc, char** argv) {
  const Options options = parse_options(argc, argv);
  preflight(options);

  rb_engine* engine = nullptr;
  if (options.mode == "prebuilt") {
    engine = rb_engine_create_prebuilt(options.shared.c_str(), options.user.c_str(), "rime.songyan.kagiroi-perf",
                                       "1.0", options.compiled.c_str());
  } else {
    engine = rb_engine_create(options.shared.c_str(), options.user.c_str(), "rime.songyan.kagiroi-perf", "1.0");
  }
  if (!engine) fail("rb_engine_create() returned NULL for mode " + options.mode);
  if (!rb_engine_ready(engine)) {
    const std::string error = rb_engine_last_error(engine);
    rb_engine_destroy(engine);
    fail("engine not ready (" + options.mode + "): " + error);
  }
  const std::string version = rb_engine_version(engine);
  if (version != "1.17.0") {
    rb_engine_destroy(engine);
    fail("runtime librime version is " + version + ", expected the pinned 1.17.0");
  }

  const uintptr_t session = rb_session_create(engine);
  if (session == 0) {
    rb_engine_destroy(engine);
    fail("rb_session_create() returned 0");
  }
  if (!rb_select_schema(engine, session, options.schema.c_str())) {
    rb_session_destroy(engine, session);
    rb_engine_destroy(engine);
    fail("rb_select_schema(\"" + options.schema + "\") failed");
  }

  const ProbeResult probe = run_probe(engine, session, options);
  if (probe.ran) {
    if (!rb_clear_composition(engine, session)) fail("rb_clear_composition() failed after the probe");
  }

  int unconsumed = 0;
  for (int i = 0; i < options.warmup; ++i) {
    run_round(engine, session, options.text, &unconsumed);
  }
  std::vector<RoundSamples> rounds;
  rounds.reserve(options.rounds);
  for (int i = 0; i < options.rounds; ++i) {
    rounds.push_back(run_round(engine, session, options.text, &unconsumed));
  }

  // Final state sanity: the text must still be composing with candidates, i.e.
  // the keys really drove the schema instead of being inserted as literal text.
  rb_snapshot* final_snapshot = rb_snapshot_get(engine, session);
  if (!final_snapshot) fail("rb_snapshot_get() returned NULL after the measured rounds");
  const std::string final_preedit = final_snapshot->preedit;
  const int final_candidates = final_snapshot->num_candidates;
  const bool final_composing = final_snapshot->is_composing != 0;
  rb_snapshot_free(final_snapshot);
  if (!final_composing || final_candidates <= 0) {
    fail("the measured text did not leave a composing session with candidates");
  }
  if (unconsumed != 0) {
    fail("the engine did not consume " + std::to_string(unconsumed) +
         " keys; timing would not be a keyboard input path");
  }

  std::vector<double> pooled;
  std::vector<double> round_p50;
  std::vector<double> round_p95;
  for (const RoundSamples& round : rounds) {
    pooled.insert(pooled.end(), round.values.begin(), round.values.end());
    std::vector<double> sorted = round.values;
    std::sort(sorted.begin(), sorted.end());
    round_p50.push_back(percentile(sorted, 0.50));
    round_p95.push_back(percentile(sorted, 0.95));
  }
  std::vector<double> sorted_pooled = pooled;
  std::sort(sorted_pooled.begin(), sorted_pooled.end());
  double sum = 0.0;
  for (double value : pooled) sum += value;
  const double mean = sum / static_cast<double>(pooled.size());

  rb_session_destroy(engine, session);
  rb_engine_destroy(engine);

  std::printf("{\n");
  std::printf("  \"label\": %s,\n", json_string(options.label).c_str());
  std::printf("  \"mode\": %s,\n", json_string(options.mode).c_str());
  std::printf("  \"schema\": %s,\n", json_string(options.schema).c_str());
  std::printf("  \"engine_version\": %s,\n", json_string(version).c_str());
  std::printf("  \"build\": {\"harness\": \"clang -O2\", \"librime\": "
              "\"pinned macOS static 1.17.0 (upstream Release build)\", \"lua\": "
              "\"pinned librime-lua + Lua 5.4.9 built with -O2\"},\n");
  std::printf("  \"paths\": {\"shared\": %s, \"compiled\": %s, \"user\": %s},\n",
              json_string(options.shared).c_str(),
              options.compiled.empty() ? "null" : json_string(options.compiled).c_str(),
              json_string(options.user).c_str());
  std::printf("  \"timing\": %s,\n",
              json_string("single thread; steady_clock around rb_process_key() + "
                          "rb_snapshot_get() per key, snapshot freed outside the span")
                  .c_str());
  std::printf("  \"text\": %s,\n", json_string(options.text).c_str());
  std::printf("  \"keys\": %zu,\n", options.text.size());
  std::printf("  \"rounds\": %d,\n", options.rounds);
  std::printf("  \"warmup_rounds\": %d,\n", options.warmup);
  std::printf("  \"cleared_between_rounds\": true,\n");
  std::printf("  \"unconsumed_keys\": %d,\n", unconsumed);
  std::printf("  \"samples_ms\": [");
  for (size_t r = 0; r < rounds.size(); ++r) {
    std::printf("%s%s", r ? ",\n    " : "\n    ", number_array(rounds[r].values).c_str());
  }
  std::printf("\n  ],\n");
  print_number_array("round_p50_ms", round_p50, true);
  print_number_array("round_p95_ms", round_p95, true);
  std::printf("  \"pooled_p50_ms\": %.3f,\n", percentile(sorted_pooled, 0.50));
  std::printf("  \"pooled_p95_ms\": %.3f,\n", percentile(sorted_pooled, 0.95));
  std::printf("  \"pooled_mean_ms\": %.3f,\n", mean);
  std::printf("  \"pooled_max_ms\": %.3f,\n", sorted_pooled.back());
  std::printf("  \"final\": {\"composing\": %s, \"num_candidates\": %d, \"preedit\": %s},\n",
              final_composing ? "true" : "false", final_candidates,
              json_string(final_preedit).c_str());
  if (probe.ran) {
    std::printf("  \"probe\": {\"text\": %s, \"preedit\": %s, \"candidates\": ",
                json_string(options.probe_text).c_str(), json_string(probe.preedit).c_str());
    std::vector<std::string> candidates = probe.candidates;
    if (candidates.size() > 20) candidates.resize(20);
    std::printf("[");
    for (size_t i = 0; i < candidates.size(); ++i) {
      std::printf("%s%s", i ? ", " : "", json_string(candidates[i]).c_str());
    }
    std::printf("], \"expect\": %s, \"expect_found\": %s}\n",
                options.expect_candidate.empty() ? "null" : json_string(options.expect_candidate).c_str(),
                probe.expect_found ? "true" : "false");
  } else {
    std::printf("  \"probe\": null\n");
  }
  std::printf("}\n");
  return 0;
}
