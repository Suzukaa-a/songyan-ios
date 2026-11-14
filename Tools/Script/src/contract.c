#include "songyan_script.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Header syntax (interface version 1):
 *
 *   // @api <n>
 *   // @name <text>
 *   // @description <text>          optional
 *   // @connect <host>              optional, repeatable
 *   // @setting <key> <text|url|choice> <label>
 *   // @option <key> <value>
 *   // @timeout <seconds>
 *   // @secret <key> <label>
 *   // @input audio                 optional
 *
 * The header is the run of leading lines that are blank or start with //; the first other line
 * ends it, so comments in the script body are not declarations. A // line that is not a
 * declaration is a free-form note. An unknown @key is an error rather than something to ignore,
 * because a typo that silently disappears is worse than a refused import. */

static const char *const kErrorNames[] = {
    "ok",
    "timeout",
    "outOfMemory",
    "addressNotAllowed",
    "networkFailure",
    "script",
    "badHeader",
    "unsupportedApiVersion",
    "capabilityUnavailable",
};

static const char *const kSettingKindNames[] = {"text", "url", "choice"};

static const char *const kCapabilityNames[] = {"text", "audio"};

const char *songyan_script_error_name(songyan_script_error error) {
    if ((size_t)error >= sizeof(kErrorNames) / sizeof(kErrorNames[0])) {
        return "unknown";
    }
    return kErrorNames[error];
}

const char *songyan_script_setting_kind_name(songyan_script_setting_kind kind) {
    if ((size_t)kind >= sizeof(kSettingKindNames) / sizeof(kSettingKindNames[0])) {
        return "unknown";
    }
    return kSettingKindNames[kind];
}

const char *songyan_script_capability_name(songyan_script_capability capability) {
    switch (capability) {
    case SONGYAN_SCRIPT_CAPABILITY_TEXT:
        return kCapabilityNames[0];
    case SONGYAN_SCRIPT_CAPABILITY_AUDIO:
        return kCapabilityNames[1];
    }
    return "unknown";
}

static int is_space(char character) { return character == ' ' || character == '\t'; }

static int is_ascii_alnum(char character) {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9');
}

/* Declaration keys and setting keys share one shape: ASCII letters, digits, '_' and '-'. */
static int is_key_char(char character) {
    return is_ascii_alnum(character) || character == '_' || character == '-';
}

static void *script_alloc(size_t size);
static void *script_realloc(void *item, size_t size);
static void script_free(void *item);

static char *duplicate_range(const char *start, size_t length) {
    char *copy = script_alloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static void trim_range(const char **start, size_t *length) {
    while (*length > 0 && is_space(**start)) {
        (*start)++;
        (*length)--;
    }
    while (*length > 0 && is_space((*start)[*length - 1])) {
        (*length)--;
    }
}

/* Allocations go through these wrappers so the test build can force failures and count what is
 * still alive; the production build is a plain pass-through. */
#ifdef SONGYAN_SCRIPT_TESTING
static long test_failures_remaining = -1;
static long test_live_allocations = 0;

void songyan_script_test_set_allocation_failure(long fail_after) {
    test_failures_remaining = fail_after;
}

long songyan_script_test_live_allocations(void) { return test_live_allocations; }

static int test_failure_due(void) {
    if (test_failures_remaining < 0) {
        return 0;
    }
    if (test_failures_remaining == 0) {
        return 1;
    }
    test_failures_remaining--;
    return 0;
}
#endif

static void *script_alloc(size_t size) {
#ifdef SONGYAN_SCRIPT_TESTING
    if (test_failure_due()) {
        return NULL;
    }
#endif
    void *allocated = malloc(size);
#ifdef SONGYAN_SCRIPT_TESTING
    if (allocated != NULL) {
        test_live_allocations++;
    }
#endif
    return allocated;
}

static void *script_realloc(void *item, size_t size) {
#ifdef SONGYAN_SCRIPT_TESTING
    if (test_failure_due()) {
        return NULL;
    }
#endif
    void *grown = realloc(item, size);
#ifdef SONGYAN_SCRIPT_TESTING
    if (grown != NULL && item == NULL) {
        test_live_allocations++;
    }
#endif
    return grown;
}

static void script_free(void *item) {
    if (item == NULL) {
        return;
    }
#ifdef SONGYAN_SCRIPT_TESTING
    test_live_allocations--;
#endif
    free(item);
}

/* The source is external input: an embedded NUL or invalid UTF-8 would silently truncate or
 * corrupt the declarations and the JSON built from them, so both are refused before parsing. */
static size_t line_at_offset(const char *source, size_t offset) {
    size_t line = 1;
    for (size_t index = 0; index < offset; index++) {
        if (source[index] == '\n') {
            line++;
        }
    }
    return line;
}

static int valid_utf8(const unsigned char *text, size_t length, size_t *bad_offset) {
    size_t index = 0;
    while (index < length) {
        unsigned char lead = text[index];
        size_t extra = 0;
        unsigned char low = 0x80;
        unsigned char high = 0xBF;
        if (lead <= 0x7F) {
            index++;
            continue;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            extra = 1;
        } else if (lead == 0xE0) {
            extra = 2;
            low = 0xA0;
        } else if ((lead >= 0xE1 && lead <= 0xEC) || (lead >= 0xEE && lead <= 0xEF)) {
            extra = 2;
        } else if (lead == 0xED) {
            extra = 2;
            high = 0x9F;
        } else if (lead == 0xF0) {
            extra = 3;
            low = 0x90;
        } else if (lead >= 0xF1 && lead <= 0xF3) {
            extra = 3;
        } else if (lead == 0xF4) {
            extra = 3;
            high = 0x8F;
        } else {
            *bad_offset = index;
            return 0;
        }
        if (index + extra >= length) {
            *bad_offset = index;
            return 0;
        }
        for (size_t step = 1; step <= extra; step++) {
            unsigned char continuation = text[index + step];
            unsigned char lower = step == 1 ? low : 0x80;
            unsigned char upper = step == 1 ? high : 0xBF;
            if (continuation < lower || continuation > upper) {
                *bad_offset = index;
                return 0;
            }
        }
        index += extra + 1;
    }
    return 1;
}

static int grow_array(void **items, size_t *capacity, size_t needed, size_t item_size) {
    if (needed <= *capacity) {
        return 1;
    }
    size_t next = *capacity == 0 ? 4 : *capacity * 2;
    while (next < needed) {
        next *= 2;
    }
    void *grown = script_realloc(*items, next * item_size);
    if (grown == NULL) {
        return 0;
    }
    *items = grown;
    *capacity = next;
    return 1;
}

void songyan_script_header_free(songyan_script_header *header) {
    if (header == NULL) {
        return;
    }
    script_free(header->name);
    script_free(header->description);
    for (size_t index = 0; index < header->connect_count; index++) {
        script_free(header->connects[index]);
    }
    script_free(header->connects);
    for (size_t index = 0; index < header->setting_count; index++) {
        script_free(header->settings[index].key);
        script_free(header->settings[index].label);
        for (size_t option = 0; option < header->settings[index].option_count; option++) {
            script_free(header->settings[index].options[option]);
        }
        script_free(header->settings[index].options);
    }
    script_free(header->settings);
    for (size_t index = 0; index < header->secret_count; index++) {
        script_free(header->secrets[index].key);
        script_free(header->secrets[index].label);
    }
    script_free(header->secrets);
    memset(header, 0, sizeof(*header));
}

static songyan_script_error reject(songyan_script_header *header, songyan_script_header_error *error,
                                   songyan_script_error code, size_t line, const char *format, ...) {
    if (error != NULL) {
        error->line = line;
        va_list arguments;
        va_start(arguments, format);
        int written = vsnprintf(error->message, sizeof(error->message), format, arguments);
        va_end(arguments);
        error->message_truncated = written >= (int)sizeof(error->message);
    }
    songyan_script_header_free(header);
    return code;
}

/* A @connect value is a host name and nothing else: no scheme, port, path, wildcard or space.
 * Uppercase is folded to lowercase so one host cannot be declared twice. */
static int valid_host(const char *host) {
    size_t label = 0;
    for (const char *cursor = host; *cursor != '\0'; cursor++) {
        char character = *cursor;
        if (character == '.') {
            if (label == 0) {
                return 0;
            }
            label = 0;
            continue;
        }
        if (!is_ascii_alnum(character) && character != '-') {
            return 0;
        }
        if (character == '-' && label == 0) {
            return 0;
        }
        label++;
    }
    return label > 0 && host[strlen(host) - 1] != '-';
}

static char *lowercase_duplicate(const char *text) {
    char *copy = duplicate_range(text, strlen(text));
    if (copy == NULL) {
        return NULL;
    }
    for (char *cursor = copy; *cursor != '\0'; cursor++) {
        if (*cursor >= 'A' && *cursor <= 'Z') {
            *cursor = (char)(*cursor - 'A' + 'a');
        }
    }
    return copy;
}

static int has_setting_key(const songyan_script_header *header, const char *key, size_t length) {
    for (size_t index = 0; index < header->setting_count; index++) {
        const char *existing = header->settings[index].key;
        if (strlen(existing) == length && memcmp(existing, key, length) == 0) {
            return 1;
        }
    }
    for (size_t index = 0; index < header->secret_count; index++) {
        const char *existing = header->secrets[index].key;
        if (strlen(existing) == length && memcmp(existing, key, length) == 0) {
            return 1;
        }
    }
    return 0;
}

typedef struct {
    size_t connects;
    size_t settings;
    size_t secrets;
} parse_capacity;

static songyan_script_error parse_declaration(songyan_script_header *header, parse_capacity *capacity,
                                              const char *text, size_t length, size_t line,
                                              size_t *single_fields, songyan_script_header_error *error) {
    size_t key_length = 0;
    while (key_length < length && !is_space(text[key_length])) {
        key_length++;
    }
    const char *rest = text + key_length;
    size_t rest_length = length - key_length;
    trim_range(&rest, &rest_length);

    if (key_length == 3 && memcmp(text, "api", 3) == 0) {
        if (single_fields[0]) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "duplicate @api");
        }
        if (rest_length == 0 || rest[0] == '0') {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @api");
        }
        /* The version is compared as written: a token too large for 64 bits is refused without
         * echoing a clipped number, and a representable one is echoed exactly. */
        unsigned long long value = 0;
        int overflowed = 0;
        for (size_t index = 0; index < rest_length; index++) {
            if (rest[index] < '0' || rest[index] > '9') {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @api");
            }
            unsigned digit = (unsigned)(rest[index] - '0');
            if (!overflowed) {
                if (value > (UINT64_MAX - digit) / 10) {
                    overflowed = 1;
                } else {
                    value = value * 10 + digit;
                }
            }
        }
        single_fields[0] = 1;
        if (overflowed) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_API_VERSION, line,
                          "unsupported @api (number too large); this host implements %u",
                          SONGYAN_SCRIPT_API_VERSION);
        }
        if (value != SONGYAN_SCRIPT_API_VERSION) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_API_VERSION, line,
                          "unsupported @api %llu; this host implements %u", value,
                          SONGYAN_SCRIPT_API_VERSION);
        }
        header->api = (unsigned)value;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 4 && memcmp(text, "name", 4) == 0) {
        if (single_fields[1]) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "duplicate @name");
        }
        if (rest_length == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "empty @name");
        }
        header->name = duplicate_range(rest, rest_length);
        if (header->name == NULL) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        single_fields[1] = 1;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 7 && memcmp(text, "timeout", 7) == 0) {
        if (header->timeout_seconds != 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "duplicate @timeout");
        }
        if (rest_length == 0 || rest_length > 3 || rest[0] == '0') {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @timeout");
        }
        unsigned value = 0;
        for (size_t index = 0; index < rest_length; index++) {
            if (rest[index] < '0' || rest[index] > '9') {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @timeout");
            }
            value = value * 10 + (unsigned)(rest[index] - '0');
        }
        if (value > SONGYAN_SCRIPT_MAX_TIMEOUT_SECONDS) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "@timeout %u is longer than %u seconds", value,
                          SONGYAN_SCRIPT_MAX_TIMEOUT_SECONDS);
        }
        header->timeout_seconds = value;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 11 && memcmp(text, "description", 11) == 0) {
        if (single_fields[2]) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "duplicate @description");
        }
        if (rest_length == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "empty @description");
        }
        header->description = duplicate_range(rest, rest_length);
        if (header->description == NULL) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        single_fields[2] = 1;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 7 && memcmp(text, "connect", 7) == 0) {
        size_t host_length = 0;
        while (host_length < rest_length && !is_space(rest[host_length])) {
            host_length++;
        }
        size_t tail = host_length;
        while (tail < rest_length && is_space(rest[tail])) {
            tail++;
        }
        if (host_length == 0 || tail != rest_length) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @connect");
        }
        char *host = duplicate_range(rest, host_length);
        if (host == NULL) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        if (!valid_host(host)) {
            script_free(host);
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "invalid @connect %.*s", (int)rest_length, rest);
        }
        char *folded = lowercase_duplicate(host);
        script_free(host);
        if (folded == NULL) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        for (size_t index = 0; index < header->connect_count; index++) {
            if (strcmp(header->connects[index], folded) == 0) {
                script_free(folded);
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                              "duplicate @connect %s", header->connects[index]);
            }
        }
        if (!grow_array((void **)&header->connects, &capacity->connects,
                        header->connect_count + 1, sizeof(*header->connects))) {
            script_free(folded);
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        header->connects[header->connect_count++] = folded;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 7 && memcmp(text, "setting", 7) == 0) {
        const char *cursor = rest;
        size_t remaining = rest_length;
        size_t key_size = 0;
        while (key_size < remaining && !is_space(cursor[key_size])) {
            key_size++;
        }
        if (key_size == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @setting");
        }
        for (size_t index = 0; index < key_size; index++) {
            if (!is_key_char(cursor[index])) {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                              "invalid setting key %.*s", (int)key_size, cursor);
            }
        }
        cursor += key_size;
        remaining -= key_size;
        trim_range(&cursor, &remaining);
        size_t kind_size = 0;
        while (kind_size < remaining && !is_space(cursor[kind_size])) {
            kind_size++;
        }
        songyan_script_setting_kind kind;
        if (kind_size == 4 && memcmp(cursor, "text", 4) == 0) {
            kind = SONGYAN_SCRIPT_SETTING_TEXT;
        } else if (kind_size == 3 && memcmp(cursor, "url", 3) == 0) {
            kind = SONGYAN_SCRIPT_SETTING_URL;
        } else if (kind_size == 6 && memcmp(cursor, "choice", 6) == 0) {
            kind = SONGYAN_SCRIPT_SETTING_CHOICE;
        } else {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "invalid @setting kind %.*s", (int)kind_size, cursor);
        }
        cursor += kind_size;
        remaining -= kind_size;
        trim_range(&cursor, &remaining);
        if (remaining == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "missing @setting label");
        }
        if (has_setting_key(header, rest, key_size)) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "duplicate setting key %.*s", (int)key_size, rest);
        }
        if (!grow_array((void **)&header->settings, &capacity->settings,
                        header->setting_count + 1, sizeof(*header->settings))) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        songyan_script_setting setting;
        memset(&setting, 0, sizeof(setting));
        setting.key = duplicate_range(rest, key_size);
        setting.label = duplicate_range(cursor, remaining);
        setting.kind = kind;
        if (setting.key == NULL || setting.label == NULL) {
            script_free(setting.key);
            script_free(setting.label);
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        header->settings[header->setting_count++] = setting;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 6 && memcmp(text, "option", 6) == 0) {
        size_t key_size = 0;
        while (key_size < rest_length && !is_space(rest[key_size])) {
            key_size++;
        }
        const char *value = rest + key_size;
        size_t value_length = rest_length - key_size;
        trim_range(&value, &value_length);
        if (key_size == 0 || value_length == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @option");
        }
        songyan_script_setting *setting = NULL;
        for (size_t index = 0; index < header->setting_count; index++) {
            const char *existing = header->settings[index].key;
            if (strlen(existing) == key_size && memcmp(existing, rest, key_size) == 0) {
                setting = &header->settings[index];
            }
        }
        if (setting == NULL || setting->kind != SONGYAN_SCRIPT_SETTING_CHOICE) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "@option %.*s does not follow a choice setting", (int)key_size, rest);
        }
        for (size_t index = 0; index < setting->option_count; index++) {
            const char *existing = setting->options[index];
            if (strlen(existing) == value_length && memcmp(existing, value, value_length) == 0) {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                              "duplicate @option %.*s", (int)value_length, value);
            }
        }
        /* Options are few, so the array grows to the exact count instead of tracking capacity. */
        size_t capacity_now = setting->option_count;
        if (!grow_array((void **)&setting->options, &capacity_now, setting->option_count + 1,
                        sizeof(*setting->options))) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        char *copy = duplicate_range(value, value_length);
        if (copy == NULL) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        setting->options[setting->option_count++] = copy;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 6 && memcmp(text, "secret", 6) == 0) {
        const char *cursor = rest;
        size_t remaining = rest_length;
        size_t key_size = 0;
        while (key_size < remaining && !is_space(cursor[key_size])) {
            key_size++;
        }
        if (key_size == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @secret");
        }
        for (size_t index = 0; index < key_size; index++) {
            if (!is_key_char(cursor[index])) {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                              "invalid secret key %.*s", (int)key_size, cursor);
            }
        }
        cursor += key_size;
        remaining -= key_size;
        trim_range(&cursor, &remaining);
        if (remaining == 0) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "missing @secret label");
        }
        if (has_setting_key(header, rest, key_size)) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line,
                          "duplicate setting key %.*s", (int)key_size, rest);
        }
        if (!grow_array((void **)&header->secrets, &capacity->secrets,
                        header->secret_count + 1, sizeof(*header->secrets))) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        songyan_script_secret secret;
        secret.key = duplicate_range(rest, key_size);
        secret.label = duplicate_range(cursor, remaining);
        if (secret.key == NULL || secret.label == NULL) {
            script_free(secret.key);
            script_free(secret.label);
            return reject(header, error, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY, line, "out of memory");
        }
        header->secrets[header->secret_count++] = secret;
        return SONGYAN_SCRIPT_OK;
    }
    if (key_length == 5 && memcmp(text, "input", 5) == 0) {
        if (rest_length == 5 && memcmp(rest, "audio", 5) == 0) {
            if ((header->needs & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0) {
                return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "duplicate @input audio");
            }
            header->needs |= SONGYAN_SCRIPT_CAPABILITY_AUDIO;
            return SONGYAN_SCRIPT_OK;
        }
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "invalid @input %.*s",
                      (int)rest_length, rest);
    }
    return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, line, "unknown declaration @%.*s",
                  (int)key_length, text);
}

songyan_script_error songyan_script_header_parse(const char *source, size_t length,
                                                 songyan_script_header *header,
                                                 songyan_script_header_error *error) {
    if (header == NULL) {
        return SONGYAN_SCRIPT_ERROR_HEADER;
    }
    memset(header, 0, sizeof(*header));
    if (error != NULL) {
        error->line = 0;
        error->message_truncated = 0;
        error->message[0] = '\0';
    }
    if (source == NULL) {
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, 0, "no source");
    }
    /* An embedded NUL would truncate a declaration's text and an invalid UTF-8 sequence would
     * produce a JSON report that parsers reject, so the source is checked before it is read. */
    for (size_t index = 0; index < length; index++) {
        if (source[index] == '\0') {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER,
                          line_at_offset(source, index), "NUL byte in source");
        }
    }
    size_t bad_utf8_offset = 0;
    if (!valid_utf8((const unsigned char *)source, length, &bad_utf8_offset)) {
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER,
                      line_at_offset(source, bad_utf8_offset), "invalid UTF-8");
    }

    parse_capacity capacity = {0, 0, 0};
    size_t single_fields[3] = {0, 0, 0}; /* api, name, description */
    int saw_declaration = 0;
    size_t line = 1;
    /* A UTF-8 BOM is an editor marker, not a line: skip it so a saved-with-BOM file still parses. */
    size_t offset = 0;
    if (length >= 3 && (unsigned char)source[0] == 0xEF && (unsigned char)source[1] == 0xBB &&
        (unsigned char)source[2] == 0xBF) {
        offset = 3;
    }
    while (offset < length) {
        size_t line_end = offset;
        while (line_end < length && source[line_end] != '\n') {
            line_end++;
        }
        size_t line_length = line_end - offset;
        if (line_length > 0 && source[offset + line_length - 1] == '\r') {
            line_length--;
        }
        const char *text = source + offset;
        size_t cursor = 0;
        while (cursor < line_length && is_space(text[cursor])) {
            cursor++;
        }
        if (cursor == line_length) {
            offset = line_end < length ? line_end + 1 : length;
            line++;
            continue;
        }
        if (cursor + 1 < line_length && text[cursor] == '/' && text[cursor + 1] == '/') {
            const char *content = text + cursor + 2;
            size_t content_length = line_length - cursor - 2;
            trim_range(&content, &content_length);
            if (content_length > 0 && content[0] == '@') {
                saw_declaration = 1;
                songyan_script_error code =
                    parse_declaration(header, &capacity, content + 1, content_length - 1, line,
                                      single_fields, error);
                if (code != SONGYAN_SCRIPT_OK) {
                    return code;
                }
            }
            offset = line_end < length ? line_end + 1 : length;
            line++;
            continue;
        }
        break; /* first line that is neither blank nor a comment ends the header */
    }

    if (!saw_declaration) {
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, 1, "no header");
    }
    if (!single_fields[0]) {
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, 0, "missing @api");
    }
    if (!single_fields[1]) {
        return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, 0, "missing @name");
    }
    for (size_t index = 0; index < header->setting_count; index++) {
        const songyan_script_setting *setting = &header->settings[index];
        if (setting->kind == SONGYAN_SCRIPT_SETTING_CHOICE && setting->option_count < 2) {
            return reject(header, error, SONGYAN_SCRIPT_ERROR_HEADER, 0,
                          "choice setting %s needs at least two @option lines", setting->key);
        }
    }
    header->needs |= SONGYAN_SCRIPT_CAPABILITY_TEXT;
    return SONGYAN_SCRIPT_OK;
}

/* Splits an absolute http(s) URL into its scheme and lowercase host. Returns 0 for anything else,
 * including URLs with credentials. host must hold at least 256 bytes. */
static int split_url(const char *url, int *is_https, char *host, size_t host_size) {
    if (url == NULL) {
        return 0;
    }
    size_t scheme_length;
    if (strncasecmp(url, "https://", 8) == 0) {
        *is_https = 1;
        scheme_length = 8;
    } else if (strncasecmp(url, "http://", 7) == 0) {
        *is_https = 0;
        scheme_length = 7;
    } else {
        return 0;
    }
    const char *start = url + scheme_length;
    const char *end = start;
    while (*end != '\0' && *end != '/' && *end != '?' && *end != '#') {
        if (*end == '@' || *end == '\\' || is_space(*end)) {
            return 0;
        }
        end++;
    }
    const char *host_end = end;
    if (start < end && *start == '[') {
        const char *close = memchr(start, ']', (size_t)(end - start));
        if (close == NULL) {
            return 0;
        }
        start++;
        host_end = close;
    } else {
        const char *colon = memchr(start, ':', (size_t)(end - start));
        if (colon != NULL) {
            host_end = colon;
        }
    }
    size_t length = (size_t)(host_end - start);
    if (length == 0 || length >= host_size) {
        return 0;
    }
    for (size_t index = 0; index < length; index++) {
        char character = start[index];
        host[index] = (character >= 'A' && character <= 'Z') ? (char)(character - 'A' + 'a')
                                                             : character;
    }
    host[length] = '\0';
    return 1;
}

/* Four dotted decimal octets without leading zeros, which some resolvers would read as octal. */
static int parse_ipv4(const char *host, unsigned octets[4]) {
    const char *cursor = host;
    for (int part = 0; part < 4; part++) {
        if (*cursor < '0' || *cursor > '9') {
            return 0;
        }
        unsigned value = 0;
        const char *digits = cursor;
        while (*cursor >= '0' && *cursor <= '9') {
            value = value * 10 + (unsigned)(*cursor - '0');
            if (value > 255) {
                return 0;
            }
            cursor++;
        }
        if (cursor - digits > 1 && *digits == '0') {
            return 0;
        }
        octets[part] = value;
        if (part < 3) {
            if (*cursor != '.') {
                return 0;
            }
            cursor++;
        }
    }
    return *cursor == '\0';
}

static int is_local_host(const char *host) {
    size_t length = strlen(host);
    if (strcmp(host, "localhost") == 0) {
        return 1;
    }
    if (length > 6 && strcmp(host + length - 6, ".local") == 0) {
        return 1;
    }
    unsigned octets[4];
    if (parse_ipv4(host, octets)) {
        return octets[0] == 127 || octets[0] == 10 ||
               (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
               (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254);
    }
    if (strchr(host, ':') != NULL) {
        if (strcmp(host, "::1") == 0) {
            return 1;
        }
        /* fc00::/7 unique local and fe80::/10 link-local, judged from the first group. */
        return (strncmp(host, "fc", 2) == 0 || strncmp(host, "fd", 2) == 0 ||
                strncmp(host, "fe8", 3) == 0 || strncmp(host, "fe9", 3) == 0 ||
                strncmp(host, "fea", 3) == 0 || strncmp(host, "feb", 3) == 0) &&
               strlen(host) > 4 && strchr(host, ':') - host == 4;
    }
    return 0;
}

int songyan_script_address_allowed(const char *url, const songyan_script_header *header,
                                   const char *const *setting_urls, size_t setting_url_count) {
    char host[256];
    int is_https = 0;
    if (!split_url(url, &is_https, host, sizeof(host))) {
        return 0;
    }
    for (size_t index = 0; index < setting_url_count; index++) {
        char typed[256];
        int typed_https = 0;
        if (setting_urls[index] != NULL &&
            split_url(setting_urls[index], &typed_https, typed, sizeof(typed)) &&
            strcmp(typed, host) == 0 && (is_https || is_local_host(host))) {
            return 1;
        }
    }
    if (!is_https || header == NULL) {
        return 0;
    }
    for (size_t index = 0; index < header->connect_count; index++) {
        if (strcmp(header->connects[index], host) == 0) {
            return 1;
        }
    }
    return 0;
}

uint32_t songyan_script_run_duration_ms(const songyan_script_header *header,
                                        const songyan_script_limits *limits) {
    if (header != NULL && header->timeout_seconds != 0) {
        return header->timeout_seconds * 1000u;
    }
    return limits == NULL ? 0 : limits->duration_ms;
}

size_t songyan_script_limits_missing(const songyan_script_limits *limits, const char *missing[],
                                     size_t capacity) {
    static const char *const kNames[] = {"sourceBytes",   "heapBytes",     "durationMs",
                                         "computeMs",     "requestCount",  "responseBytes",
                                         "inputTextBytes"};
    size_t written = 0;
    if (limits == NULL) {
        return 0;
    }
    const size_t values[7] = {limits->source_bytes,         limits->heap_bytes,
                              (size_t)limits->duration_ms,  (size_t)limits->compute_ms,
                              (size_t)limits->request_count, limits->response_bytes,
                              limits->input_text_bytes};
    for (size_t index = 0; index < 7; index++) {
        if (values[index] == 0) {
            if (missing != NULL && written < capacity) {
                missing[written] = kNames[index];
            }
            written++;
        }
    }
    return written;
}
