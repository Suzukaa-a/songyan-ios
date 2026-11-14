#include "songyan_script.h"
#include "songyan_script_run.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The command-line runner: it parses the same header the hosts parse, injects limits from the
 * command line (never from compiled-in numbers), runs a script with the script environment and
 * prints the canonical JSON the shared cases expect. Network access comes from a fixture file so
 * the cases describe simulated responses instead of depending on a live server; the real hosts
 * own the transport and the address policy. */

int songyan_script_cli_run(int argc, char **argv);

/* One request the script actually sent, recorded by the test host so the shared cases can check
 * the upload bytes and not only the response. */
typedef struct {
    char *method;
    char *url;
    char *headers_json;
    unsigned char *body;
    size_t body_length;
} recorded_request;

static char *copy_field(const char *text, size_t length);

static void run_usage(FILE *out) {
    fputs("usage:\n"
          "  songyan-script run --script PATH [--script PATH ...] [--text TEXT | --text-file PATH]\n"
          "                     [--settings JSON | --settings-file PATH]\n"
          "                     [--capabilities text[,audio]] [--fetch FILE] [--log-limit N]\n"
          "                     [--host-wait-ms N]\n"
          "                     [--shipped-limits] --source-bytes N --heap-bytes N\n"
          "                     --duration-ms N --compute-ms N --request-count N\n"
          "                     --response-bytes N --input-text-bytes N\n"
          "\n"
          "run executes each script once, in a fresh engine, and prints one JSON report (or one\n"
          "report per --script under runs). --shipped-limits starts from the limits both apps\n"
          "ship; a limit flag after it overrides one value. A fetch fixture line grants or denies\n"
          "an address and describes the response the next call receives.\n",
          out);
}

static void write_indent(FILE *out, int indent) {
    for (int index = 0; index < indent; index++) {
        fputc(' ', out);
    }
}

static void write_json_string(FILE *out, const char *text, size_t length) {
    fputc('"', out);
    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)text[index];
        switch (character) {
        case '"':
            fputs("\\\"", out);
            break;
        case '\\':
            fputs("\\\\", out);
            break;
        case '\n':
            fputs("\\n", out);
            break;
        case '\r':
            fputs("\\r", out);
            break;
        case '\t':
            fputs("\\t", out);
            break;
        default:
            if (character < 0x20) {
                fprintf(out, "\\u%04x", character);
            } else {
                fputc(character, out);
            }
            break;
        }
    }
    fputc('"', out);
}

static void write_json_string_z(FILE *out, const char *text) {
    write_json_string(out, text, strlen(text));
}

static void emit_strings(FILE *out, char **items, size_t *lengths, size_t count, int indent) {
    if (count == 0) {
        fputs("[]", out);
        return;
    }
    fputs("[\n", out);
    for (size_t index = 0; index < count; index++) {
        write_indent(out, indent + 2);
        write_json_string(out, items[index],
                          lengths == NULL ? strlen(items[index]) : lengths[index]);
        fputs(index + 1 < count ? ",\n" : "\n", out);
    }
    write_indent(out, indent);
    fputc(']', out);
}

static const char kBase64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void write_base64(FILE *out, const unsigned char *bytes, size_t length) {
    for (size_t index = 0; index < length; index += 3) {
        size_t remaining = length - index;
        unsigned value = (unsigned)bytes[index] << 16;
        if (remaining > 1) {
            value |= (unsigned)bytes[index + 1] << 8;
        }
        if (remaining > 2) {
            value |= (unsigned)bytes[index + 2];
        }
        fputc(kBase64Alphabet[(value >> 18) & 0x3F], out);
        fputc(kBase64Alphabet[(value >> 12) & 0x3F], out);
        fputc(remaining > 1 ? kBase64Alphabet[(value >> 6) & 0x3F] : '=', out);
        fputc(remaining > 2 ? kBase64Alphabet[value & 0x3F] : '=', out);
    }
}

static int bytes_are_utf8(const unsigned char *bytes, size_t length) {
    size_t index = 0;
    while (index < length) {
        unsigned char lead = bytes[index];
        size_t need = 0;
        if (lead <= 0x7F) {
            index++;
            continue;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            need = 1;
        } else if (lead >= 0xE0 && lead <= 0xEF) {
            need = 2;
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            need = 3;
        } else {
            return 0;
        }
        if (index + need >= length) {
            return 0;
        }
        for (size_t step = 1; step <= need; step++) {
            if ((bytes[index + step] & 0xC0) != 0x80) {
                return 0;
            }
        }
        index += need + 1;
    }
    return 1;
}

/* Returns the multipart boundary declared in the request headers, or NULL. */
static char *multipart_boundary(const char *headers_json) {
    if (headers_json == NULL || strstr(headers_json, "multipart/form-data") == NULL) {
        return NULL;
    }
    const char *marker = strstr(headers_json, "boundary=");
    if (marker == NULL) {
        return NULL;
    }
    marker += strlen("boundary=");
    size_t length = 0;
    while (marker[length] != '\0' && marker[length] != '"' && marker[length] != ';' &&
           marker[length] != '}' && marker[length] != ' ') {
        length++;
    }
    return length == 0 ? NULL : copy_field(marker, length);
}

static const unsigned char *find_bytes(const unsigned char *haystack, size_t haystack_length,
                                       const unsigned char *needle, size_t needle_length,
                                       size_t from) {
    if (needle_length == 0 || haystack_length < needle_length) {
        return NULL;
    }
    for (size_t index = from; index + needle_length <= haystack_length; index++) {
        if (memcmp(haystack + index, needle, needle_length) == 0) {
            return haystack + index;
        }
    }
    return NULL;
}

static void emit_multipart_parts(FILE *out, const recorded_request *request, const char *boundary,
                                 int indent) {
    size_t boundary_length = strlen(boundary);
    unsigned char *delimiter = malloc(boundary_length + 2);
    if (delimiter == NULL) {
        fputs("[]", out);
        return;
    }
    delimiter[0] = '-';
    delimiter[1] = '-';
    memcpy(delimiter + 2, boundary, boundary_length);
    size_t delimiter_length = boundary_length + 2;
    int first = 1;
    size_t offset = 0;
    fputs("[\n", out);
    for (;;) {
        const unsigned char *start = find_bytes(request->body, request->body_length, delimiter,
                                                delimiter_length, offset);
        if (start == NULL) {
            break;
        }
        size_t position = (size_t)(start - request->body) + delimiter_length;
        if (position + 2 <= request->body_length && request->body[position] == '-' &&
            request->body[position + 1] == '-') {
            break;
        }
        if (position + 2 <= request->body_length && request->body[position] == '\r' &&
            request->body[position + 1] == '\n') {
            position += 2;
        }
        const unsigned char *headers_end = find_bytes(request->body, request->body_length,
                                                      (const unsigned char *)"\r\n\r\n", 4,
                                                      position);
        if (headers_end == NULL) {
            break;
        }
        size_t value_start = (size_t)(headers_end - request->body) + 4;
        const unsigned char *next = find_bytes(request->body, request->body_length, delimiter,
                                              delimiter_length, value_start);
        if (next == NULL) {
            break;
        }
        size_t value_end = (size_t)(next - request->body);
        if (value_end >= 2 && request->body[value_end - 2] == '\r' &&
            request->body[value_end - 1] == '\n') {
            value_end -= 2;
        }
        char *name = NULL;
        const unsigned char *name_at = find_bytes(request->body, (size_t)(headers_end - request->body),
                                                  (const unsigned char *)"name=\"", 6, position);
        if (name_at != NULL) {
            const unsigned char *name_start = name_at + 6;
            const unsigned char *name_end = find_bytes(name_start,
                                                       (size_t)(headers_end - name_start),
                                                       (const unsigned char *)"\"", 1, 0);
            if (name_end != NULL) {
                name = copy_field((const char *)name_start, (size_t)(name_end - name_start));
            }
        }
        if (!first) {
            fputs(",\n", out);
        }
        first = 0;
        write_indent(out, indent + 2);
        fputs("{\n", out);
        write_indent(out, indent + 4);
        fputs("\"name\": ", out);
        if (name == NULL) {
            fputs("null", out);
        } else {
            write_json_string_z(out, name);
        }
        fputs(",\n", out);
        write_indent(out, indent + 4);
        if (bytes_are_utf8(request->body + value_start, value_end - value_start)) {
            fputs("\"value\": ", out);
            write_json_string(out, (const char *)request->body + value_start,
                              value_end - value_start);
        } else {
            fputs("\"valueBase64\": \"", out);
            write_base64(out, request->body + value_start, value_end - value_start);
            fputc('"', out);
        }
        fputc('\n', out);
        write_indent(out, indent + 2);
        fputc('}', out);
        free(name);
        offset = value_end;
    }
    fputc('\n', out);
    write_indent(out, indent);
    fputc(']', out);
    free(delimiter);
}

/* Prints what the script actually sent: method, URL, headers and the upload bytes. Multipart
 * bodies are parsed into their named fields (the boundary is random, so it is normalised in the
 * headers); other bodies are shown as text when they are UTF-8 and as base64 otherwise. */
static void emit_requests(FILE *out, recorded_request *requests, size_t count, int truncated,
                          int indent) {
    fputs("[\n", out);
    for (size_t index = 0; index < count; index++) {
        recorded_request *request = &requests[index];
        char *boundary = multipart_boundary(request->headers_json);
        write_indent(out, indent + 2);
        fputs("{\n", out);
        write_indent(out, indent + 4);
        fputs("\"method\": ", out);
        write_json_string_z(out, request->method);
        fputs(",\n", out);
        write_indent(out, indent + 4);
        fputs("\"url\": ", out);
        write_json_string_z(out, request->url);
        fputs(",\n", out);
        write_indent(out, indent + 4);
        fputs("\"headers\": ", out);
        if (request->headers_json == NULL) {
            fputs("null", out);
        } else if (boundary == NULL) {
            write_json_string_z(out, request->headers_json);
        } else {
            char *scrubbed = copy_field(request->headers_json, strlen(request->headers_json));
            if (scrubbed == NULL) {
                fputs("null", out);
            } else {
                size_t boundary_length = strlen(boundary);
                char *at = strstr(scrubbed, boundary);
                while (at != NULL) {
                    memset(at, 'X', boundary_length);
                    at = strstr(at + boundary_length, boundary);
                }
                write_json_string_z(out, scrubbed);
                free(scrubbed);
            }
        }
        fputs(",\n", out);
        write_indent(out, indent + 4);
        fprintf(out, "\"bodyLength\": %zu", request->body_length);
        if (boundary != NULL) {
            fputs(",\n", out);
            write_indent(out, indent + 4);
            fputs("\"parts\": ", out);
            emit_multipart_parts(out, request, boundary, indent + 4);
        } else if (request->body_length > 0) {
            if (bytes_are_utf8(request->body, request->body_length)) {
                fputs(",\n", out);
                write_indent(out, indent + 4);
                fputs("\"body\": ", out);
                write_json_string(out, (const char *)request->body, request->body_length);
            } else {
                fputs(",\n", out);
                write_indent(out, indent + 4);
                fputs("\"bodyBase64\": \"", out);
                write_base64(out, request->body, request->body_length);
                fputc('"', out);
            }
        }
        fputc('\n', out);
        write_indent(out, indent + 2);
        fputc('}', out);
        free(boundary);
        if (index + 1 < count) {
            fputc(',', out);
        }
        fputc('\n', out);
    }
    if (truncated) {
        write_indent(out, indent + 2);
        fputs("{\"truncated\": true}\n", out);
    }
    write_indent(out, indent);
    fputc(']', out);
}

static void emit_report(FILE *out, const songyan_script_run_result *result, char **logs,
                        size_t *log_lengths, size_t log_count, int logs_truncated,
                        recorded_request *requests, size_t request_count,
                        int requests_truncated, int indent) {
    write_indent(out, indent);
    fputs("{\n", out);
    if (result->error == SONGYAN_SCRIPT_OK) {
        write_indent(out, indent + 2);
        fputs("\"ok\": true,\n", out);
        write_indent(out, indent + 2);
        fputs("\"outputs\": ", out);
        emit_strings(out, result->outputs, result->output_lengths, result->output_count,
                     indent + 2);
        fputs(",\n", out);
        write_indent(out, indent + 2);
        fputs("\"logs\": ", out);
        emit_strings(out, logs, log_lengths, log_count, indent + 2);
        fputs(",\n", out);
        write_indent(out, indent + 2);
        fprintf(out, "\"logsTruncated\": %s", logs_truncated ? "true" : "false");
        if (request_count > 0 || requests_truncated) {
            fputs(",\n", out);
            write_indent(out, indent + 2);
            fputs("\"requests\": ", out);
            emit_requests(out, requests, request_count, requests_truncated, indent + 2);
        }
        fputc('\n', out);
    } else {
        write_indent(out, indent + 2);
        fputs("\"ok\": false,\n", out);
        write_indent(out, indent + 2);
        fputs("\"error\": ", out);
        write_json_string_z(out, songyan_script_error_name(result->error));
        fputs(",\n", out);
        write_indent(out, indent + 2);
        fputs("\"message\": ", out);
        write_json_string_z(out, result->message);
        fputs(",\n", out);
        write_indent(out, indent + 2);
        fprintf(out, "\"line\": %zu\n", result->line);
    }
    write_indent(out, indent);
    fputc('}', out);
}

static void emit_invalid_report(FILE *out, const char *message, int indent) {
    write_indent(out, indent);
    fputs("{\n", out);
    write_indent(out, indent + 2);
    fputs("\"ok\": false,\n", out);
    write_indent(out, indent + 2);
    fputs("\"cliError\": \"invalidRun\",\n", out);
    write_indent(out, indent + 2);
    fputs("\"message\": ", out);
    write_json_string_z(out, message);
    fputc('\n', out);
    write_indent(out, indent);
    fputc('}', out);
}

static int emit_header_error(songyan_script_error code, const songyan_script_header_error *error,
                             int indent) {
    write_indent(stdout, indent);
    fputs("{\n", stdout);
    write_indent(stdout, indent + 2);
    fputs("\"ok\": false,\n", stdout);
    write_indent(stdout, indent + 2);
    fputs("\"error\": ", stdout);
    write_json_string_z(stdout, songyan_script_error_name(code));
    fputs(",\n", stdout);
    write_indent(stdout, indent + 2);
    fprintf(stdout, "\"line\": %zu,\n", error == NULL ? (size_t)0 : error->line);
    write_indent(stdout, indent + 2);
    fputs("\"message\": ", stdout);
    write_json_string_z(stdout, error == NULL ? "" : error->message);
    if (error != NULL && error->message_truncated) {
        fputs(",\n", stdout);
        write_indent(stdout, indent + 2);
        fputs("\"messageTruncated\": true", stdout);
    }
    fputc('\n', stdout);
    write_indent(stdout, indent);
    fputc('}', stdout);
    return code == SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY ? 70 : 1;
}

static char *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size < 0) {
        fclose(file);
        return NULL;
    }
    rewind(file);
    char *data = malloc((size_t)size + 1);
    if (data == NULL) {
        fclose(file);
        return NULL;
    }
    size_t read = fread(data, 1, (size_t)size, file);
    fclose(file);
    data[read] = '\0';
    *length = read;
    return data;
}

static int parse_size(const char *text, size_t *value) {
    if (*text == '\0') {
        return 0;
    }
    size_t parsed = 0;
    for (const char *cursor = text; *cursor != '\0'; cursor++) {
        if (*cursor < '0' || *cursor > '9') {
            return 0;
        }
        size_t digit = (size_t)(*cursor - '0');
        if (parsed > (SIZE_MAX - digit) / 10) {
            return 0;
        }
        parsed = parsed * 10 + digit;
    }
    if (parsed == 0) {
        return 0;
    }
    *value = parsed;
    return 1;
}

static int parse_capabilities(const char *list, unsigned *capabilities) {
    unsigned value = 0;
    const char *cursor = list;
    for (;;) {
        const char *comma = strchr(cursor, ',');
        size_t length = comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
        if (length == 4 && memcmp(cursor, "text", 4) == 0) {
            value |= SONGYAN_SCRIPT_CAPABILITY_TEXT;
        } else if (length == 5 && memcmp(cursor, "audio", 5) == 0) {
            value |= SONGYAN_SCRIPT_CAPABILITY_AUDIO;
        } else {
            return 0;
        }
        if (comma == NULL) {
            break;
        }
        cursor = comma + 1;
    }
    *capabilities = value;
    return 1;
}

static int base64_value(char character) {
    if (character >= 'A' && character <= 'Z') {
        return character - 'A';
    }
    if (character >= 'a' && character <= 'z') {
        return character - 'a' + 26;
    }
    if (character >= '0' && character <= '9') {
        return character - '0' + 52;
    }
    if (character == '+') {
        return 62;
    }
    if (character == '/') {
        return 63;
    }
    return -1;
}

static unsigned char *base64_decode(const char *text, size_t *length) {
    size_t text_length = strlen(text);
    unsigned char *bytes = malloc(text_length / 4 * 3 + 4);
    if (bytes == NULL) {
        return NULL;
    }
    size_t written = 0;
    int accumulator = 0;
    int bits = 0;
    for (size_t index = 0; index < text_length; index++) {
        if (text[index] == '=') {
            break;
        }
        int value = base64_value(text[index]);
        if (value < 0) {
            free(bytes);
            return NULL;
        }
        accumulator = (accumulator << 6) | value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes[written++] = (unsigned char)((accumulator >> bits) & 0xFF);
        }
    }
    *length = written;
    return bytes;
}

typedef struct {
    int is_error;
    int deferred;
    char *error_message;
    unsigned status;
    char *content_type;
    char *final_url;
    unsigned char *body;
    size_t body_length;
    /* "oversize" declares a length without providing bytes, so a case can prove the bridge rejects
     * an over-limit response before copying it. */
    size_t declared_length;
} canned_response;

typedef struct {
    char **allowed;
    size_t allowed_count;
    char **denied;
    size_t denied_count;
    canned_response *responses;
    size_t response_count;
    size_t response_index;
    const canned_response *deferred_response;
    uint64_t deferred_id;
    /* console lines are host-owned by design; this harness keeps up to log_limit bytes and says
     * in the report when it stopped instead of dropping the rest silently. */
    char **logs;
    size_t *log_lengths;
    size_t log_count;
    size_t log_capacity;
    size_t log_bytes;
    size_t log_limit;
    int logs_truncated;
    /* How long the host waits before answering any request, synchronously or deferred. */
    size_t wait_ms;
    /* The upload bytes are part of what the shared cases verify, so the host records what the
     * script actually sent instead of only echoing a response. */
    recorded_request *requests;
    size_t request_count;
    size_t request_capacity;
    int requests_truncated;
} fake_host;

static void canned_release(canned_response *response) {
    free(response->error_message);
    free(response->content_type);
    free(response->final_url);
    free(response->body);
    memset(response, 0, sizeof(*response));
}

static void fake_host_release(fake_host *host) {
    for (size_t index = 0; index < host->allowed_count; index++) {
        free(host->allowed[index]);
    }
    free(host->allowed);
    for (size_t index = 0; index < host->denied_count; index++) {
        free(host->denied[index]);
    }
    free(host->denied);
    for (size_t index = 0; index < host->response_count; index++) {
        canned_release(&host->responses[index]);
    }
    free(host->responses);
    for (size_t index = 0; index < host->log_count; index++) {
        free(host->logs[index]);
    }
    free(host->logs);
    free(host->log_lengths);
    for (size_t index = 0; index < host->request_count; index++) {
        free(host->requests[index].method);
        free(host->requests[index].url);
        free(host->requests[index].headers_json);
        free(host->requests[index].body);
    }
    free(host->requests);
    memset(host, 0, sizeof(*host));
}

static int append_string(char ***items, size_t *count, const char *text, size_t length) {
    char **grown = realloc(*items, (*count + 1) * sizeof(**items));
    if (grown == NULL) {
        return 0;
    }
    *items = grown;
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, text, length);
    copy[length] = '\0';
    (*items)[(*count)++] = copy;
    return 1;
}

static char *trim_range(const char *start, const char *end) {
    while (start < end && (*start == ' ' || *start == '\t')) {
        start++;
    }
    while (end > start && (end[-1] == ' ' || end[-1] == '\t')) {
        end--;
    }
    char *copy = malloc((size_t)(end - start) + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, start, (size_t)(end - start));
    copy[end - start] = '\0';
    return copy;
}

static const char *next_token(const char *cursor, const char *end, char **token) {
    while (cursor < end && (*cursor == ' ' || *cursor == '\t')) {
        cursor++;
    }
    if (cursor >= end) {
        *token = NULL;
        return NULL;
    }
    const char *start = cursor;
    while (cursor < end && *cursor != ' ' && *cursor != '\t') {
        cursor++;
    }
    *token = trim_range(start, cursor);
    return cursor;
}

/* Fixture grammar, one entry per line:
 *
 *   allow <url>                                  authorize this exact URL
 *   deny <url>                                   refuse it even if an allow line matches
 *   response <status> <content-type> <base64|-> [final-url|-]
 *   deferred <status> <content-type> <base64|-> [final-url|-]
 *   oversize <status> <content-type> <bytes>     declares an over-limit body without bytes
 *   error <message...>                           the transport fails
 *
 * A URL is allowed only when it matches an allow line; the bridge also asks about a reported
 * redirect target, so a redirect needs its own allow line. Responses are consumed in file order,
 * one per submitted fetch; "deferred" makes the call return pending and complete on the next
 * step, which exercises the asynchronous path without a network. */
static int load_fixture(const char *path, fake_host *host, char *error, size_t error_size) {
    size_t length = 0;
    char *data = read_file(path, &length);
    if (data == NULL) {
        snprintf(error, error_size, "cannot read fetch fixture %s", path);
        return 0;
    }
    size_t line_number = 0;
    size_t offset = 0;
    int ok = 1;
    while (offset <= length) {
        size_t line_end = offset;
        while (line_end < length && data[line_end] != '\n') {
            line_end++;
        }
        size_t text_end = line_end;
        if (text_end > offset && data[text_end - 1] == '\r') {
            text_end--;
        }
        line_number++;
        /* Copy the line so the token helpers can write into it. */
        char *line = trim_range(data + offset, data + text_end);
        offset = line_end + 1;
        if (line == NULL) {
            ok = 0;
            break;
        }
        if (line[0] == '\0' || line[0] == '#') {
            free(line);
            if (line_end >= length) {
                break;
            }
            continue;
        }
        char *cursor = line;
        char *keyword = NULL;
        const char *after = next_token(cursor, line + strlen(line), &keyword);
        if (keyword == NULL || after == NULL) {
            snprintf(error, error_size, "fixture line %zu has no value", line_number);
            free(line);
            ok = 0;
            break;
        }
        if (strcmp(keyword, "allow") == 0) {
            char *value = trim_range(after, line + strlen(line));
            if (value == NULL || !append_string(&host->allowed, &host->allowed_count, value,
                                                strlen(value))) {
                free(value);
                free(line);
                ok = 0;
                break;
            }
            free(value);
        } else if (strcmp(keyword, "deny") == 0) {
            char *value = trim_range(after, line + strlen(line));
            if (value == NULL || !append_string(&host->denied, &host->denied_count, value,
                                                strlen(value))) {
                free(value);
                free(line);
                ok = 0;
                break;
            }
            free(value);
        } else if (strcmp(keyword, "error") == 0) {
            canned_response *grown = realloc(host->responses,
                                             (host->response_count + 1) * sizeof(*grown));
            if (grown == NULL) {
                free(line);
                ok = 0;
                break;
            }
            host->responses = grown;
            canned_response *response = &host->responses[host->response_count++];
            memset(response, 0, sizeof(*response));
            response->is_error = 1;
            response->error_message = trim_range(after, line + strlen(line));
            if (response->error_message == NULL) {
                free(line);
                ok = 0;
                break;
            }
        } else if (strcmp(keyword, "oversize") == 0) {
            const char *position = after;
            const char *line_end_pointer = line + strlen(line);
            char *status_text = NULL;
            char *type_text = NULL;
            char *length_text = NULL;
            position = next_token(position, line_end_pointer, &status_text);
            position = position == NULL ? NULL
                                        : next_token(position, line_end_pointer, &type_text);
            position = position == NULL ? NULL
                                        : next_token(position, line_end_pointer, &length_text);
            size_t parsed_status = 0;
            size_t declared_length = 0;
            if (status_text == NULL || type_text == NULL || length_text == NULL ||
                !parse_size(status_text, &parsed_status) || parsed_status > 999 ||
                !parse_size(length_text, &declared_length)) {
                snprintf(error, error_size, "fixture line %zu is not an oversize response",
                         line_number);
                free(status_text);
                free(type_text);
                free(length_text);
                free(line);
                ok = 0;
                break;
            }
            canned_response *grown = realloc(host->responses,
                                             (host->response_count + 1) * sizeof(*grown));
            if (grown == NULL) {
                free(status_text);
                free(type_text);
                free(length_text);
                free(line);
                ok = 0;
                break;
            }
            host->responses = grown;
            canned_response *response = &host->responses[host->response_count++];
            memset(response, 0, sizeof(*response));
            response->status = (unsigned)parsed_status;
            response->content_type = type_text;
            response->declared_length = declared_length;
            free(status_text);
            free(length_text);
            free(line);
            continue;
        } else if (strcmp(keyword, "response") == 0 || strcmp(keyword, "deferred") == 0) {
            int deferred = strcmp(keyword, "deferred") == 0;
            const char *position = after;
            const char *line_end_pointer = line + strlen(line);
            char *status_text = NULL;
            char *type_text = NULL;
            char *body_text = NULL;
            position = next_token(position, line_end_pointer, &status_text);
            position = position == NULL ? NULL
                                        : next_token(position, line_end_pointer, &type_text);
            position = position == NULL ? NULL
                                        : next_token(position, line_end_pointer, &body_text);
            size_t parsed_status = 0;
            if (status_text == NULL || type_text == NULL || body_text == NULL ||
                !parse_size(status_text, &parsed_status) || parsed_status > 999) {
                snprintf(error, error_size, "fixture line %zu is not a response", line_number);
                free(status_text);
                free(type_text);
                free(body_text);
                free(line);
                ok = 0;
                break;
            }
            canned_response *grown = realloc(host->responses,
                                             (host->response_count + 1) * sizeof(*grown));
            if (grown == NULL) {
                free(status_text);
                free(type_text);
                free(body_text);
                free(line);
                ok = 0;
                break;
            }
            host->responses = grown;
            canned_response *response = &host->responses[host->response_count++];
            memset(response, 0, sizeof(*response));
            response->deferred = deferred;
            response->status = (unsigned)parsed_status;
            response->content_type = type_text;
            if (strcmp(body_text, "-") != 0) {
                response->body = base64_decode(body_text, &response->body_length);
                if (response->body == NULL) {
                    snprintf(error, error_size, "fixture line %zu has invalid base64",
                             line_number);
                    free(status_text);
                    free(body_text);
                    free(line);
                    ok = 0;
                    break;
                }
            }
            free(status_text);
            free(body_text);
            char *final_text = position == NULL ? NULL
                                                : trim_range(position, line_end_pointer);
            if (final_text != NULL && strcmp(final_text, "-") != 0 && final_text[0] != '\0') {
                response->final_url = final_text;
                final_text = NULL;
            }
            free(final_text);
        } else {
            snprintf(error, error_size, "fixture line %zu has an unknown keyword %s", line_number,
                     keyword);
            free(keyword);
            free(line);
            ok = 0;
            break;
        }
        free(keyword);
        free(line);
        if (line_end >= length) {
            break;
        }
    }
    free(data);
    return ok;
}

static int fixture_url_allowed(const fake_host *host, const char *url) {
    for (size_t index = 0; index < host->denied_count; index++) {
        if (strcmp(host->denied[index], url) == 0) {
            return 0;
        }
    }
    for (size_t index = 0; index < host->allowed_count; index++) {
        if (strcmp(host->allowed[index], url) == 0) {
            return 1;
        }
    }
    return 0;
}

static songyan_script_address_decision fake_authorize(void *userdata, const char *url,
                                                      songyan_script_fetch_phase phase) {
    (void)phase;
    fake_host *host = userdata;
    return fixture_url_allowed(host, url) ? SONGYAN_SCRIPT_ADDRESS_ALLOWED
                                          : SONGYAN_SCRIPT_ADDRESS_DENIED;
}

static char *copy_field(const char *text, size_t length) {
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    if (length > 0) {
        memcpy(copy, text, length);
    }
    copy[length] = '\0';
    return copy;
}

static int fake_host_record_request(fake_host *host, const songyan_script_fetch_request *request) {
    if (host->request_count == host->request_capacity) {
        size_t next = host->request_capacity == 0 ? 4 : host->request_capacity * 2;
        recorded_request *grown = realloc(host->requests, next * sizeof(*grown));
        if (grown == NULL) {
            return 0;
        }
        host->requests = grown;
        host->request_capacity = next;
    }
    recorded_request *record = &host->requests[host->request_count];
    memset(record, 0, sizeof(*record));
    record->method = copy_field(request->method, strlen(request->method));
    record->url = copy_field(request->url, strlen(request->url));
    record->headers_json = request->headers_json == NULL
                               ? NULL
                               : copy_field(request->headers_json, strlen(request->headers_json));
    if (request->body != NULL && request->body_length > 0) {
        record->body = malloc(request->body_length);
        if (record->body == NULL) {
            free(record->method);
            free(record->url);
            free(record->headers_json);
            memset(record, 0, sizeof(*record));
            return 0;
        }
        memcpy(record->body, request->body, request->body_length);
        record->body_length = request->body_length;
    }
    if (record->method == NULL || record->url == NULL ||
        (request->headers_json != NULL && record->headers_json == NULL)) {
        free(record->method);
        free(record->url);
        free(record->headers_json);
        free(record->body);
        memset(record, 0, sizeof(*record));
        return 0;
    }
    host->request_count++;
    return 1;
}

static int fake_host_append_log(fake_host *host, const char *text, size_t length) {
    if (host->logs_truncated) {
        return 1;
    }
    if (host->log_bytes + length > host->log_limit) {
        host->logs_truncated = 1;
        return 1;
    }
    if (host->log_count == host->log_capacity) {
        size_t next = host->log_capacity == 0 ? 8 : host->log_capacity * 2;
        size_t *grown_lengths = realloc(host->log_lengths, next * sizeof(*grown_lengths));
        if (grown_lengths == NULL) {
            return 0;
        }
        host->log_lengths = grown_lengths;
        char **grown = realloc(host->logs, next * sizeof(*grown));
        if (grown == NULL) {
            return 0;
        }
        host->logs = grown;
        host->log_capacity = next;
    }
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, text, length);
    copy[length] = '\0';
    host->logs[host->log_count] = copy;
    host->log_lengths[host->log_count] = length;
    host->log_count++;
    host->log_bytes += length;
    return 1;
}

static void fake_log(void *userdata, const char *text, size_t length) {
    fake_host *host = userdata;
    if (!fake_host_append_log(host, text, length)) {
        host->logs_truncated = 1;
    }
}

static songyan_script_fetch_action fake_fetch(void *userdata, songyan_script_run *run,
                                              const songyan_script_fetch_request *request,
                                              songyan_script_fetch_response *response,
                                              const char **error_message) {
    (void)run;
    fake_host *host = userdata;
    if (!fake_host_record_request(host, request)) {
        host->requests_truncated = 1;
    }
    if (host->response_index >= host->response_count) {
        *error_message = "the fixture has no response for this request";
        return SONGYAN_SCRIPT_FETCH_REJECTED;
    }
    canned_response *canned = &host->responses[host->response_index++];
    if (host->wait_ms > 0 && !canned->deferred) {
        /* Stands in for a slow server answered synchronously, as both apps' hosts do. */
        struct timespec wait = {(time_t)(host->wait_ms / 1000),
                                (long)(host->wait_ms % 1000) * 1000000L};
        nanosleep(&wait, NULL);
    }
    if (canned->is_error) {
        *error_message = canned->error_message;
        return SONGYAN_SCRIPT_FETCH_REJECTED;
    }
    if (canned->deferred) {
        host->deferred_response = canned;
        host->deferred_id = request->id;
        return SONGYAN_SCRIPT_FETCH_PENDING;
    }
    if (canned->declared_length > 0) {
        response->status = canned->status;
        response->body = NULL;
        response->body_length = canned->declared_length;
        response->content_type = canned->content_type;
        return SONGYAN_SCRIPT_FETCH_ACCEPTED;
    }
    response->status = canned->status;
    response->body = canned->body;
    response->body_length = canned->body_length;
    response->content_type = canned->content_type;
    response->final_url = canned->final_url;
    return SONGYAN_SCRIPT_FETCH_ACCEPTED;
}

typedef struct {
    const char *source;
    size_t source_length;
    const songyan_script_header *header;
    unsigned host_capabilities;
    songyan_script_limits limits;
    const char *settings_json;
    const char *text;
    size_t text_length;
    const char *fixture_path;
    size_t log_limit;
    int cancel_pending;
    size_t host_wait_ms;
} run_options;

/* Runs one script and fills the result. Returns the process status this run deserves. */
static int run_one(const run_options *options, songyan_script_run_result *result,
                   songyan_script_step *step_out, char ***logs_out, size_t **log_lengths_out,
                   size_t *log_count_out, int *logs_truncated_out,
                   recorded_request **requests_out, size_t *request_count_out,
                   int *requests_truncated_out) {
    fake_host host;
    memset(&host, 0, sizeof(host));
    host.wait_ms = options->host_wait_ms;
    host.log_limit = options->log_limit;
    char fixture_error[256];
    if (options->fixture_path != NULL &&
        !load_fixture(options->fixture_path, &host, fixture_error, sizeof(fixture_error))) {
        fprintf(stderr, "songyan-script: %s\n", fixture_error);
        fake_host_release(&host);
        return 64;
    }
    songyan_script_run_config config;
    memset(&config, 0, sizeof(config));
    config.source = options->source;
    config.source_length = options->source_length;
    config.header = options->header;
    config.host_capabilities = options->host_capabilities;
    config.limits = &options->limits;
    config.settings_json = options->settings_json;
    config.text = options->text;
    config.text_length = options->text_length;
    config.host.userdata = &host;
    config.host.authorize = fake_authorize;
    config.host.fetch = fake_fetch;
    config.host.log = fake_log;
    songyan_script_run *run = songyan_script_run_create(&config);
    if (run == NULL) {
        fprintf(stderr, "songyan-script: out of memory\n");
        fake_host_release(&host);
        return 70;
    }
    songyan_script_step step = SONGYAN_SCRIPT_STEP_RUNNING;
    for (;;) {
        step = songyan_script_run_step(run);
        if (step == SONGYAN_SCRIPT_STEP_PENDING) {
            if (options->cancel_pending) {
                songyan_script_run_cancel(run);
                continue;
            }
            if (options->host_wait_ms > 0) {
                /* Stands in for a slow server answered later, as a pending request. */
                struct timespec wait = {(time_t)(options->host_wait_ms / 1000),
                                        (long)(options->host_wait_ms % 1000) * 1000000L};
                nanosleep(&wait, NULL);
            }
            const canned_response *deferred = host.deferred_response;
            if (deferred == NULL) {
                fprintf(stderr, "songyan-script: the fixture host left a request pending\n");
                songyan_script_run_destroy(run);
                fake_host_release(&host);
                return 70;
            }
            songyan_script_fetch_response response;
            memset(&response, 0, sizeof(response));
            response.status = deferred->status;
            response.body = deferred->body;
            response.body_length = deferred->body_length;
            response.content_type = deferred->content_type;
            response.final_url = deferred->final_url;
            if (!songyan_script_run_complete_fetch(run, host.deferred_id, &response)) {
                fprintf(stderr, "songyan-script: the fixture could not complete request %llu\n",
                        (unsigned long long)host.deferred_id);
                songyan_script_run_destroy(run);
                fake_host_release(&host);
                return 70;
            }
            host.deferred_response = NULL;
            continue;
        }
        if (step == SONGYAN_SCRIPT_STEP_RUNNING) {
            continue;
        }
        break;
    }
    memset(result, 0, sizeof(*result));
    songyan_script_run_result_take(run, result);
    songyan_script_run_destroy(run);
    *logs_out = host.logs;
    *log_lengths_out = host.log_lengths;
    *log_count_out = host.log_count;
    *logs_truncated_out = host.logs_truncated;
    *requests_out = host.requests;
    *request_count_out = host.request_count;
    *requests_truncated_out = host.requests_truncated;
    host.requests = NULL;
    host.request_count = 0;
    host.logs = NULL;
    host.log_lengths = NULL;
    host.log_count = 0;
    fake_host_release(&host);
    *step_out = step;
    if (step == SONGYAN_SCRIPT_STEP_DONE) {
        return 0;
    }
    if (step == SONGYAN_SCRIPT_STEP_FAILED) {
        return 1;
    }
    return 64;
}

int songyan_script_cli_run(int argc, char **argv) {
    const char *scripts[32];
    size_t script_count = 0;
    const char *text_literal = NULL;
    const char *text_file = NULL;
    const char *settings_literal = NULL;
    const char *settings_file = NULL;
    const char *capability_list = "text";
    const char *fixture_path = NULL;
    size_t log_limit = 1048576;
    int cancel_pending = 0;
    size_t host_wait_ms = 0;
    songyan_script_limits limits;
    memset(&limits, 0, sizeof(limits));
    int index = 0;
    while (index < argc) {
        const char *flag = argv[index];
        if (index + 1 >= argc) {
            run_usage(stderr);
            return 64;
        }
        const char *value = argv[index + 1];
        if (strcmp(flag, "--script") == 0) {
            if (script_count >= sizeof(scripts) / sizeof(scripts[0])) {
                fprintf(stderr, "too many --script arguments\n");
                return 64;
            }
            scripts[script_count++] = value;
        } else if (strcmp(flag, "--text") == 0) {
            text_literal = value;
        } else if (strcmp(flag, "--text-file") == 0) {
            text_file = value;
        } else if (strcmp(flag, "--settings") == 0) {
            settings_literal = value;
        } else if (strcmp(flag, "--settings-file") == 0) {
            settings_file = value;
        } else if (strcmp(flag, "--capabilities") == 0) {
            capability_list = value;
        } else if (strcmp(flag, "--fetch") == 0) {
            fixture_path = value;
        } else if (strcmp(flag, "--host-wait-ms") == 0) {
            if (!parse_size(value, &host_wait_ms)) {
                fprintf(stderr, "invalid value for %s: %s\n", flag, value);
                return 64;
            }
        } else if (strcmp(flag, "--log-limit") == 0) {
            if (!parse_size(value, &log_limit)) {
                fprintf(stderr, "invalid value for %s: %s\n", flag, value);
                return 64;
            }
        } else if (strcmp(flag, "--shipped-limits") == 0) {
            limits.source_bytes = SONGYAN_SCRIPT_SHIPPED_SOURCE_BYTES;
            limits.heap_bytes = SONGYAN_SCRIPT_SHIPPED_HEAP_BYTES;
            limits.duration_ms = SONGYAN_SCRIPT_SHIPPED_DURATION_MS;
            limits.compute_ms = SONGYAN_SCRIPT_SHIPPED_COMPUTE_MS;
            limits.request_count = SONGYAN_SCRIPT_SHIPPED_REQUEST_COUNT;
            limits.response_bytes = SONGYAN_SCRIPT_SHIPPED_RESPONSE_BYTES;
            limits.input_text_bytes = SONGYAN_SCRIPT_SHIPPED_INPUT_TEXT_BYTES;
            index += 1;
            continue;
        } else if (strcmp(flag, "--cancel-pending") == 0) {
            /* A flag without a value: consume it on its own instead of pairing it. */
            cancel_pending = 1;
            index += 1;
            continue;
        } else if (strcmp(flag, "--source-bytes") == 0 ||
                   strcmp(flag, "--heap-bytes") == 0 ||
                   strcmp(flag, "--duration-ms") == 0 ||
                   strcmp(flag, "--compute-ms") == 0 ||
                   strcmp(flag, "--request-count") == 0 ||
                   strcmp(flag, "--response-bytes") == 0 ||
                   strcmp(flag, "--input-text-bytes") == 0) {
            size_t parsed = 0;
            if (!parse_size(value, &parsed)) {
                fprintf(stderr, "invalid value for %s: %s\n", flag, value);
                return 64;
            }
            if (strcmp(flag, "--source-bytes") == 0) {
                limits.source_bytes = parsed;
            } else if (strcmp(flag, "--heap-bytes") == 0) {
                limits.heap_bytes = parsed;
            } else if (strcmp(flag, "--duration-ms") == 0) {
                if (parsed > UINT32_MAX) {
                    fprintf(stderr, "value for %s is out of range\n", flag);
                    return 64;
                }
                limits.duration_ms = (uint32_t)parsed;
            } else if (strcmp(flag, "--compute-ms") == 0) {
                if (parsed > UINT32_MAX) {
                    fprintf(stderr, "value for %s is out of range\n", flag);
                    return 64;
                }
                limits.compute_ms = (uint32_t)parsed;
            } else if (strcmp(flag, "--request-count") == 0) {
                if (parsed > UINT32_MAX) {
                    fprintf(stderr, "value for %s is out of range\n", flag);
                    return 64;
                }
                limits.request_count = (uint32_t)parsed;
            } else if (strcmp(flag, "--response-bytes") == 0) {
                limits.response_bytes = parsed;
            } else {
                limits.input_text_bytes = parsed;
            }
        } else {
            run_usage(stderr);
            return 64;
        }
        index += 2;
    }
    if (script_count == 0) {
        run_usage(stderr);
        return 64;
    }
    if (text_literal != NULL && text_file != NULL) {
        fprintf(stderr, "--text and --text-file cannot be combined\n");
        return 64;
    }
    if (settings_literal != NULL && settings_file != NULL) {
        fprintf(stderr, "--settings and --settings-file cannot be combined\n");
        return 64;
    }
    unsigned host_capabilities = 0;
    if (!parse_capabilities(capability_list, &host_capabilities)) {
        fprintf(stderr, "unknown capability list: %s\n", capability_list);
        return 64;
    }
    char *text_storage = NULL;
    size_t text_length = 0;
    const char *text = NULL;
    if (text_literal != NULL) {
        text = text_literal;
        text_length = strlen(text_literal);
    } else if (text_file != NULL) {
        text_storage = read_file(text_file, &text_length);
        if (text_storage == NULL) {
            fprintf(stderr, "cannot read %s\n", text_file);
            return 64;
        }
        text = text_storage;
    }
    char *settings_storage = NULL;
    const char *settings = settings_literal;
    if (settings_file != NULL) {
        size_t length = 0;
        settings_storage = read_file(settings_file, &length);
        if (settings_storage == NULL) {
            fprintf(stderr, "cannot read %s\n", settings_file);
            free(text_storage);
            return 64;
        }
        settings = settings_storage;
    }
    int status = 0;
    int multi = script_count > 1;
    if (multi) {
        fputs("{\n  \"runs\": [\n", stdout);
    }
    for (size_t script_index = 0; script_index < script_count; script_index++) {
        size_t source_length = 0;
        char *source = read_file(scripts[script_index], &source_length);
        if (source == NULL) {
            fprintf(stderr, "cannot read %s\n", scripts[script_index]);
            status = 64;
            break;
        }
        songyan_script_header header;
        songyan_script_header_error header_error;
        songyan_script_error code =
            songyan_script_header_parse(source, source_length, &header, &header_error);
        if (code != SONGYAN_SCRIPT_OK) {
            if (multi) {
                fprintf(stderr, "the header of %s is refused\n", scripts[script_index]);
            }
            status = emit_header_error(code, &header_error, multi ? 4 : 0);
            fputc('\n', stdout);
            free(source);
            break;
        }
        run_options options;
        memset(&options, 0, sizeof(options));
        options.source = source;
        options.source_length = source_length;
        options.header = &header;
        options.host_capabilities = host_capabilities;
        options.limits = limits;
        options.settings_json = settings;
        options.text = text;
        options.text_length = text_length;
        options.fixture_path = fixture_path;
        options.log_limit = log_limit;
        options.cancel_pending = cancel_pending;
        options.host_wait_ms = host_wait_ms;
        songyan_script_run_result result;
        songyan_script_step step = SONGYAN_SCRIPT_STEP_RUNNING;
        char **logs = NULL;
        size_t *log_lengths = NULL;
        size_t log_count = 0;
        int logs_truncated = 0;
        recorded_request *requests = NULL;
        size_t request_count = 0;
        int requests_truncated = 0;
        int run_status = run_one(&options, &result, &step, &logs, &log_lengths, &log_count,
                                 &logs_truncated, &requests, &request_count,
                                 &requests_truncated);
        if (run_status > status) {
            status = run_status;
        }
        if (step == SONGYAN_SCRIPT_STEP_INVALID || step == SONGYAN_SCRIPT_STEP_CANCELLED) {
            const char *message = result.message;
            if (message[0] == '\0') {
                message = step == SONGYAN_SCRIPT_STEP_CANCELLED ? "the run was cancelled"
                                                               : "the run was refused";
            }
            emit_invalid_report(stdout, message, multi ? 4 : 0);
            if (!multi) {
                fputc('\n', stdout);
            }
        } else {
            emit_report(stdout, &result, logs, log_lengths, log_count, logs_truncated, requests,
                        request_count, requests_truncated, multi ? 4 : 0);
            if (!multi) {
                fputc('\n', stdout);
            }
        }
        for (size_t index = 0; index < log_count; index++) {
            free(logs[index]);
        }
        free(logs);
        free(log_lengths);
        for (size_t index = 0; index < request_count; index++) {
            free(requests[index].method);
            free(requests[index].url);
            free(requests[index].headers_json);
            free(requests[index].body);
        }
        free(requests);
        songyan_script_run_result_free(&result);
        if (multi) {
            fputs(script_index + 1 < script_count ? ",\n" : "\n", stdout);
        }
        songyan_script_header_free(&header);
        free(source);
        if (run_status == 70) {
            break;
        }
    }
    if (multi) {
        fputs("  ],\n", stdout);
        fprintf(stdout, "  \"ok\": %s\n}\n", status == 0 ? "true" : "false");
    }
    free(text_storage);
    free(settings_storage);
    return status;
}
