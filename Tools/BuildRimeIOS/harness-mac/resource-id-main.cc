// Resource ids from a schema must not reach files outside the engine's data folders.
// Deploys a schema whose user dictionary is an absolute path and whose dictionary pack
// and secondary translator name "../x", types and commits a word, then checks that
// nothing was created or read outside the user folder while the schema keeps working.
#include <rime_api.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

static void check(bool value, const std::string& label) {
  if (!value) throw std::runtime_error(label);
  std::cout << "PASS " << label << std::endl;
}

static void write_file(const fs::path& file, const std::string& text) {
  std::ofstream output(file, std::ios::binary);
  output << text;
  output.close();
  if (output.fail()) throw std::runtime_error("cannot write fixture " + file.string());
}

static std::vector<std::string> candidates(RimeApi* api, RimeSessionId session) {
  std::vector<std::string> texts;
  RIME_STRUCT(RimeContext, context);
  if (api->get_context(session, &context)) {
    for (int i = 0; i < context.menu.num_candidates; ++i) texts.push_back(context.menu.candidates[i].text);
    api->free_context(&context);
  }
  return texts;
}

static std::vector<std::string> tree(const fs::path& dir) {
  std::vector<std::string> entries;
  for (const auto& entry : fs::recursive_directory_iterator(dir)) entries.push_back(entry.path().string());
  return entries;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: resource-id-harness <fresh-root>" << std::endl;
    return 2;
  }
  RimeApi* api = rime_get_api();
  bool initialized = false;
  std::string leak_template = (fs::temp_directory_path() / "songyan-leak.XXXXXX").string();
  fs::path leak;
  int status = 0;
  try {
    const fs::path root = fs::absolute(argv[1]);
    check(fs::create_directory(root), "fresh harness root created");
    const fs::path shared = root / "shared", user = root / "user", logs = root / "logs";
    for (const auto& dir : {shared, user, logs}) fs::create_directory(dir);
    check(mkdtemp(leak_template.data()) != nullptr, "empty absolute target folder created");
    leak = leak_template;

    // root/x.dict.yaml is what "../x" names from both the user and the shared folder.
    write_file(root / "x.dict.yaml",
               "---\nname: \"../x\"\nversion: \"1\"\nsort: original\n...\n外泄\tnihao\n");
    write_file(shared / "probe.dict.yaml",
               "---\nname: probe\nversion: \"1\"\nsort: original\n...\n你好\tnihao\n");
    write_file(shared / "default.yaml", "schema_list:\n  - schema: probe\n");
    write_file(shared / "probe.schema.yaml",
               "schema:\n  schema_id: probe\n  name: probe\n  version: \"1\"\n"
               "engine:\n  processors: [speller, selector, express_editor]\n"
               "  segmentors: [abc_segmentor]\n"
               "  translators: [table_translator, table_translator@secondary]\n"
               "speller:\n  alphabet: abcdefghijklmnopqrstuvwxyz\n"
               "translator:\n  dictionary: probe\n  packs: [../x]\n"
               "  enable_user_dict: true\n  user_dict: " + (leak / "leak").string() + "\n"
               "secondary:\n  dictionary: ../x\n");

    const char* modules[] = {"default", "levers", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    const std::string shared_s = shared.string(), user_s = user.string(), logs_s = logs.string();
    traits.shared_data_dir = shared_s.c_str();
    traits.user_data_dir = user_s.c_str();
    traits.log_dir = logs_s.c_str();
    traits.min_log_level = 0;
    traits.app_name = "rime.resource-id-harness";
    traits.modules = modules;
    api->setup(&traits);
    api->initialize(&traits);
    initialized = true;
    check(api->deploy() != 0, "deployment succeeds with refused resource ids");
    check(fs::exists(user / "build/probe.schema.yaml") && fs::exists(user / "build/probe.table.bin"),
          "schema and its own dictionary are compiled");

    RimeSessionId session = api->create_session();
    check(session != 0, "session created");
    check(api->select_schema(session, "probe") != 0, "probe schema selected");
    check(api->simulate_key_sequence(session, "nihao") != 0, "typed nihao");
    const auto texts = candidates(api, session);
    check(!texts.empty() && texts.front() == "你好", "the schema's own dictionary still answers");
    for (const auto& text : texts) check(text != "外泄", "no candidate from the dictionary outside the data folders");
    check(api->select_candidate_on_current_page(session, 0) != 0, "candidate committed");
    RIME_STRUCT(RimeCommit, commit);
    check(api->get_commit(session, &commit) != 0 && std::string(commit.text) == "你好", "commit text is 你好");
    api->free_commit(&commit);
    api->destroy_session(session);
    api->finalize();
    initialized = false;

    check(fs::is_empty(leak), "nothing written to the absolute user_dict folder");
    std::vector<std::string> outside;
    for (const auto& entry : fs::directory_iterator(root)) {
      const auto name = entry.path().filename().string();
      if (name != "shared" && name != "user" && name != "logs" && name != "x.dict.yaml")
        outside.push_back(entry.path().string());
    }
    for (const auto& entry : tree(root))
      if (entry.find("x.table.bin") != std::string::npos || entry.find("x.prism.bin") != std::string::npos ||
          entry.find("refused-resource-id") != std::string::npos || entry.find("leak") != std::string::npos)
        outside.push_back(entry);
    for (const auto& entry : outside) std::cerr << "unexpected: " << entry << std::endl;
    check(outside.empty(), "no file created from the refused ids");
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << std::endl;
    status = 1;
  }
  if (initialized) api->finalize();
  if (!leak.empty()) {
    std::error_code ignored;
    fs::remove_all(leak, ignored);
  }
  return status;
}
