#include "songyan_script.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Command-line front end for the shared script interface: the header parser, the limit checker
 * and the runner that executes a script with an injected host. The execution layer is run_cli.c;
 * the presence of the engine does not change the contract commands. */

int songyan_script_cli_run(int argc, char **argv);

static void usage(FILE *out) {
    fputs("usage:\n"
          "  songyan-script header --script PATH [--capabilities text[,audio]]\n"
          "  songyan-script limits --source-bytes N --heap-bytes N --duration-ms N\n"
          "                       --request-count N --response-bytes N --input-text-bytes N\n"
          "  songyan-script run --script PATH ...\n"
          "\n"
          "header prints the parsed declarations as JSON and exits 0, or 1 when the header is\n"
          "refused. limits prints the injected limits as JSON and exits 64 when any is missing.\n"
          "run executes a script in a fresh engine; see songyan-script run --help for its flags.\n",
          out);
}

static void write_indent(FILE *out, int indent) {
    for (int index = 0; index < indent; index++) {
        fputc(' ', out);
    }
}

static void write_json_string(FILE *out, const char *text) {
    fputc('"', out);
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor != '\0'; cursor++) {
        switch (*cursor) {
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
            if (*cursor < 0x20) {
                fprintf(out, "\\u%04x", *cursor);
            } else {
                fputc(*cursor, out);
            }
            break;
        }
    }
    fputc('"', out);
}

static void emit_string_array(FILE *out, int indent, const char *const *items, size_t count) {
    if (count == 0) {
        fputs("[]", out);
        return;
    }
    fputs("[\n", out);
    for (size_t index = 0; index < count; index++) {
        write_indent(out, indent + 2);
        write_json_string(out, items[index]);
        fputs(index + 1 < count ? ",\n" : "\n", out);
    }
    write_indent(out, indent);
    fputc(']', out);
}

static void emit_header_report(const songyan_script_header *header, unsigned host_capabilities) {
    printf("{\n");
    printf("  \"ok\": true,\n");
    printf("  \"error\": \"ok\",\n");
    printf("  \"line\": 0,\n");
    printf("  \"header\": {\n");
    printf("    \"api\": %u,\n", header->api);
    printf("    \"name\": ");
    write_json_string(stdout, header->name);
    printf(",\n");
    printf("    \"description\": ");
    if (header->description == NULL) {
        fputs("null", stdout);
    } else {
        write_json_string(stdout, header->description);
    }
    printf(",\n");
    printf("    \"connects\": ");
    emit_string_array(stdout, 4, (const char *const *)header->connects, header->connect_count);
    printf(",\n");
    printf("    \"settings\": ");
    if (header->setting_count == 0) {
        fputs("[]", stdout);
    } else {
        fputs("[\n", stdout);
        for (size_t index = 0; index < header->setting_count; index++) {
            const songyan_script_setting *setting = &header->settings[index];
            write_indent(stdout, 6);
            fputs("{\n", stdout);
            write_indent(stdout, 8);
            fputs("\"key\": ", stdout);
            write_json_string(stdout, setting->key);
            fputs(",\n", stdout);
            write_indent(stdout, 8);
            fputs("\"kind\": ", stdout);
            write_json_string(stdout, songyan_script_setting_kind_name(setting->kind));
            fputs(",\n", stdout);
            write_indent(stdout, 8);
            fputs("\"label\": ", stdout);
            write_json_string(stdout, setting->label);
            fputc('\n', stdout);
            write_indent(stdout, 6);
            fputs(index + 1 < header->setting_count ? "},\n" : "}\n", stdout);
        }
        write_indent(stdout, 4);
        fputs("]", stdout);
    }
    printf(",\n");
    printf("    \"secrets\": ");
    if (header->secret_count == 0) {
        fputs("[]", stdout);
    } else {
        fputs("[\n", stdout);
        for (size_t index = 0; index < header->secret_count; index++) {
            const songyan_script_secret *secret = &header->secrets[index];
            write_indent(stdout, 6);
            fputs("{\n", stdout);
            write_indent(stdout, 8);
            fputs("\"key\": ", stdout);
            write_json_string(stdout, secret->key);
            fputs(",\n", stdout);
            write_indent(stdout, 8);
            fputs("\"label\": ", stdout);
            write_json_string(stdout, secret->label);
            fputc('\n', stdout);
            write_indent(stdout, 6);
            fputs(index + 1 < header->secret_count ? "},\n" : "}\n", stdout);
        }
        write_indent(stdout, 4);
        fputs("]", stdout);
    }
    printf(",\n");
    printf("    \"needs\": ");
    const char *needs[2];
    size_t need_count = 0;
    if ((header->needs & SONGYAN_SCRIPT_CAPABILITY_TEXT) != 0) {
        needs[need_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_TEXT);
    }
    if ((header->needs & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0) {
        needs[need_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_AUDIO);
    }
    emit_string_array(stdout, 4, needs, need_count);
    printf("\n  },\n");
    printf("  \"capabilities\": {\n");
    const char *host[2];
    size_t host_count = 0;
    if ((host_capabilities & SONGYAN_SCRIPT_CAPABILITY_TEXT) != 0) {
        host[host_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_TEXT);
    }
    if ((host_capabilities & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0) {
        host[host_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_AUDIO);
    }
    const char *missing[2];
    size_t missing_count = 0;
    if ((header->needs & ~host_capabilities & SONGYAN_SCRIPT_CAPABILITY_TEXT) != 0) {
        missing[missing_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_TEXT);
    }
    if ((header->needs & ~host_capabilities & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0) {
        missing[missing_count++] = songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_AUDIO);
    }
    printf("    \"host\": ");
    emit_string_array(stdout, 4, host, host_count);
    printf(",\n");
    printf("    \"missing\": ");
    emit_string_array(stdout, 4, missing, missing_count);
    printf("\n  }\n}\n");
}

static void emit_error_report(songyan_script_error code, const songyan_script_header_error *error) {
    printf("{\n");
    printf("  \"ok\": false,\n");
    printf("  \"error\": ");
    write_json_string(stdout, songyan_script_error_name(code));
    printf(",\n");
    printf("  \"line\": %zu,\n", error == NULL ? (size_t)0 : error->line);
    printf("  \"message\": ");
    write_json_string(stdout, error == NULL ? "" : error->message);
    if (error != NULL && error->message_truncated) {
        printf(",\n  \"messageTruncated\": true");
    }
    printf("\n}\n");
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

static int command_header(int argc, char **argv) {
    const char *path = NULL;
    const char *capability_list = "text";
    int index = 0;
    while (index < argc) {
        if (strcmp(argv[index], "--script") == 0 && index + 1 < argc) {
            path = argv[index + 1];
            index += 2;
        } else if (strcmp(argv[index], "--capabilities") == 0 && index + 1 < argc) {
            capability_list = argv[index + 1];
            index += 2;
        } else {
            usage(stderr);
            return 64;
        }
    }
    if (path == NULL) {
        usage(stderr);
        return 64;
    }
    unsigned host_capabilities = 0;
    if (!parse_capabilities(capability_list, &host_capabilities)) {
        fprintf(stderr, "unknown capability list: %s\n", capability_list);
        return 64;
    }
    size_t length = 0;
    char *source = read_file(path, &length);
    if (source == NULL) {
        fprintf(stderr, "cannot read %s\n", path);
        return 64;
    }
    songyan_script_header header;
    songyan_script_header_error error;
    songyan_script_error code = songyan_script_header_parse(source, length, &header, &error);
    free(source);
    if (code == SONGYAN_SCRIPT_OK) {
        emit_header_report(&header, host_capabilities);
        songyan_script_header_free(&header);
        return 0;
    }
    if (code == SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY) {
        fprintf(stderr, "out of memory while parsing header\n");
        return 70;
    }
    emit_error_report(code, &error);
    return 1;
}

static int command_limits(int argc, char **argv) {
    songyan_script_limits limits;
    memset(&limits, 0, sizeof(limits));
    int index = 0;
    while (index < argc) {
        const char *flag = argv[index];
        const char *value = index + 1 < argc ? argv[index + 1] : NULL;
        int slot = -1;
        if (strcmp(flag, "--source-bytes") == 0) {
            slot = 0;
        } else if (strcmp(flag, "--heap-bytes") == 0) {
            slot = 1;
        } else if (strcmp(flag, "--duration-ms") == 0) {
            slot = 2;
        } else if (strcmp(flag, "--request-count") == 0) {
            slot = 3;
        } else if (strcmp(flag, "--response-bytes") == 0) {
            slot = 4;
        } else if (strcmp(flag, "--input-text-bytes") == 0) {
            slot = 5;
        }
        if (slot < 0 || value == NULL) {
            usage(stderr);
            return 64;
        }
        size_t parsed = 0;
        if (!parse_size(value, &parsed)) {
            fprintf(stderr, "invalid value for %s: %s\n", flag, value);
            return 64;
        }
        if ((slot == 2 || slot == 3) && parsed > UINT32_MAX) {
            fprintf(stderr, "value for %s is out of range: %s\n", flag, value);
            return 64;
        }
        switch (slot) {
        case 0:
            limits.source_bytes = parsed;
            break;
        case 1:
            limits.heap_bytes = parsed;
            break;
        case 2:
            limits.duration_ms = (uint32_t)parsed;
            break;
        case 3:
            limits.request_count = (uint32_t)parsed;
            break;
        case 4:
            limits.response_bytes = parsed;
            break;
        default:
            limits.input_text_bytes = parsed;
            break;
        }
        index += 2;
    }
    const char *missing[6];
    size_t missing_count = songyan_script_limits_missing(&limits, missing, 6);
    if (missing_count > 0) {
        printf("{\n  \"ok\": false,\n  \"cliError\": \"limitsNotInjected\",\n  \"missing\": ");
        emit_string_array(stdout, 2, missing, missing_count);
        printf("\n}\n");
        return 64;
    }
    printf("{\n  \"ok\": true,\n  \"limits\": {\n");
    printf("    \"sourceBytes\": %zu,\n", limits.source_bytes);
    printf("    \"heapBytes\": %zu,\n", limits.heap_bytes);
    printf("    \"durationMs\": %u,\n", limits.duration_ms);
    printf("    \"requestCount\": %u,\n", limits.request_count);
    printf("    \"responseBytes\": %zu,\n", limits.response_bytes);
    printf("    \"inputTextBytes\": %zu\n", limits.input_text_bytes);
    printf("  }\n}\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(stderr);
        return 64;
    }
    if (strcmp(argv[1], "header") == 0) {
        return command_header(argc - 2, argv + 2);
    }
    if (strcmp(argv[1], "limits") == 0) {
        return command_limits(argc - 2, argv + 2);
    }
    if (strcmp(argv[1], "run") == 0) {
        return songyan_script_cli_run(argc - 2, argv + 2);
    }
    if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        usage(stdout);
        return 0;
    }
    usage(stderr);
    return 64;
}
