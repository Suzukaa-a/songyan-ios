#ifndef SONGYAN_SCRIPT_H
#define SONGYAN_SCRIPT_H

/* Shared script contract, implemented once in C and used by both platforms. The header syntax,
 * the declarations it produces, the error codes and the capability model are defined here; the
 * reference implementation is src/contract.c and the shared behaviour cases are tests/cases/.
 *
 * Header grammar, interface version 1:
 *
 *   // @api <n>                        required; exactly SONGYAN_SCRIPT_API_VERSION
 *   // @name <text>                    required
 *   // @description <text>             optional
 *   // @connect <host>                 optional, repeatable; host name only
 *   // @setting <key> <text|url|choice> <label>
 *   // @option <key> <value>           repeatable; the choices of an earlier choice setting
 *   // @timeout <seconds>              optional; how long one run may take, 1 to 600
 *   // @secret <key> <label>
 *   // @input audio                    optional (text input is implicit)
 *
 * The header is the run of leading lines that are blank or start with //; the first other line
 * ends it, so comments in the body are not declarations and non-declaration // lines are notes.
 * Fields are separated by runs of spaces or tabs; name, description and labels are the rest of
 * the line, trimmed. Declarations may appear in any order; single-value declarations, setting or
 * secret keys (unique across both lists) and audio input may not repeat. Unknown @keys are an
 * error. A refusal reports the 1-based source line, or 0 when the problem is a missing required
 * declaration. Setting and secret keys are ASCII letters, digits, '_' and '-'. @connect folds to
 * lowercase and accepts letters, digits, dots and inner hyphens only: no scheme, port, path,
 * wildcard or space. A missing host capability never rejects a file; it is reported separately.
 *
 * A choice setting lists what the user can pick with @option lines after it: at least two,
 * distinct, kept in order, the first being the default. The value is the rest of the line and is
 * both what the user sees and what the script receives. @option for a key that is not an earlier
 * choice setting is an error, and only choice settings take options.
 *
 * @timeout replaces the host's wall-clock duration for this script, because a slow model can
 * legitimately need minutes; the author knows that, the host cannot. It is an unsigned decimal
 * without leading zeros from 1 to SONGYAN_SCRIPT_MAX_TIMEOUT_SECONDS. The compute limit is not
 * affected: a long timeout buys waiting time, never CPU time.
 *
 * @api is an unsigned decimal without leading zeros. Exactly the version this host implements is
 * accepted; a higher one is a file this host refuses with unsupportedApiVersion and never runs;
 * 0, a leading zero or a non-number is a broken header. A version token too large for 64 bits is
 * refused as unsupportedApiVersion as well, and its diagnostic says the number is too large
 * instead of echoing a clipped value. A UTF-8 BOM at the very start of the file is accepted and
 * ignored. The source is external input, so an embedded NUL or an invalid UTF-8 sequence is
 * refused as a broken header before parsing: both would otherwise truncate a declaration or
 * produce a report that JSON parsers reject.
 *
 * Shared cases for both platforms: tests/cases/<name>/expected.json plus an optional
 * capabilities.txt ("text" or "text,audio"; default "text"), and script.js unless the case is fed
 * from examples/<name>.js: the minimal example is a case input, not a copy of one. expected.json
 * is the canonical JSON this implementation prints; a case whose expectation says "ok": false
 * must exit 1. The AI instructions users copy are resources/ai-guide.txt. The cases, the example
 * and that guide belong to the same sync set.
 *
 * Resource limits are injected by the host through songyan_script_limits on every run. The values
 * both apps ship are the SONGYAN_SCRIPT_SHIPPED_* constants below, defined here once so a script
 * that runs on one platform runs on the other; tests inject their own values. */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Interface version this implementation speaks. A script declaring a higher @api is refused with
 * unsupportedApiVersion and never runs; 0, a leading zero or a non-number is a broken header. */
#define SONGYAN_SCRIPT_API_VERSION 1u

/* Every way a script can fail, defined once. Codes are stable across platforms; each platform
 * maps a code to its own user-facing wording and the bridge only supplies a developer
 * diagnostic. HEADER and API_VERSION are produced while parsing the header. TIMEOUT,
 * OUT_OF_MEMORY, ADDRESS_NOT_ALLOWED, NETWORK_FAILURE and SCRIPT belong to the execution layer.
 * CAPABILITY is reported when a run is requested for a script whose declared input the host
 * cannot offer; importing such a file never fails, it is reported separately as unavailable. */
typedef enum {
    SONGYAN_SCRIPT_OK = 0,
    SONGYAN_SCRIPT_ERROR_TIMEOUT,
    SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
    SONGYAN_SCRIPT_ERROR_ADDRESS_NOT_ALLOWED,
    SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
    SONGYAN_SCRIPT_ERROR_SCRIPT,
    SONGYAN_SCRIPT_ERROR_HEADER,
    SONGYAN_SCRIPT_ERROR_API_VERSION,
    SONGYAN_SCRIPT_ERROR_CAPABILITY
} songyan_script_error;

/* Stable machine name, e.g. "badHeader". Used by the shared test cases. */
const char *songyan_script_error_name(songyan_script_error error);

typedef enum {
    SONGYAN_SCRIPT_SETTING_TEXT = 0,
    SONGYAN_SCRIPT_SETTING_URL,
    SONGYAN_SCRIPT_SETTING_CHOICE
} songyan_script_setting_kind;

const char *songyan_script_setting_kind_name(songyan_script_setting_kind kind);

/* Capabilities a host can offer and a header can require. Text is always required; audio only
 * when the header declares @input audio. A missing capability never rejects the import: the
 * script is kept and shown as unavailable on that device, and a run of it is refused with
 * SONGYAN_SCRIPT_ERROR_CAPABILITY. */
typedef enum {
    SONGYAN_SCRIPT_CAPABILITY_TEXT = 1u << 0,
    SONGYAN_SCRIPT_CAPABILITY_AUDIO = 1u << 1
} songyan_script_capability;

const char *songyan_script_capability_name(songyan_script_capability capability);

typedef struct {
    char *key;
    songyan_script_setting_kind kind;
    char *label;
    char **options; /* choice settings only, in declaration order; NULL otherwise */
    size_t option_count;
} songyan_script_setting;

typedef struct {
    char *key;
    char *label;
} songyan_script_secret;

/* A parsed header. Declaration order is kept: the settings page shows it. All strings are
 * UTF-8 and owned by the header until songyan_script_header_free. */
typedef struct {
    unsigned api;
    char *name;
    char *description; /* NULL when the header has none */
    char **connects;
    size_t connect_count;
    songyan_script_setting *settings;
    size_t setting_count;
    songyan_script_secret *secrets;
    size_t secret_count;
    unsigned needs; /* songyan_script_capability bits */
    unsigned timeout_seconds; /* 0 when the header has no @timeout */
} songyan_script_header;

/* The diagnostic buffer is fixed at 256 bytes because this struct is passed by value across the
 * C bridge. A longer declaration text is cut at 255 bytes and message_truncated is set, so a
 * caller can tell the user the report was shortened instead of silently showing half a message. */
typedef struct {
    size_t line; /* 1-based source line; 0 when the problem is not tied to one */
    int message_truncated; /* non-zero when message was cut at the 255-byte limit */
    char message[256]; /* English developer diagnostic; platforms own the user copy */
} songyan_script_header_error;

/* Parses the comment header at the top of source. The header ends at the first line that is
 * neither blank nor a // comment. On any error the returned header is freed and zeroed. */
songyan_script_error songyan_script_header_parse(const char *source, size_t length,
                                                 songyan_script_header *header,
                                                 songyan_script_header_error *error);

void songyan_script_header_free(songyan_script_header *header);

/* Resource limits, injected by the host. The bridge has no defaults: a host that does not set
 * every field cannot run anything. duration_ms bounds the whole run on the wall clock, waiting
 * for the network included; compute_ms bounds only the time the engine spends executing the
 * script, so a busy loop stops quickly while a slow server still gets the full duration. */
typedef struct {
    size_t source_bytes;
    size_t heap_bytes;
    uint32_t duration_ms;
    uint32_t compute_ms;
    uint32_t request_count;
    size_t response_bytes;
    size_t input_text_bytes;
} songyan_script_limits;

/* The limits both apps ship. A language model rewriting a paragraph commonly answers in 5 to 20
 * seconds, so the wall-clock duration leaves room for that; the compute bound stays short because
 * no text tool needs seconds of pure computation. The heap fits the keyboard extension's memory
 * on iOS, which is the tighter of the two platforms. */
#define SONGYAN_SCRIPT_SHIPPED_SOURCE_BYTES 262144u /* 256 KiB */
#define SONGYAN_SCRIPT_SHIPPED_HEAP_BYTES 8388608u /* 8 MiB */
#define SONGYAN_SCRIPT_SHIPPED_DURATION_MS 30000u
#define SONGYAN_SCRIPT_SHIPPED_COMPUTE_MS 4000u
/* The longest a script may ask for with @timeout. */
#define SONGYAN_SCRIPT_MAX_TIMEOUT_SECONDS 600u
#define SONGYAN_SCRIPT_SHIPPED_REQUEST_COUNT 4u
#define SONGYAN_SCRIPT_SHIPPED_RESPONSE_BYTES 65536u /* 64 KiB */
#define SONGYAN_SCRIPT_SHIPPED_INPUT_TEXT_BYTES 65536u /* 64 KiB */

/* Whether a script may reach url, the one address rule both platforms apply to every request and
 * every redirect. Allowed are:
 *   - https to a host the header declares with @connect;
 *   - https to the host of a value the user typed into one of this script's url settings;
 *   - http to such a user-typed host only when it is local: localhost, a *.local name, or a
 *     literal loopback, private or link-local IP address.
 * Everything else is refused: other schemes, URLs with credentials, http to a declared host (an
 * author cannot hard-code cleartext) and any host neither the header nor the user named. Ports
 * are ignored and nothing is resolved through DNS, so the answer depends on the text alone.
 * setting_urls are the user's values of the url settings; empty or unparsable ones are skipped.
 * The shared table tests/address-cases.txt pins this rule for every implementation. */
int songyan_script_address_allowed(const char *url, const songyan_script_header *header,
                                   const char *const *setting_urls, size_t setting_url_count);

/* The wall-clock duration one run of this script gets: its @timeout when declared, otherwise
 * the host's duration_ms. Hosts size their own watchdogs from this, not from duration_ms. */
uint32_t songyan_script_run_duration_ms(const songyan_script_header *header,
                                        const songyan_script_limits *limits);

/* Names of the fields still zero, in declaration order. Returns the number written, which may
 * exceed capacity; call with a NULL array to count. */
size_t songyan_script_limits_missing(const songyan_script_limits *limits,
                                     const char *missing[], size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
