// ---------------------------------------------------------------------------
// traditional-playback-main.cc — development-only macOS replay for the
// traditional-Chinese playback fixtures
// (Tests/EngineFixtures/Traditional/playback_cases.json) against a real,
// pinned librime 1.17.0 process reading an already deployed, read-only
// generation from the pinned catalogue build.
//
// The JSON fixture stays the single source of truth. The shell wrapper
// (Tools/BuildRimeIOS/scripts/traditional-playback-harness.sh) parses it with
// the Python standard library, resolves every case's schema to the deployed
// generation whose shipping metadata (store-*/active.json, schema id and
// generation) names it, validates that schema against that generation's
// compiled default.yaml schema list, and writes one headerless TSV per
// generation. This binary therefore reads a headerless TSV: there is no
// hand-written JSON parser here and no fixture expectation is derived from the
// harness.
//
// One case is replayed the way a keyboard front end does it:
//   rb_select_schema -> rb_clear_composition -> rb_process_key per ASCII key
//   (space included) -> rb_snapshot_get -> assert preedit / candidate rank /
//   committed text; when the case names a candidate to select, find it on the
//   current page (paging while missing), rb_select_candidate_on_current_page,
//   then compare the committed text.
//
// The expectations follow the built-in fixture contract and add optional
// evidence columns the traditional acceptance needs:
//   expect_first           candidate 0 is exactly this text
//   expect_top3/top5       this text appears within the first 3/5 candidates
//   commit_action          "select" (default when expect_text is present: find
//                          that candidate, tap it, compare the commit) or
//                          "confirm" (the front end's space/return confirm:
//                          librime commits the highlighted candidate). It is
//                          explicit because Bopomofo's fluency editor only
//                          confirms on a tap and commits on the confirm action.
//   expect_preedit         the composition preedit is exactly this text
//                          (the Bopomofo case pins the Zhuyin symbols, so an
//                          ASCII key-code preedit can never pass)
// A case without expect_text must carry at least one of the other columns.
// Everything printed is machine parsable (RECORD/PASS/FAIL/SUMMARY); every
// non-met expectation, a schema that does not select, a key the engine does
// not consume and a missing engine generation are hard failures (exit 2), so
// a stale fixture can never be reported as a passing replay.
//
// Usage: see Tools/BuildRimeIOS/scripts/traditional-playback-harness.sh; this
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
constexpr int kCaseColumns = 9;
constexpr int kRecordedCandidates = 12;

struct Options {
  std::string shared;
  std::string compiled;
  std::string user;
  std::string cases;
  std::string label = "traditional-playback";
  int max_pages = 40;
  bool record = false;
};

struct Case {
  std::string schema;
  std::string layout;
  std::string keys;
  std::string expect_text;
  std::string expect_first;
  std::string expect_top3;
  std::string expect_top5;
  std::string expect_preedit;
  std::string commit_action;  // "" (no commit), "select" or "confirm"
};

[[noreturn]] void fail(const std::string& message) {
  std::fprintf(stderr, "[FAIL] %s\n", message.c_str());
  std::exit(kExitFailure);
}

[[noreturn]] void usage(const char* message) {
  std::fprintf(stderr,
               "[usage] %s\n"
               "  --shared DIR --compiled DIR --user DIR --cases FILE\n"
               "  [--label NAME] [--record] [--max-pages N]\n",
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

int parse_channel_count(const char* flag, const char* value) {
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
    if (flag == "--shared") {
      options.shared = value();
    } else if (flag == "--compiled") {
      options.compiled = value();
    } else if (flag == "--user") {
      options.user = value();
    } else if (flag == "--cases") {
      options.cases = value();
    } else if (flag == "--label") {
      options.label = value();
    } else if (flag == "--max-pages") {
      options.max_pages = parse_channel_count(flag.c_str(), value());
    } else if (flag == "--record") {
      options.record = true;
    } else {
      usage(flag.c_str());
    }
  }
  if (options.shared.empty()) usage("--shared");
  if (options.compiled.empty()) usage("--compiled");
  if (options.user.empty()) usage("--user");
  if (options.cases.empty()) usage("--cases");
  return options;
}

// Everything the engine is about to read is checked up front so an empty or
// half-deployed generation fails as a fixture error instead of an engine error.
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
  if (!is_dir(options.compiled)) {
    fail("fixture compiled directory is missing: " + options.compiled);
  }
  if (!is_file(join(options.compiled, "default.yaml"))) {
    fail("fixture compiled directory has no default.yaml: " + options.compiled);
  }
}

bool printable_ascii(const std::string& text) {
  if (text.empty()) return false;
  for (unsigned char c : text) {
    if (c < 0x20 || c > 0x7e) return false;
  }
  return true;
}

std::string column(const std::vector<std::string>& fields, size_t index) {
  return fields[index] == "-" ? std::string() : fields[index];
}

Case parse_case(const std::vector<std::string>& fields, long line_number) {
  const std::string where = "cases file line " + std::to_string(line_number);
  if (fields.size() != kCaseColumns) {
    fail(where + ": expected " + std::to_string(kCaseColumns) +
         " tab-separated columns, got " + std::to_string(fields.size()));
  }
  Case c;
  c.schema = fields[0];
  c.layout = fields[1];
  c.keys = fields[2];
  c.expect_text = column(fields, 3);
  c.expect_first = column(fields, 4);
  c.expect_top3 = column(fields, 5);
  c.expect_top5 = column(fields, 6);
  c.expect_preedit = column(fields, 7);
  c.commit_action = column(fields, 8);
  if (c.schema.empty() || c.layout.empty()) {
    fail(where + ": empty schema/layout column");
  }
  if (!printable_ascii(c.keys)) {
    fail(where + ": keys must be non-empty printable ASCII");
  }
  if (c.expect_text.empty() && c.expect_first.empty() && c.expect_top3.empty() &&
      c.expect_top5.empty() && c.expect_preedit.empty()) {
    fail(where + ": case carries no expectation");
  }
  if (c.commit_action != "" && c.commit_action != "select" && c.commit_action != "confirm") {
    fail(where + ": commit_action must be select or confirm");
  }
  if (!c.commit_action.empty() && c.expect_text.empty()) {
    fail(where + ": commit_action needs expect_text");
  }
  if (c.commit_action.empty() && !c.expect_text.empty()) c.commit_action = "select";
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
    if (line_number == 1 && fields.size() == kCaseColumns && fields[0] == "schema") {
      continue;
    }
    cases.push_back(parse_case(fields, line_number));
  }
  if (cases.empty()) fail("cases file has no cases: " + path);
  return cases;
}

rb_engine* create_engine(const Options& options) {
  rb_engine* engine = rb_engine_create_prebuilt(options.shared.c_str(), options.user.c_str(),
                                                "rime.songyan.traditional-playback", "1.0",
                                                options.compiled.c_str());
  if (!engine) {
    fail("rb_engine_create_prebuilt() returned NULL");
  }
  if (!rb_engine_ready(engine)) {
    const std::string error = rb_engine_last_error(engine);
    rb_engine_destroy(engine);
    fail("engine not ready: " + error);
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

bool candidate_at(const rb_snapshot& snapshot, int index, const std::string& text) {
  return index < snapshot.num_candidates && text == snapshot.candidates[index].text;
}

bool candidate_within(const rb_snapshot& snapshot, int rank, const std::string& text) {
  for (int i = 0; i < snapshot.num_candidates && i < rank; ++i) {
    if (text == snapshot.candidates[i].text) return true;
  }
  return false;
}

std::string candidates_reason(const rb_snapshot& snapshot) {
  std::string out = "candidates [" + join_candidates(snapshot, kRecordedCandidates) + "]";
  if (snapshot.num_candidates > kRecordedCandidates) out += "...";
  return out;
}

struct ReplayCounters {
  int passed = 0;
  int failed = 0;
  int first_checked = 0;
  int top3_checked = 0;
  int top5_checked = 0;
  int preedit_checked = 0;
  int commit_checked = 0;
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
    std::printf(
        "RECORD\t%ld\t%s/%s\tkeys=%s\tcomposing=%d\tpreedit=%s\ttop=%s\tcommit=%s\n", index,
        display_text(c.schema).c_str(), display_text(c.layout).c_str(),
        display_text(c.keys).c_str(), snapshot->is_composing,
        display_text(snapshot->preedit).c_str(),
        join_candidates(*snapshot, kRecordedCandidates).c_str(),
        display_text(snapshot->commit_text).c_str());
  }

  bool failed = false;
  std::string local_reason;
  const std::string commit = snapshot->commit_text ? snapshot->commit_text : "";
  if (!c.expect_preedit.empty()) {
    ++counters->preedit_checked;
    if (c.expect_preedit != snapshot->preedit) {
      local_reason = "preedit is \"" + display_text(snapshot->preedit) + "\", expected \"" +
                     display_text(c.expect_preedit) + "\"";
      failed = true;
    }
  }
  if (!c.expect_first.empty()) {
    ++counters->first_checked;
    if (!candidate_at(*snapshot, 0, c.expect_first)) {
      local_reason = "first candidate is \"" +
                     (snapshot->num_candidates > 0 ? display_text(snapshot->candidates[0].text)
                                                   : std::string("<none>")) +
                     "\", expected \"" + display_text(c.expect_first) + "\" (" +
                     candidates_reason(*snapshot) + ")";
      failed = true;
    }
  }
  if (!c.expect_top3.empty()) {
    ++counters->top3_checked;
    if (!candidate_within(*snapshot, 3, c.expect_top3)) {
      local_reason = "\"" + display_text(c.expect_top3) + "\" is not within the first 3 (" +
                     candidates_reason(*snapshot) + ")";
      failed = true;
    }
  }
  if (!c.expect_top5.empty()) {
    ++counters->top5_checked;
    if (!candidate_within(*snapshot, 5, c.expect_top5)) {
      local_reason = "\"" + display_text(c.expect_top5) + "\" is not within the first 5 (" +
                     candidates_reason(*snapshot) + ")";
      failed = true;
    }
  }

  if (!failed && c.commit_action == "confirm") {
    // This case requests an explicit native composition commit. A schema's
    // Space binding can instead select a tone or confirm only one segment.
    ++counters->commit_checked;
    const bool confirmed = rb_commit_composition(engine, session);
    rb_snapshot_free(snapshot);
    snapshot = nullptr;
    if (!confirmed) {
      rb_clear_composition(engine, session);
      *reason = "rb_commit_composition() failed";
      return false;
    }
    rb_snapshot* confirmed_snapshot = rb_snapshot_get(engine, session);
    if (!confirmed_snapshot) {
      rb_clear_composition(engine, session);
      *reason = "rb_snapshot_get() returned NULL after the confirm action";
      return false;
    }
    const std::string confirmed_text =
        confirmed_snapshot->commit_text ? confirmed_snapshot->commit_text : "";
    if (options.record) {
      std::printf("CONFIRMED\t%ld\tcomposing=%d\tpreedit=%s\tcommit=%s\n", index,
                  confirmed_snapshot->is_composing,
                  display_text(confirmed_snapshot->preedit).c_str(),
                  display_text(confirmed_text).c_str());
    }
    rb_snapshot_free(confirmed_snapshot);
    if (confirmed_text != c.expect_text) {
      rb_clear_composition(engine, session);
      *reason = "confirm action committed \"" + display_text(confirmed_text) + "\", expected \"" +
                display_text(c.expect_text) + "\"";
      return false;
    }
    return true;
  }
  if (!failed && !c.expect_text.empty()) {
    ++counters->commit_checked;
    if (!commit.empty()) {
      // The keys already committed, so a candidate selection cannot be the
      // evidence this case claims; fail closed instead of ignoring it.
      rb_snapshot_free(snapshot);
      rb_clear_composition(engine, session);
      *reason = "keys committed \"" + display_text(commit) +
                "\" before the expected candidate could be selected";
      return false;
    }
    bool found = false;
    int pages = 0;
    std::string committed;
    while (snapshot) {
      int candidate_index = -1;
      for (int i = 0; i < snapshot->num_candidates; ++i) {
        if (c.expect_text == snapshot->candidates[i].text) {
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
          local_reason = "rb_select_candidate_on_current_page() failed";
          failed = true;
          break;
        }
        rb_snapshot* committed_snapshot = rb_snapshot_get(engine, session);
        if (!committed_snapshot) {
          local_reason = "rb_snapshot_get() returned NULL after selecting the candidate";
          failed = true;
          break;
        }
        if (options.record) {
          std::printf("SELECTED\t%ld\tcomposing=%d\tpreedit=%s\tcommit=%s\n", index,
                      committed_snapshot->is_composing,
                      display_text(committed_snapshot->preedit).c_str(),
                      display_text(committed_snapshot->commit_text).c_str());
        }
        committed = committed_snapshot->commit_text ? committed_snapshot->commit_text : "";
        rb_snapshot_free(committed_snapshot);
        if (committed != c.expect_text) {
          local_reason = "committed \"" + display_text(committed) + "\", expected \"" +
                         display_text(c.expect_text) + "\"";
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
      local_reason = "expected candidate \"" + display_text(c.expect_text) +
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

  if (snapshot) rb_snapshot_free(snapshot);
  if (failed) {
    rb_clear_composition(engine, session);
    *reason = local_reason.empty() ? "replay failed" : local_reason;
    return false;
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
  std::fprintf(stderr,
               "[harness] shared=%s compiled=%s user=%s cases=%s count=%zu label=%s\n",
               options.shared.c_str(), options.compiled.c_str(), options.user.c_str(),
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
                display_text(c.schema).c_str(), display_text(c.layout).c_str(),
                display_text(c.keys).c_str(),
                display_text(c.expect_text).c_str(),
                ok ? "as expected" : reason.c_str());
  }

  rb_session_destroy(engine, session);
  rb_engine_destroy(engine);

  std::printf(
      "SUMMARY\tlabel=%s\tcases=%zu\tpassed=%d\tfailed=%d\tfirst=%d\ttop3=%d\ttop5=%d\t"
      "preedit=%d\tcommit=%d\n",
      display_text(options.label).c_str(), cases.size(), counters.passed, counters.failed,
      counters.first_checked, counters.top3_checked, counters.top5_checked,
      counters.preedit_checked, counters.commit_checked);
  return counters.failed == 0 ? 0 : kExitFailure;
}

}  // namespace

int main(int argc, char** argv) {
  const Options options = parse_options(argc, argv);
  preflight(options);
  return run_replay(options);
}
