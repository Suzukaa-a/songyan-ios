// ---------------------------------------------------------------------------
// rime_opencc.cc — standalone OpenCC conversion behind a small C ABI.
//
// See rime_opencc.h for the contract. OpenCC is already linked into RimeKit for
// the engine's simplifier filter; this file reuses the same static library
// through its public C++ SimpleConverter rather than through librime's wrapper,
// so the conversion path owns no engine state at all.
//
// A converter is built and destroyed per call on purpose: the shipped .ocd2
// dictionaries are read-only, and per-call ownership is what lets the tools
// panel convert concurrently without a lock or a cache invalidation policy.
// The cost is loading the dictionaries per call, which is why callers must stay
// off the main thread.
// ---------------------------------------------------------------------------
#include "rime_opencc.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>

#include <opencc/SimpleConverter.hpp>

namespace {

bool is_absolute_path(const char* path) {
  return path != nullptr && path[0] == '/' && path[1] != '\0';
}

// Rejects malformed UTF-8 here so a refusal carries a valid UTF-8 diagnostic:
// OpenCC's own InvalidUTF8 message embeds the offending bytes verbatim.
bool is_valid_utf8(const char* text, size_t length) {
  const unsigned char* bytes = reinterpret_cast<const unsigned char*>(text);
  size_t index = 0;
  while (index < length) {
    const unsigned char lead = bytes[index];
    if (lead < 0x80) {
      ++index;
      continue;
    }
    size_t continuation_count = 0;
    unsigned int code_point = 0;
    if ((lead & 0xE0) == 0xC0) {
      continuation_count = 1;
      code_point = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
      continuation_count = 2;
      code_point = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
      continuation_count = 3;
      code_point = lead & 0x07;
    } else {
      return false;
    }
    if (index + continuation_count >= length) return false;
    for (size_t step = 1; step <= continuation_count; ++step) {
      const unsigned char continuation = bytes[index + step];
      if ((continuation & 0xC0) != 0x80) return false;
      code_point = (code_point << 6) | (continuation & 0x3F);
    }
    const bool overlong = (continuation_count == 1 && code_point < 0x80) ||
                          (continuation_count == 2 && code_point < 0x800) ||
                          (continuation_count == 3 && code_point < 0x10000);
    const bool surrogate = code_point >= 0xD800 && code_point <= 0xDFFF;
    if (overlong || surrogate || code_point > 0x10FFFF) return false;
    index += continuation_count + 1;
  }
  return true;
}

char* copy_string(const char* text, size_t length) {
  char* copy = static_cast<char*>(std::malloc(length + 1));
  if (!copy) return nullptr;
  std::memcpy(copy, text, length);
  copy[length] = '\0';
  return copy;
}

char* copy_string(const std::string& text) { return copy_string(text.data(), text.size()); }

char* copy_string(const char* text) {
  return copy_string(text, text ? std::strlen(text) : 0);
}

// Every refusal sets *out_text to NULL and hands the caller a diagnostic it must
// free; a caller that passed out_error == NULL gets only the status.
rb_opencc_status refuse(char** out_text, char** out_error, rb_opencc_status status,
                        const char* message) {
  if (out_text) *out_text = nullptr;
  char* diagnostic = copy_string(message);
  if (out_error) {
    *out_error = diagnostic;
  } else {
    std::free(diagnostic);
  }
  return diagnostic ? status : RB_OPENCC_OUT_OF_MEMORY;
}

}  // namespace

extern "C" enum rb_opencc_status rb_opencc_convert(const char* config_path,
                                                   const char* input_utf8,
                                                   size_t input_length,
                                                   char** out_text,
                                                   size_t* out_length,
                                                   char** out_error) {
  if (out_length) *out_length = 0;
  if (!out_text) return RB_OPENCC_INVALID_ARGUMENT;
  *out_text = nullptr;
  if (out_error) *out_error = nullptr;

  if (!is_absolute_path(config_path)) {
    return refuse(out_text, out_error, RB_OPENCC_INVALID_ARGUMENT,
                  "the OpenCC config path must be an absolute file path");
  }
  if (!input_utf8 && input_length != 0) {
    return refuse(out_text, out_error, RB_OPENCC_INVALID_ARGUMENT,
                  "the input text is NULL");
  }
  if (input_length > RB_OPENCC_MAX_INPUT_BYTES) {
    return refuse(out_text, out_error, RB_OPENCC_INVALID_ARGUMENT,
                  "the input text is longer than the conversion limit");
  }
  const char* text = input_utf8 ? input_utf8 : "";
  if (!is_valid_utf8(text, input_length)) {
    return refuse(out_text, out_error, RB_OPENCC_CONVERSION_FAILED,
                  "the input text is not valid UTF-8");
  }

  std::unique_ptr<opencc::SimpleConverter> converter;
  try {
    converter.reset(new opencc::SimpleConverter(config_path));
  } catch (const std::bad_alloc&) {
    return refuse(out_text, out_error, RB_OPENCC_OUT_OF_MEMORY, "out of memory");
  } catch (const std::exception& error) {
    return refuse(out_text, out_error, RB_OPENCC_CONFIG_UNAVAILABLE, error.what());
  } catch (...) {
    return refuse(out_text, out_error, RB_OPENCC_CONFIG_UNAVAILABLE,
                  "OpenCC could not load this config");
  }

  std::string converted;
  try {
    // OpenCC treats NUL as a terminator even with an explicit length. Convert
    // each text segment and retain separators so selected text is never truncated.
    size_t offset = 0;
    while (offset < input_length) {
      const char* separator = static_cast<const char*>(
          std::memchr(text + offset, 0, input_length - offset));
      size_t length = separator ? static_cast<size_t>(separator - text - offset)
                                : input_length - offset;
      converted += converter->Convert(text + offset, length);
      offset += length;
      if (offset < input_length) {
        converted.push_back('\0');
        ++offset;
      }
    }
  } catch (const std::bad_alloc&) {
    return refuse(out_text, out_error, RB_OPENCC_OUT_OF_MEMORY, "out of memory");
  } catch (const std::exception& error) {
    return refuse(out_text, out_error, RB_OPENCC_CONVERSION_FAILED, error.what());
  } catch (...) {
    return refuse(out_text, out_error, RB_OPENCC_CONVERSION_FAILED,
                  "OpenCC failed to convert this text");
  }

  char* output = copy_string(converted);
  if (!output) {
    return refuse(out_text, out_error, RB_OPENCC_OUT_OF_MEMORY, "out of memory");
  }
  *out_text = output;
  if (out_length) *out_length = converted.size();
  return RB_OPENCC_OK;
}

extern "C" void rb_opencc_free(char* text) { std::free(text); }
