// ---------------------------------------------------------------------------
// opencc-main.c — macOS proof for the standalone OpenCC conversion ABI.
//
// Runs the REAL shipped configs and .ocd2 dictionaries
// (Resources/EngineResources/opencc) through Tools/BuildRimeIOS/src/rime_opencc.cc,
// linked against the pinned macOS OpenCC but deliberately NOT against librime: a
// conversion has to work with no engine, and linking no librime archive is what
// proves this path cannot reach librime's process-global service/registry/session
// state. The Swift adapter half of the same contract is proven by
// opencc-adapter-main.swift, built by 44-opencc-harness.sh.
//
// Usage: opencc-main <config-dir> <writable-scratch-dir>
// ---------------------------------------------------------------------------
#include "rime_opencc.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void fail(const char* name, const char* detail) {
  fprintf(stderr, "FAIL: %s%s%s\n", name, detail ? " - " : "", detail ? detail : "");
  ++failures;
}

static void pass(const char* name) { printf("PASS: %s\n", name); }

static void check(int condition, const char* name) {
  if (condition) {
    pass(name);
  } else {
    fail(name, NULL);
  }
}

static char* join_path(const char* directory, const char* name) {
  size_t size = strlen(directory) + strlen(name) + 2;
  char* path = (char*)malloc(size);
  if (!path) return NULL;
  snprintf(path, size, "%s/%s", directory, name);
  return path;
}

static int write_text_file(const char* path, const char* text) {
  FILE* file = fopen(path, "wb");
  if (!file) return 0;
  size_t length = strlen(text);
  int written = fwrite(text, 1, length, file) == length;
  int closed = fclose(file) == 0;
  return written && closed;
}

// Converts through the real shipped config and compares the exact UTF-8 bytes.
static void expect_conversion(const char* config_dir, const char* config_name,
                              const char* input, const char* expected,
                              const char* name) {
  char* config = join_path(config_dir, config_name);
  if (!config) {
    fail(name, "cannot build the config path");
    return;
  }
  char* output = NULL;
  char* error = NULL;
  int status = rb_opencc_convert(config, input, strlen(input), &output, NULL, &error);
  if (status != RB_OPENCC_OK) {
    fail(name, error ? error : "status is not OK and no diagnostic was set");
  } else if (!output) {
    fail(name, "status is OK but no output was set");
  } else if (error) {
    fail(name, "status is OK but a diagnostic was also set");
  } else if (strcmp(output, expected) != 0) {
    fail(name, "converted text does not match the expected bytes");
  } else {
    pass(name);
  }
  rb_opencc_free(output);
  rb_opencc_free(error);
  free(config);
}

// Asserts a refusal: no output, a non-empty diagnostic, and the exact status.
static void expect_status(const char* config, const char* input, size_t input_length,
                          int expected_status, const char* name) {
  char* output = NULL;
  char* error = NULL;
  int status = rb_opencc_convert(config, input, input_length, &output, NULL, &error);
  if (status != expected_status) {
    fail(name, "status does not match the expected rejection");
  } else if (output) {
    fail(name, "a refused call still produced output");
  } else if (!error || error[0] == '\0') {
    fail(name, "a refused call produced no diagnostic");
  } else {
    pass(name);
  }
  rb_opencc_free(output);
  rb_opencc_free(error);
}

typedef struct {
  const char* config;
  int iterations;
  int failures;
} convert_worker;

static void* run_convert_worker(void* raw) {
  convert_worker* worker = (convert_worker*)raw;
  for (int iteration = 0; iteration < worker->iterations; ++iteration) {
    char* output = NULL;
    char* error = NULL;
    int status = rb_opencc_convert(worker->config, "软件信息", strlen("软件信息"),
                                   &output, NULL, &error);
    if (status != RB_OPENCC_OK || !output || strcmp(output, "軟體資訊") != 0) {
      ++worker->failures;
    }
    rb_opencc_free(output);
    rb_opencc_free(error);
  }
  return NULL;
}

static void check_concurrent_conversions(const char* config) {
  enum { kThreads = 4, kIterations = 3 };
  pthread_t threads[kThreads];
  convert_worker workers[kThreads];
  int created = 0;
  for (int index = 0; index < kThreads; ++index) {
    workers[index].config = config;
    workers[index].iterations = kIterations;
    workers[index].failures = 0;
    if (pthread_create(&threads[index], NULL, run_convert_worker, &workers[index]) != 0) {
      break;
    }
    ++created;
  }
  int worker_failures = 0;
  for (int index = 0; index < created; ++index) {
    pthread_join(threads[index], NULL);
    worker_failures += workers[index].failures;
  }
  if (created != kThreads || worker_failures != 0) {
    fail("independent converters convert concurrently", "a concurrent conversion failed");
    return;
  }
  pass("independent converters convert concurrently");
}

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <config-dir> <scratch-dir>\n", argv[0]);
    return 2;
  }
  const char* configs = argv[1];
  const char* scratch = argv[2];

  char* s2twp = join_path(configs, "s2twp.json");
  char* t2s = join_path(configs, "t2s.json");
  if (!s2twp || !t2s) {
    fprintf(stderr, "cannot build the config paths\n");
    return 2;
  }

  // The conversions the tools panel offers, against the real bundled data.
  expect_conversion(configs, "s2twp.json", "软件", "軟體",
                    "s2twp converts 软件 to 軟體");
  expect_conversion(configs, "t2s.json", "軟體", "软体", "t2s converts 軟體 to 软体");
  expect_conversion(configs, "s2t.json", "汉字", "漢字", "s2t converts 汉字 to 漢字");
  expect_conversion(configs, "s2twp.json", "信息", "資訊",
                    "s2twp converts the phrase 信息 to 資訊");
  expect_conversion(configs, "s2twp.json", "", "", "empty input converts to empty output");
  expect_conversion(configs, "s2twp.json", "🙂e\xCC\x81日本語", "🙂e\xCC\x81日本語",
                    "already-correct unicode text is returned unchanged");
  expect_conversion(configs, "s2twp.json", "ＡＢＣ１", "ＡＢＣ１",
                    "the width step is not native: full-width ASCII is untouched");

  // Missing / malformed configs: OpenCC opens the config before any text work.
  char* missing = join_path(configs, "missing-config.json");
  if (missing) {
    expect_status(missing, "软件", strlen("软件"), RB_OPENCC_CONFIG_UNAVAILABLE,
                  "a missing config reports config unavailable");
    free(missing);
  }

  char* invalid_config = join_path(scratch, "invalid-config.json");
  char* missing_dictionary = join_path(scratch, "missing-dictionary.json");
  if (invalid_config && missing_dictionary) {
    if (!write_text_file(invalid_config, "{\"name\": \"broken\",")) {
      fail("a malformed config reports config unavailable", "cannot write the fixture");
    } else {
      expect_status(invalid_config, "软件", strlen("软件"), RB_OPENCC_CONFIG_UNAVAILABLE,
                    "a malformed config reports config unavailable");
    }
    const char* config_without_dictionary =
        "{\"name\": \"missing dictionary\","
        "\"segmentation\":{\"type\":\"mmseg\",\"dict\":"
        "{\"type\":\"ocd2\",\"file\":\"absent-dictionary.ocd2\"}},"
        "\"conversion_chain\":[{\"dict\":{\"type\":\"ocd2\","
        "\"file\":\"absent-dictionary.ocd2\"}}]}";
    if (!write_text_file(missing_dictionary, config_without_dictionary)) {
      fail("a config naming a missing dictionary reports config unavailable",
           "cannot write the fixture");
    } else {
      expect_status(missing_dictionary, "软件", strlen("软件"), RB_OPENCC_CONFIG_UNAVAILABLE,
                    "a config naming a missing dictionary reports config unavailable");
    }
  }
  free(invalid_config);
  free(missing_dictionary);

  // Argument and ownership contract.
  expect_status(NULL, "软件", strlen("软件"), RB_OPENCC_INVALID_ARGUMENT,
                "a null config path is an invalid argument");
  expect_status("", "软件", strlen("软件"), RB_OPENCC_INVALID_ARGUMENT,
                "an empty config path is an invalid argument");
  expect_status("s2twp.json", "软件", strlen("软件"), RB_OPENCC_INVALID_ARGUMENT,
                "a relative config path is an invalid argument");
  expect_status(s2twp, NULL, 1, RB_OPENCC_INVALID_ARGUMENT,
                "null input text with a length is an invalid argument");

  char* error = NULL;
  int status = rb_opencc_convert(s2twp, "软件", strlen("软件"), NULL, NULL, &error);
  if (status == RB_OPENCC_INVALID_ARGUMENT) {
    pass("a null out_text is an invalid argument");
  } else {
    fail("a null out_text is an invalid argument", "status does not match");
  }
  rb_opencc_free(error);

  char* output = NULL;
  status = rb_opencc_convert(s2twp, "软件", strlen("软件"), &output, NULL, NULL);
  check(status == RB_OPENCC_OK && output && strcmp(output, "軟體") == 0,
        "a null out_error is accepted on success");
  rb_opencc_free(output);

  {
    size_t too_long_length = (size_t)RB_OPENCC_MAX_INPUT_BYTES + 1;
    char* too_long = (char*)malloc(too_long_length);
    if (!too_long) {
      fail("input above the byte cap is an invalid argument", "cannot allocate the input");
    } else {
      memset(too_long, 'a', too_long_length);
      output = NULL;
      error = NULL;
      status = rb_opencc_convert(s2twp, too_long, too_long_length, &output, NULL, &error);
      if (status == RB_OPENCC_INVALID_ARGUMENT && !output) {
        pass("input above the byte cap is an invalid argument");
      } else {
        fail("input above the byte cap is an invalid argument", "status does not match");
      }
      rb_opencc_free(output);
      rb_opencc_free(error);
      free(too_long);
    }
  }

  // Malformed UTF-8 is refused before OpenCC sees it, so diagnostics stay UTF-8.
  {
    const char invalid_utf8[] = {(char)0xFF, (char)0xFE, 'a'};
    output = NULL;
    error = NULL;
    status = rb_opencc_convert(s2twp, invalid_utf8, sizeof(invalid_utf8), &output, NULL, &error);
    if (status == RB_OPENCC_CONVERSION_FAILED && !output && error && error[0] != '\0') {
      pass("malformed UTF-8 reports a conversion failure");
    } else {
      fail("malformed UTF-8 reports a conversion failure", "status does not match");
    }
    rb_opencc_free(output);
    rb_opencc_free(error);
  }

  // Results are caller-owned copies: freeing one result cannot disturb another.
  {
    char* first = NULL;
    char* first_error = NULL;
    char* second = NULL;
    char* second_error = NULL;
    int first_status =
        rb_opencc_convert(s2twp, "软件", strlen("软件"), &first, NULL, &first_error);
    int second_status =
        rb_opencc_convert(s2twp, "信息", strlen("信息"), &second, NULL, &second_error);
    rb_opencc_free(first);
    rb_opencc_free(first_error);
    check(first_status == RB_OPENCC_OK && second_status == RB_OPENCC_OK && second &&
              strcmp(second, "資訊") == 0,
          "results are caller-owned copies");
    rb_opencc_free(second);
    rb_opencc_free(second_error);
  }

  check_concurrent_conversions(s2twp);
  rb_opencc_free(NULL);
  pass("rb_opencc_free accepts NULL");

  free(s2twp);
  free(t2s);

  if (failures == 0) {
    printf("ALL PASS\n");
    return 0;
  }
  fprintf(stderr, "%d check(s) failed\n", failures);
  return 1;
}
