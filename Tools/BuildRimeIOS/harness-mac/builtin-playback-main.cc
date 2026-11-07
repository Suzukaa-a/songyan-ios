// ---------------------------------------------------------------------------
// builtin-playback-main.cc — development-only macOS replay for the built-in
// engine fixtures (Tests/EngineFixtures/Builtin/playback_cases.json) against a
// real, pinned librime 1.17.0 process.
//
// The JSON fixture is parsed by Tools/BuildRimeIOS/scripts/
// playback-cases-to-tsv.py (Python stdlib json only), which also resolves every
// fixture layout to the deployed schema id from the staged shared tree. This
// binary therefore reads a headerless TSV: there is no hand-written JSON parser
// here, and no fixture expectation is derived from the harness.
//
// One case is replayed the way a keyboard front end does it:
//   rb_select_schema -> rb_set_option (the schema's own switches) ->
//   rb_process_key per ASCII key -> rb_snapshot_get -> page forward while the
//   expected candidate is not on the current page ->
//   rb_select_candidate_on_current_page -> rb_snapshot_get().commit_text.
// A case that carries options does not depend on state left behind by the
// previous case: the fixture lists every member of an exclusive switch group
// explicitly (the four script states are a librime radio group), so the
// harness sets each member to the requested value.
//
// `expect_first` holds the text that must be candidate 0 of the first page
// (the four-state acceptance requires first choice); cases without it keep the
// plain find-and-commit contract. It is a separate column because the first
// candidate text and the committed text are both real engine evidence and may
// legitimately differ for other cases.
//
// `--dump-projection SCHEMA` prints the raw rb_syllable_display_map_json()
// capture (real text/normal/correction per token) used to regenerate the
// committed real-engine projection fixtures; see the --capture-projections
// mode of the same script. Text is the only thing written to stdout in that
// mode.
//
// A missing or malformed cases file, a non-1.17.0 runtime, a schema that does
// not select, an option that does not take effect, a key the engine does not
// consume, and a missing or wrong first candidate/candidate/commit are hard
// failures (exit 2), so an empty or stale fixture can never be reported as a
// passing replay.
//
// Usage: see Tools/BuildRimeIOS/scripts/39-builtin-playback-harness.sh; this
// binary is script-internal.
// ---------------------------------------------------------------------------
#include "rime_bridge.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <utility>
#include <vector>

namespace {

constexpr int kExitUsage = 64;
constexpr int kExitFailure = 2;
constexpr int kCaseColumns = 7;
constexpr int kRecordedCandidates = 20;

struct Options {
  std::string mode = "source";
  std::string shared;
  std::string compiled;
  std::string user;
  std::string cases;
  std::string label = "builtin-playback";
  std::string dump_projection;
  int max_pages = 40;
  bool record = false;
};

struct OptionValue {
  std::string name;
  int value = 0;
};

struct Case {
  std::string source_schema;
  std::string layout;
  std::string schema;
  std::string keys;
  std::string expect;
  std::vector<OptionValue> options;
  std::string expect_first;  // empty -> no first-page assertion
};

[[noreturn]] void fail(const std::string& message) {
  std::fprintf(stderr, "[FAIL] %s\n", message.c_str());
  std::exit(kExitFailure);
}

[[noreturn]] void usage(const char* message) {
  std::fprintf(stderr,
               "[usage] %s\n"
               "  --shared DIR --user DIR [--mode source|prebuilt] [--compiled DIR]\n"
               "  [--cases FILE] [--label NAME] [--record] [--max-pages N]\n"
               "  [--dump-projection SCHEMA_ID]\n",
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

std::vector<std::string> split(const std::string& text, char separator) {
  std::vector<std::string> fields;
  std::string::size_type start = 0;
  while (true) {
    const std::string::size_type at = text.find(separator, start);
    if (at == std::string::npos) {
      fields.push_back(text.substr(start));
      return fields;
    }
    fields.push_back(text.substr(start, at - start));
    start = at + 1;
  }
}

int parse_count(const char* flag, const char* value) {
  char* end = nullptr;
  long parsed = std::strtol(value, &end, 10);
  if (!end || *end != '\0' || parsed < 1 || parsed > 100000) usage(flag);
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
    } else if (flag == "--cases") {
      options.cases = value();
    } else if (flag == "--label") {
      options.label = value();
    } else if (flag == "--dump-projection") {
      options.dump_projection = value();
    } else if (flag == "--max-pages") {
      options.max_pages = parse_count(flag.c_str(), value());
    } else if (flag == "--record") {
      options.record = true;
    } else {
      usage(flag.c_str());
    }
  }
  if (options.mode != "source" && options.mode != "prebuilt") usage("--mode");
  if (options.shared.empty()) usage("--shared");
  if (options.user.empty()) usage("--user");
  if (options.mode == "prebuilt" && options.compiled.empty()) usage("--compiled");
  if (options.dump_projection.empty() && options.cases.empty()) usage("--cases");
  return options;
}

// Everything the engine is about to read is checked up front so an empty or
// half-staged tree fails as a fixture error instead of an engine error.
void preflight(const Options& options) {
  if (!is_dir(options.shared)) {
    fail("fixture shared directory is missing: " + options.shared);
  }
  if (!is_file(join(options.shared, "default.yaml"))) {
    fail("fixture shared directory has no default.yaml: " + options.shared);
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
  }
}

bool valid_option_name(const std::string& name) {
  if (name.empty()) return false;
  for (unsigned char c : name) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_';
    if (!ok) return false;
  }
  return true;
}

bool printable_ascii(const std::string& text) {
  if (text.empty()) return false;
  for (unsigned char c : text) {
    if (c < 0x20 || c > 0x7e) return false;
  }
  return true;
}

Case parse_case(const std::vector<std::string>& fields, long line_number) {
  const std::string where = "cases file line " + std::to_string(line_number);
  if (fields.size() != kCaseColumns) {
    fail(where + ": expected " + std::to_string(kCaseColumns) + " tab-separated columns, got " +
         std::to_string(fields.size()));
  }
  Case c;
  c.source_schema = fields[0];
  c.layout = fields[1];
  c.schema = fields[2];
  const std::string& option_column = fields[3];
  c.keys = fields[4];
  c.expect = fields[5];
  const std::string& first_column = fields[6];
  if (c.source_schema.empty() || c.layout.empty() || c.schema.empty()) {
    fail(where + ": empty schema/layout column");
  }
  if (!printable_ascii(c.keys)) {
    fail(where + ": keys must be non-empty printable ASCII");
  }
  if (c.expect.empty()) {
    fail(where + ": empty expect_text");
  }
  if (first_column != "-") {
    if (first_column.empty()) fail(where + ": empty expect_first column");
    c.expect_first = first_column;
  }
  if (option_column != "-") {
    for (const std::string& entry : split(option_column, ',')) {
      const std::vector<std::string> pair = split(entry, '=');
      if (pair.size() != 2 || !valid_option_name(pair[0]) ||
          (pair[1] != "0" && pair[1] != "1")) {
        fail(where + ": malformed option entry \"" + entry + "\"");
      }
      c.options.push_back(OptionValue{pair[0], pair[1] == "1" ? 1 : 0});
    }
  }
  return c;
}

std::vector<Case> load_cases(const std::string& path) {
  if (!is_file(path)) fail("cases file is missing: " + path);
  std::ifstream stream(path);
  if (!stream) fail("cannot open cases file: " + path);
  std::vector<Case> cases;
  std::string line;
  long line_number = 0;
  while (std::getline(stream, line)) {
    ++line_number;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    const std::vector<std::string> fields = split(line, '\t');
    // Tolerate an explicit header, but never silently skip a malformed row.
    if (line_number == 1 && fields.size() == kCaseColumns && fields[0] == "source_schema") {
      continue;
    }
    cases.push_back(parse_case(fields, line_number));
  }
  if (cases.empty()) fail("cases file has no cases: " + path);
  return cases;
}

rb_engine* create_engine(const Options& options) {
  rb_engine* engine = nullptr;
  if (options.mode == "prebuilt") {
    engine = rb_engine_create_prebuilt(options.shared.c_str(), options.user.c_str(),
                                       "rime.songyan.builtin-playback", "1.0",
                                       options.compiled.c_str());
  } else {
    engine = rb_engine_create(options.shared.c_str(), options.user.c_str(),
                              "rime.songyan.builtin-playback", "1.0");
  }
  if (!engine) {
    fail("rb_engine_create() returned NULL for mode " + options.mode);
  }
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
  return engine;
}

// Replaces control bytes so one fixture value cannot break the line-oriented
// result protocol; UTF-8 text is copied byte for byte.
std::string display_text(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  for (unsigned char c : text) {
    out.push_back(c < 0x20 || c == 0x7f ? ' ' : static_cast<char>(c));
  }
  return out;
}

std::string join_candidates(const rb_snapshot& snapshot, int limit) {
  std::string out;
  for (int i = 0; i < snapshot.num_candidates && i < limit; ++i) {
    if (i) out += "|";
    out += display_text(snapshot.candidates[i].text);
  }
  return out;
}

int dump_projection(const Options& options) {
  rb_engine* engine = create_engine(options);
  const uintptr_t session = rb_session_create(engine);
  if (session == 0) {
    rb_engine_destroy(engine);
    fail("rb_session_create() returned 0");
  }
  if (!rb_select_schema(engine, session, options.dump_projection.c_str())) {
    rb_session_destroy(engine, session);
    rb_engine_destroy(engine);
    fail("rb_select_schema(\"" + options.dump_projection + "\") failed");
  }
  char* json = rb_syllable_display_map_json(session);
  if (!json) {
    rb_session_destroy(engine, session);
    rb_engine_destroy(engine);
    fail("rb_syllable_display_map_json() returned NULL: projection not provable for " +
         options.dump_projection);
  }
  std::printf("%s\n", json);
  rb_syllable_display_map_free(json);
  rb_session_destroy(engine, session);
  rb_engine_destroy(engine);
  return 0;
}

struct ReplayCounters {
  int passed = 0;
  int failed = 0;
  int first_checked = 0;
};

// Replays one case. Returns false with *reason set when the case does not meet
// its expectation; engine-level problems (no session, NULL snapshot) are
// reported the same way so one broken case does not hide the rest.
bool replay_case(rb_engine* engine, uintptr_t session, const Case& c, long index,
                 const Options& options, ReplayCounters* counters, std::string* reason) {
  if (!rb_select_schema(engine, session, c.schema.c_str())) {
    *reason = "rb_select_schema(\"" + c.schema + "\") failed";
    return false;
  }
  if (!rb_clear_composition(engine, session)) {
    *reason = "rb_clear_composition() failed";
    return false;
  }
  for (const OptionValue& option : c.options) {
    if (!rb_set_option(engine, session, option.name.c_str(), option.value)) {
      *reason = "rb_set_option(\"" + option.name + "\") failed";
      return false;
    }
  }
  // A requested ON option that the live schema does not resolve (typo, missing
  // four-state member, stale fixture) must fail closed instead of silently
  // replaying the previous state.
  for (const OptionValue& option : c.options) {
    if (option.value && !rb_get_option(engine, session, option.name.c_str())) {
      *reason = "option \"" + option.name + "\" did not take effect";
      return false;
    }
  }
  for (unsigned char key : c.keys) {
    if (!rb_process_key(engine, session, static_cast<int>(key), 0)) {
      rb_clear_composition(engine, session);
      *reason = "key '" + std::string(1, static_cast<char>(key)) + "' was not consumed by the engine";
      return false;
    }
  }

  rb_snapshot* snapshot = rb_snapshot_get(engine, session);
  if (!snapshot) {
    *reason = "rb_snapshot_get() returned NULL after the keys";
    return false;
  }
  if (options.record) {
    std::printf("RECORD\t%ld\t%s/%s\tkeys=%s\tpreedit=%s\tfirst=%s\tcandidates=%s\n", index,
                display_text(c.source_schema).c_str(), display_text(c.layout).c_str(),
                display_text(c.keys).c_str(), display_text(snapshot->preedit).c_str(),
                snapshot->num_candidates > 0 ? display_text(snapshot->candidates[0].text).c_str() : "",
                join_candidates(*snapshot, kRecordedCandidates).c_str());
  }

  bool failed = false;
  std::string local_reason;
  if (!c.expect_first.empty()) {
    ++counters->first_checked;
    if (snapshot->num_candidates < 1 || c.expect_first != snapshot->candidates[0].text) {
      local_reason = "first candidate is \"" +
                     (snapshot->num_candidates > 0
                          ? display_text(snapshot->candidates[0].text)
                          : std::string("<none>")) +
                     "\", expected \"" + display_text(c.expect_first) + "\"";
      failed = true;
    }
  }

  bool found = false;
  int pages = 0;
  std::string committed;
  while (snapshot) {
    int candidate_index = -1;
    for (int i = 0; i < snapshot->num_candidates; ++i) {
      if (c.expect == snapshot->candidates[i].text) {
        candidate_index = i;
        break;
      }
    }
    if (candidate_index >= 0) {
      found = true;
      const bool selected = rb_select_candidate_on_current_page(
          engine, session, static_cast<size_t>(candidate_index));
      rb_snapshot_free(snapshot);
      snapshot = nullptr;
      if (!selected) {
        if (!failed) local_reason = "rb_select_candidate_on_current_page() failed";
        failed = true;
        break;
      }
      rb_snapshot* committed_snapshot = rb_snapshot_get(engine, session);
      if (!committed_snapshot) {
        if (!failed) local_reason = "rb_snapshot_get() returned NULL after selecting the candidate";
        failed = true;
        break;
      }
      committed = committed_snapshot->commit_text ? committed_snapshot->commit_text : "";
      rb_snapshot_free(committed_snapshot);
      if (committed != c.expect && !failed) {
        local_reason = "committed \"" + display_text(committed) + "\", expected \"" +
                       display_text(c.expect) + "\"";
        failed = true;
      }
      break;
    }
    if (snapshot->is_last_page || pages >= options.max_pages) {
      rb_snapshot_free(snapshot);
      snapshot = nullptr;
      break;
    }
    rb_snapshot_free(snapshot);
    snapshot = nullptr;
    if (!rb_change_page(engine, session, 0)) {
      local_reason = "rb_change_page() failed after " + std::to_string(pages + 1) + " page(s)";
      failed = true;
      break;
    }
    ++pages;
    snapshot = rb_snapshot_get(engine, session);
    if (!snapshot) {
      local_reason = "rb_snapshot_get() returned NULL after paging";
      failed = true;
      break;
    }
  }
  if (!found && !failed) {
    local_reason = "expected candidate \"" + display_text(c.expect) +
                   "\" is not in the menu after " + std::to_string(pages + 1) + " page(s)";
    failed = true;
  }
  if (failed) {
    rb_clear_composition(engine, session);
    *reason = local_reason.empty() ? "replay failed" : local_reason;
    return false;
  }
  if (options.record) {
    std::printf("COMMIT\t%ld\t%s\n", index, display_text(committed).c_str());
  }
  return true;
}

int run_replay(const Options& options) {
  const std::vector<Case> cases = load_cases(options.cases);
  rb_engine* engine = create_engine(options);
  const uintptr_t session = rb_session_create(engine);
  if (session == 0) {
    rb_engine_destroy(engine);
    fail("rb_session_create() returned 0");
  }
  std::fprintf(stderr, "[harness] mode=%s shared=%s user=%s cases=%s cases=%zu label=%s\n",
               options.mode.c_str(), options.shared.c_str(), options.user.c_str(),
               options.cases.c_str(), cases.size(), options.label.c_str());

  ReplayCounters counters;
  for (size_t i = 0; i < cases.size(); ++i) {
    const Case& c = cases[i];
    std::string reason;
    const bool ok = replay_case(engine, session, c, static_cast<long>(i + 1), options,
                                &counters, &reason);
    if (ok) {
      ++counters.passed;
    } else {
      ++counters.failed;
    }
    std::printf("%s\t%zu\t%s/%s\t%s\t%s\t%s\n", ok ? "PASS" : "FAIL", i + 1,
                display_text(c.source_schema).c_str(), display_text(c.layout).c_str(),
                display_text(c.keys).c_str(), display_text(c.expect).c_str(),
                ok ? "committed" : reason.c_str());
  }

  rb_session_destroy(engine, session);
  rb_engine_destroy(engine);

  std::printf("SUMMARY\tlabel=%s\tcases=%zu\tpassed=%d\tfailed=%d\tfirst_checked=%d\n",
              display_text(options.label).c_str(), cases.size(), counters.passed,
              counters.failed, counters.first_checked);
  return counters.failed == 0 ? 0 : kExitFailure;
}

}  // namespace

int main(int argc, char** argv) {
  const Options options = parse_options(argc, argv);
  preflight(options);
  if (!options.dump_projection.empty()) {
    return dump_projection(options);
  }
  return run_replay(options);
}
