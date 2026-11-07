// ---------------------------------------------------------------------------
// rime_opencc.h — standalone OpenCC text conversion for the keyboard tools.
//
// What this layer is:
//   * a one-call C ABI over OpenCC's C++ `SimpleConverter`, for ONE absolute
//     config file path (one of the configs shipped under
//     Resources/EngineResources/opencc);
//   * a hard boundary from librime: this file includes no librime header,
//     registers no module, reads no service/registry/session state and never
//     calls RimeInitialize. A conversion can therefore run while the keyboard
//     engine owns its process-global singleton, on any queue that is not the
//     main thread.
//
// What this layer deliberately is NOT:
//   * not a converter cache. Every rb_opencc_convert() builds and destroys a
//     converter, so the .ocd2 dictionaries load per call. A conversion is
//     disk-bound and must not run on the main thread; keeping no converter
//     alive between calls is what makes concurrent calls safe.
//   * not a width transform. Full-width/half-width conversion is a
//     keyboard-tool step implemented in Swift; OpenCC leaves full-width ASCII
//     untouched.
//
// Memory model (same convention as the rest of the bridge): every returned
// string is malloc'd here, owned by the caller and released with
// rb_opencc_free(). NULL is accepted and ignored.
// ---------------------------------------------------------------------------
#ifndef RIME_OPENCC_H_
#define RIME_OPENCC_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Longest accepted input. The keyboard-tool panel already bounds the text it
 * offers (a selection or one paragraph), so this only rejects accidental
 * misuse from a C caller. */
#define RB_OPENCC_MAX_INPUT_BYTES (64u * 1024u)

/* Outcome of rb_opencc_convert(). */
enum rb_opencc_status {
  RB_OPENCC_OK = 0,
  /* A NULL/empty/non-absolute config path, NULL input text, an input longer
   * than RB_OPENCC_MAX_INPUT_BYTES, or a NULL out_text. */
  RB_OPENCC_INVALID_ARGUMENT = 1,
  /* OpenCC could not open the config or one of the dictionaries it names. */
  RB_OPENCC_CONFIG_UNAVAILABLE = 2,
  /* The text is not valid UTF-8, or OpenCC failed while converting it. */
  RB_OPENCC_CONVERSION_FAILED = 3,
  /* A result or diagnostic string could not be allocated. */
  RB_OPENCC_OUT_OF_MEMORY = 4,
};

/*
 * Converts `input_length` bytes of UTF-8 `input_utf8` with the OpenCC config at
 * `config_path`. The path must be absolute: OpenCC resolves the .ocd2 files the
 * config names relative to the config file's directory, and a relative path
 * would resolve against the process working directory instead of the bundle.
 *
 * On RB_OPENCC_OK, *out_text receives a newly malloc'd NUL-terminated UTF-8
 * string (an empty input allocates an empty string) and *out_error is left NULL.
 * When out_length is supplied it receives the byte length, including embedded NUL
 * bytes but excluding the trailing terminator; failures set it to zero.
 * On any other status, *out_text is NULL and *out_error receives a newly
 * malloc'd NUL-terminated UTF-8 diagnostic; out_error may be NULL when the
 * caller does not need the reason, in which case nothing is retained.
 *
 * Both outputs are released with rb_opencc_free(). A call constructs its own
 * converter and touches no shared mutable state, so calls may run concurrently
 * from different threads. */
enum rb_opencc_status rb_opencc_convert(const char* config_path,
                                        const char* input_utf8,
                                        size_t input_length,
                                        char** out_text,
                                        size_t* out_length,
                                        char** out_error);

/* Releases a string returned by rb_opencc_convert(). NULL is a no-op. */
void rb_opencc_free(char* text);

#ifdef __cplusplus
}
#endif

#endif  // RIME_OPENCC_H_
