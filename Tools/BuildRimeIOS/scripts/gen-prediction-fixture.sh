#!/usr/bin/env bash
# Rebuild the tiny prediction model and verify native post-commit behavior on macOS.
# Usage: Tools/BuildRimeIOS/scripts/gen-prediction-fixture.sh [--check]
# --check verifies the existing model without replacing it. Requires the macOS
# engine prefix and pinned predictor checkout from 09-fetch-plugins.sh.
# PREDICT_SRC and FIXTURE_DIR override their standard repository locations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../CI/scripts/lib/xcode.sh"
require_xcode
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/harness.sh"

PREDICT_SRC="${PREDICT_SRC:-${PROJECT_ROOT}/.local/ios-engine/plugin-sources/src/librime-predict}"
FIXTURE_DIR="${FIXTURE_DIR:-${PROJECT_ROOT}/Tests/EngineFixtures/Prediction}"
GENERATE=1
case "$*" in
  "") ;;
  --check) GENERATE=0 ;;
  *) printf 'usage: %s [--check]\n' "${0##*/}" >&2; exit 2 ;;
esac

HARNESS_OUTPUT_ROOT="${PROJECT_ROOT}/.scratch/prediction-fixture/runs"
RUN_DIR="$(new_harness_dir prediction-fixture)"
GEN_INCLUDE="$(rime_generated_include)"
prepare_native_bridge

PREDICT_INCLUDE=(-I"${PREDICT_SRC}/src")

if [[ "${GENERATE}" == 1 ]]; then
  say "compile librime-predict db writer (build_predict + predict_db)"
  "${MAC_CXX}" "${MAC_CXX_FLAGS[@]}" "${PREDICT_INCLUDE[@]}" \
    "${PREDICT_SRC}/src/predict_db.cc" -o "${RUN_DIR}/predict_db.o"
  "${MAC_CXX}" "${MAC_CXX_FLAGS[@]}" "${PREDICT_INCLUDE[@]}" \
    "${PREDICT_SRC}/tools/build_predict.cc" -o "${RUN_DIR}/build_predict.o"
  "${MAC_CXX}" -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
    "${RUN_DIR}/predict_db.o" "${RUN_DIR}/build_predict.o" \
    "${MAC_LINK_FLAGS[@]}" -o "${RUN_DIR}/build_predict"

  say "generate predict.db from row: 你 好 100"
  printf '你 好 100\n' | "${RUN_DIR}/build_predict" "${RUN_DIR}/predict.db"
  cp "${RUN_DIR}/predict.db" "${FIXTURE_DIR}/predict.db"
  say "wrote ${FIXTURE_DIR}/predict.db"
else
  say "keeping existing ${FIXTURE_DIR}/predict.db (--check)"
fi

say "compile librime-predict module sources + host probe"
MODULE_OBJECTS=()
for unit in predict_db predict_engine predict_translator predictor predict_module; do
  "${MAC_CXX}" "${MAC_CXX_FLAGS[@]}" "${PREDICT_INCLUDE[@]}" \
    "${PREDICT_SRC}/src/${unit}.cc" -o "${RUN_DIR}/${unit}.o"
  MODULE_OBJECTS+=("${RUN_DIR}/${unit}.o")
done

cat > "${RUN_DIR}/prediction_probe_main.cc" <<'PROBE_EOF'
// Host probe for the post-commit prediction fixture. Reads state only through
// rime_api.h (get_input / get_status / get_context / get_commit) so the
// assertions describe what a keyboard backend actually observes.
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <rime_api.h>

namespace {

RimeApi* g_api = nullptr;
int g_deploy_state = 0;  // 0 none, 1 start, 2 success, 3 failure
int g_failures = 0;

void OnMessage(void*, RimeSessionId, const char* type, const char* value) {
  if (std::strcmp(type, "deploy") != 0)
    return;
  if (std::strcmp(value, "start") == 0)
    g_deploy_state = 1;
  else if (std::strcmp(value, "success") == 0)
    g_deploy_state = 2;
  else if (std::strcmp(value, "failure") == 0)
    g_deploy_state = 3;
}

void Check(bool ok, const std::string& what) {
  std::printf("%s  %s\n", ok ? "PASS" : "FAIL", what.c_str());
  if (!ok)
    ++g_failures;
}

struct Snapshot {
  int is_composing = 0;
  int is_ascii_mode = 0;
  std::string schema_id;
  std::string input;
  std::string preedit;
  std::vector<std::string> candidates;

  bool HasCandidate(const std::string& text) const {
    for (const auto& candidate : candidates) {
      if (candidate == text)
        return true;
    }
    return false;
  }
};

std::string Join(const std::vector<std::string>& items) {
  std::string joined;
  for (size_t i = 0; i < items.size(); ++i) {
    if (i)
      joined += ",";
    joined += "[" + items[i] + "]";
  }
  return joined;
}

void Describe(const char* stage, const Snapshot& snapshot) {
  std::printf("state %-13s input=[%s] composing=%d preedit=[%s] candidates=%s\n",
              stage, snapshot.input.c_str(), snapshot.is_composing,
              snapshot.preedit.c_str(), Join(snapshot.candidates).c_str());
}

bool ReadSnapshot(RimeSessionId session, Snapshot* out) {
  RIME_STRUCT(RimeStatus, status);
  if (!g_api->get_status(session, &status)) {
    Check(false, "get_status answered");
    return false;
  }
  out->is_composing = status.is_composing;
  out->is_ascii_mode = status.is_ascii_mode;
  if (status.schema_id)
    out->schema_id = status.schema_id;
  g_api->free_status(&status);

  const char* input = g_api->get_input(session);
  out->input = input ? input : "";

  RIME_STRUCT(RimeContext, context);
  if (!g_api->get_context(session, &context)) {
    Check(false, "get_context answered");
    return false;
  }
  out->preedit =
      context.composition.preedit ? context.composition.preedit : "";
  for (int i = 0; i < context.menu.num_candidates; ++i) {
    const char* text = context.menu.candidates[i].text;
    out->candidates.push_back(text ? text : "");
  }
  g_api->free_context(&context);
  return true;
}

std::string TakeCommit(RimeSessionId session) {
  RIME_STRUCT(RimeCommit, commit);
  std::string text;
  if (g_api->get_commit(session, &commit)) {
    text = commit.text ? commit.text : "";
    g_api->free_commit(&commit);
  }
  return text;
}

int Run(const char* shared_dir, const char* user_dir) {
  g_api = rime_get_api();
  if (!g_api) {
    std::fprintf(stderr, "FAIL  rime_get_api() returned NULL\n");
    return 1;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared_dir;
  traits.user_data_dir = user_dir;
  traits.distribution_name = "songyan-prediction-fixture";
  traits.distribution_code_name = "songyan-prediction-fixture";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.songyan.prediction.probe";
  traits.min_log_level = 2;  // ERROR only; the probe output is the evidence.
  // Keep every deployment artifact (compiled dicts, userdb, prebuilt data)
  // under the throwaway user dir: the shared fixture directory is canonical
  // test data and must stay read-only.
  std::string prebuilt_dir = std::string(user_dir) + "/prebuilt";
  std::string staging_dir = std::string(user_dir) + "/build";
  traits.prebuilt_data_dir = prebuilt_dir.c_str();
  traits.staging_dir = staging_dir.c_str();
  // "default" is librime's core/dict/gears group, "predict" is the module this
  // probe links from librime-predict's own sources.
  static const char* kModules[] = {"default", "predict", nullptr};
  traits.modules = kModules;

  g_api->setup(&traits);
  g_api->set_notification_handler(&OnMessage, nullptr);
  g_api->initialize(&traits);
  g_deploy_state = 0;
  if (!g_api->start_maintenance(True)) {
    Check(false, "start_maintenance(full_check) accepted");
    g_api->finalize();
    return 1;
  }
  g_api->join_maintenance_thread();
  Check(g_deploy_state == 2, "native deployment finished successfully");

  RimeSessionId session = g_api->create_session();
  if (!session) {
    Check(false, "create session");
    g_api->finalize();
    return 1;
  }

  Check(g_api->select_schema(session, "prediction_probe"),
        "select schema prediction_probe");
  char current[128] = {0};
  Check(g_api->get_current_schema(session, current, sizeof(current)) &&
            std::strcmp(current, "prediction_probe") == 0,
        "engine reports schema prediction_probe");

  Snapshot idle;
  if (ReadSnapshot(session, &idle)) {
    Describe("idle", idle);
    Check(idle.is_composing == 0, "idle: not composing");
    Check(idle.is_ascii_mode == 0,
          "idle: ascii_mode switch resets to Chinese mode");
  }

  Check(g_api->simulate_key_sequence(session, "ni"), "type ni");
  Snapshot typed;
  if (ReadSnapshot(session, &typed)) {
    Describe("after ni", typed);
    Check(typed.input == "ni", "ni: raw input is ni");
    Check(typed.is_composing == 1, "ni: native is_composing true");
    Check(typed.HasCandidate("你"), "ni: candidate 你 present");
    Check(!typed.candidates.empty() && typed.candidates[0] == "你",
          "ni: 你 is the first candidate");
  }

  Check(g_api->process_key(session, '1', 0), "press 1 selects the first candidate");
  const std::string committed = TakeCommit(session);
  Check(committed == "你", "selecting 你 commits 你 as native commit text");

  Snapshot predicted;
  if (ReadSnapshot(session, &predicted)) {
    Describe("after commit", predicted);
    Check(predicted.input.empty(), "after commit: raw input empty");
    Check(predicted.is_composing == 1,
          "after commit: native is_composing true (zero-length prediction segment)");
    Check(predicted.preedit.empty(), "after commit: preedit empty");
    Check(predicted.candidates.size() == 1 && predicted.candidates[0] == "好",
          "after commit: only prediction candidate is 好");
  }

  Check(g_api->process_key(session, 0xFF1B /* XK_Escape */, 0), "press Esc");
  Snapshot dismissed;
  if (ReadSnapshot(session, &dismissed)) {
    Describe("after Esc", dismissed);
    Check(dismissed.is_composing == 0,
          "after Esc: native is_composing false");
    Check(dismissed.input.empty(), "after Esc: raw input still empty");
    Check(dismissed.candidates.empty(), "after Esc: no candidates left");
    Check(TakeCommit(session).empty(), "after Esc: nothing committed");
  }

  // Dedicated cancel path: clear_composition() is what the backends call to
  // discard input. Record what it actually does to the post-commit prediction;
  // librime-predict may re-predict it from commit history.
  Check(g_api->simulate_key_sequence(session, "ni"), "discard: type ni again");
  Snapshot retyped;
  if (ReadSnapshot(session, &retyped)) {
    Describe("ni again", retyped);
    Check(retyped.input == "ni", "discard: raw input is ni again");
    Check(retyped.HasCandidate("你"), "discard: candidate 你 present");
  }

  Check(g_api->process_key(session, '1', 0), "discard: press 1 selects 你");
  Check(TakeCommit(session) == "你", "discard: selecting 你 commits 你");
  Snapshot repredicted;
  if (ReadSnapshot(session, &repredicted)) {
    Describe("prediction again", repredicted);
    Check(repredicted.input.empty() && repredicted.is_composing == 1 &&
              repredicted.HasCandidate("好"),
          "discard: prediction 好 appears before clearing");
  }

  g_api->clear_composition(session);
  Snapshot cancelled;
  if (ReadSnapshot(session, &cancelled)) {
    Describe("after clear", cancelled);
    Check(cancelled.input.empty(),
          "discard: raw input empty after clear_composition");
    // Context::Clear() fires update_notifier; Predictor::OnContextUpdate then
    // re-predicts from commit_history (last_action is Select, not Delete), so a
    // bare clear_composition keeps a live prediction segment. The backend must
    // dismiss with the schema's Esc path for prediction; clear_composition is
    // only a fallback for schemas that do not create one.
    Check(cancelled.is_composing == 1 && cancelled.HasCandidate("好"),
          "discard: clear_composition alone keeps the re-created prediction");
    Check(TakeCommit(session).empty(),
          "discard: clear_composition commits nothing");
  }

  // librime-predict re-predicts on any context update with an empty composition
  // unless its own delete flag is set, and that flag only comes from a key
  // event (Esc/Backspace) it processes. Record that Esc is the route that
  // actually dismisses the (re-created) prediction segment.
  Check(g_api->process_key(session, 0xFF1B /* XK_Escape */, 0),
        "discard: press Esc after clear_composition");
  Snapshot recovered;
  if (ReadSnapshot(session, &recovered)) {
    Describe("Esc after clear", recovered);
    Check(recovered.is_composing == 0 && recovered.candidates.empty(),
          "discard: Esc dismisses the re-predicted segment");
  }

  g_api->clear_composition(session);
  Snapshot clearedAfterDismiss;
  if (ReadSnapshot(session, &clearedAfterDismiss)) {
    Check(!clearedAfterDismiss.is_composing && clearedAfterDismiss.candidates.empty() &&
              TakeCommit(session).empty(),
          "host clear after dismissal keeps predictions closed without committing");
  }

  std::printf("RESULT %s failures=%d\n",
              g_failures == 0 ? "PASS" : "FAIL", g_failures);
  g_api->destroy_session(session);
  g_api->finalize();
  return g_failures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr,
                 "usage: prediction-probe SHARED_DATA_DIR USER_DATA_DIR\n");
    return 2;
  }
  return Run(argv[1], argv[2]);
}
PROBE_EOF

"${MAC_CXX}" "${MAC_CXX_FLAGS[@]}" "${RUN_DIR}/prediction_probe_main.cc" \
  -o "${RUN_DIR}/prediction_probe_main.o"
"${MAC_CXX}" -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  "${RUN_DIR}/prediction_probe_main.o" "${MODULE_OBJECTS[@]}" \
  "${MAC_LINK_FLAGS[@]}" -o "${RUN_DIR}/prediction-probe"

say "run host probe against the fixture in an isolated user dir"
# Deployment caches (build/, userdb, prebuilt data) live here and only here.
PROBE_USER_DIR="${RUN_DIR}/probe-user"
mkdir -p "${PROBE_USER_DIR}"
"${RUN_DIR}/prediction-probe" "${FIXTURE_DIR}" "${PROBE_USER_DIR}"

say "prediction fixture PASS; run dir ${RUN_DIR}"
