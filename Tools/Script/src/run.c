#include "internal.h"

#include "songyan_script_bootstrap.inc"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The run driver: one engine per run, the default export of the script, the injected limits and
 * the error mapping shared by both platforms. The fetch bridge lives in fetch.c; the environment
 * installed before the script runs is src/bootstrap.js. */

/* ---- Allocation accounting ----
 *
 * QuickJS checks its own memory limit before asking the backing allocator for memory, so a
 * refused allocation leaves no public trace: after the fact, a real "out of memory" and a script
 * that threw new InternalError("out of memory") have the same name, message, stack and even the
 * same uncatchable flag. The bridge therefore enforces the injected heap limit in its own
 * allocator and records the refusal. That recorded event is the only signal used to classify
 * outOfMemory; without it an exception stays a script error with the script's own words. */

typedef union {
    struct {
        size_t size;
    } info;
    max_align_t alignment;
} run_allocation;

static void *run_allocator_malloc(void *opaque, size_t size) {
    songyan_script_run *run = opaque;
    if (run->limits.heap_bytes != 0 &&
        (size > run->limits.heap_bytes || run->allocated_bytes > run->limits.heap_bytes - size)) {
        run->allocation_failed = 1;
        return NULL;
    }
    run_allocation *block = malloc(sizeof(*block) + size);
    if (block == NULL) {
        run->allocation_failed = 1;
        return NULL;
    }
    block->info.size = size;
    run->allocated_bytes += size;
    return block + 1;
}

static void run_allocator_free(void *opaque, void *pointer) {
    songyan_script_run *run = opaque;
    if (pointer == NULL) {
        return;
    }
    run_allocation *block = (run_allocation *)pointer - 1;
    run->allocated_bytes -= block->info.size;
    free(block);
}

static void *run_allocator_realloc(void *opaque, void *pointer, size_t size) {
    songyan_script_run *run = opaque;
    if (pointer == NULL) {
        return run_allocator_malloc(opaque, size);
    }
    if (size == 0) {
        run_allocator_free(opaque, pointer);
        return NULL;
    }
    run_allocation *block = (run_allocation *)pointer - 1;
    size_t old_size = block->info.size;
    if (size > old_size && run->limits.heap_bytes != 0 &&
        size - old_size > run->limits.heap_bytes - run->allocated_bytes) {
        run->allocation_failed = 1;
        return NULL;
    }
    run_allocation *grown = realloc(block, sizeof(*grown) + size);
    if (grown == NULL) {
        run->allocation_failed = 1;
        return NULL;
    }
    grown->info.size = size;
    run->allocated_bytes = run->allocated_bytes - old_size + size;
    return grown + 1;
}

static void *run_allocator_calloc(void *opaque, size_t count, size_t size) {
    songyan_script_run *run = opaque;
    if (size != 0 && count > SIZE_MAX / size) {
        if (run != NULL) {
            run->allocation_failed = 1;
        }
        return NULL;
    }
    size_t total = count * size;
    void *pointer = run_allocator_malloc(opaque, total);
    if (pointer != NULL) {
        memset(pointer, 0, total);
    }
    return pointer;
}

static size_t run_allocator_usable_size(const void *pointer) {
    if (pointer == NULL) {
        return 0;
    }
    const run_allocation *block = ((const run_allocation *)pointer) - 1;
    return block->info.size;
}

static const JSMallocFunctions kRunAllocator = {
    run_allocator_calloc,
    run_allocator_malloc,
    run_allocator_free,
    run_allocator_realloc,
    run_allocator_usable_size,
};

/* Charges a host-side copy against the injected heap budget. Exhausting it ends the run with
 * outOfMemory, the same observable contract as an engine allocation refusal. */
static int charge_copy(songyan_script_run *run, size_t bytes) {
    if (run->limits.heap_bytes == 0) {
        return 0;
    }
    if (bytes > run->limits.heap_bytes - run->copy_budget_used) {
        run->copy_budget_exceeded = 1;
        return 0;
    }
    run->copy_budget_used += bytes;
    return 1;
}

static char *duplicate_bytes(const void *bytes, size_t length) {
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    if (length > 0) {
        memcpy(copy, bytes, length);
    }
    copy[length] = '\0';
    return copy;
}

/* ---- Well-formed UTF-8 ----
 *
 * JavaScript strings are UTF-16, so a string with a lone surrogate comes out of JS_ToCString as
 * WTF-8 (ED A0..BF 80..BF for a surrogate), which is not valid UTF-8 and would corrupt the JSON
 * the hosts exchange. Every string that leaves the bridge is copied through this normaliser:
 * ill-formed sequences become U+FFFD, exactly the replacement a UTF-8 decoder shows. Valid text is
 * copied byte for byte, so ordinary Chinese, emoji and ASCII are unchanged. */

static size_t utf8_valid_sequence(const unsigned char *bytes, size_t remaining) {
    unsigned char lead = bytes[0];
    size_t need = 0;
    unsigned minimum = 0;
    unsigned code = 0;
    if (lead <= 0x7F) {
        return remaining > 0 ? 1 : 0;
    } else if (lead >= 0xC2 && lead <= 0xDF) {
        need = 1;
        minimum = 0x80;
        code = lead & 0x1Fu;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        need = 2;
        minimum = 0x800;
        code = lead & 0x0Fu;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        need = 3;
        minimum = 0x10000;
        code = lead & 0x07u;
    } else {
        return 0;
    }
    if (remaining < need + 1) {
        return 0;
    }
    for (size_t index = 1; index <= need; index++) {
        if ((bytes[index] & 0xC0) != 0x80) {
            return 0;
        }
        code = (code << 6) | (bytes[index] & 0x3Fu);
    }
    if (code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
        return 0;
    }
    return need + 1;
}

/* Length of the maximal ill-formed subpart starting at bytes[0]: the lead byte plus the
 * continuation bytes that are themselves valid, so one broken character produces one U+FFFD. */
static size_t utf8_bad_prefix_length(const unsigned char *bytes, size_t remaining) {
    unsigned char lead = bytes[0];
    size_t need = 0;
    if (lead >= 0xC2 && lead <= 0xDF) {
        need = 1;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        need = 2;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        need = 3;
    }
    size_t consumed = 1;
    for (size_t index = 1; index <= need && index < remaining; index++) {
        if ((bytes[index] & 0xC0) != 0x80) {
            break;
        }
        consumed++;
    }
    return consumed;
}

int songyan_script_copy_utf8(songyan_script_run *run, const char *input, size_t length,
                             char **output, size_t *output_length) {
    static const char kReplacement[] = "\xEF\xBF\xBD"; /* U+FFFD */
    const unsigned char *bytes = (const unsigned char *)input;
    if (songyan_script_run_aborted(run)) {
        return -1;
    }
    size_t written = 0;
    size_t next_check = 4096;
    for (size_t index = 0; index < length;) {
        size_t valid = utf8_valid_sequence(bytes + index, length - index);
        if (valid > 0) {
            written += valid;
            index += valid;
        } else {
            written += sizeof(kReplacement) - 1;
            index += utf8_bad_prefix_length(bytes + index, length - index);
        }
        if (index >= next_check) {
            if (songyan_script_run_aborted(run)) {
                return -1;
            }
            next_check = index + 4096;
        }
    }
    char *clean = malloc(written + 1);
    if (clean == NULL) {
        return 0;
    }
    size_t at = 0;
    next_check = 4096;
    for (size_t index = 0; index < length;) {
        size_t valid = utf8_valid_sequence(bytes + index, length - index);
        if (valid > 0) {
            memcpy(clean + at, bytes + index, valid);
            at += valid;
            index += valid;
        } else {
            memcpy(clean + at, kReplacement, sizeof(kReplacement) - 1);
            at += sizeof(kReplacement) - 1;
            index += utf8_bad_prefix_length(bytes + index, length - index);
        }
        if (index >= next_check) {
            if (songyan_script_run_aborted(run)) {
                free(clean);
                return -1;
            }
            next_check = index + 4096;
        }
    }
    clean[at] = '\0';
    *output = clean;
    *output_length = at;
    return 1;
}

uint64_t songyan_script_now_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

int songyan_script_run_deadline_passed(const songyan_script_run *run) {
    return run->deadline_ns != 0 && songyan_script_now_ns() >= run->deadline_ns;
}

static int interrupt_handler(JSContext *context, void *opaque) {
    songyan_script_run *run = opaque;
    (void)context;
    if (run->cancelled) {
        return 1;
    }
    if (songyan_script_run_deadline_passed(run)) {
        run->timed_out = 1;
        return 1;
    }
    return 0;
}

static void finish(songyan_script_run *run, songyan_script_step terminal) {
    run->terminal = terminal;
    run->finished = 1;
    if (terminal == SONGYAN_SCRIPT_STEP_FAILED || terminal == SONGYAN_SCRIPT_STEP_INVALID) {
        run->phase = SONGYAN_SCRIPT_PHASE_FAILED;
    } else {
        run->phase = SONGYAN_SCRIPT_PHASE_DONE;
    }
}

static void set_result_message_va(songyan_script_run *run, const char *format,
                                 va_list arguments) {
    va_list copy;
    va_copy(copy, arguments);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        needed = 0;
    }
    char *message = malloc((size_t)needed + 1);
    if (message == NULL) {
        return;
    }
    vsnprintf(message, (size_t)needed + 1, format, arguments);
    if (!charge_copy(run, (size_t)needed + 1)) {
        // The budget is exhausted; keep a fixed diagnostic instead of an uncharged long one.
        free(message);
        const char *fallback = "the script produced more data than the injected memory limit allows";
        message = duplicate_bytes(fallback, strlen(fallback));
        if (message == NULL) {
            return;
        }
    }
    free(run->result.message);
    run->result.message = message;
}

static void set_result_message(songyan_script_run *run, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    set_result_message_va(run, format, arguments);
    va_end(arguments);
}

void songyan_script_run_fail(songyan_script_run *run, songyan_script_error code,
                             const char *message, size_t line) {
    if (run->finished) {
        return;
    }
    run->result.error = code;
    set_result_message(run, "%s", message == NULL ? "" : message);
    run->result.line = line;
    finish(run, SONGYAN_SCRIPT_STEP_FAILED);
}

void songyan_script_run_failf(songyan_script_run *run, songyan_script_error code,
                              const char *format, ...) {
    if (run->finished) {
        return;
    }
    run->result.error = code;
    va_list arguments;
    va_start(arguments, format);
    set_result_message_va(run, format, arguments);
    va_end(arguments);
    finish(run, SONGYAN_SCRIPT_STEP_FAILED);
}

int songyan_script_run_aborted(songyan_script_run *run) {
    if (run == NULL || run->finished) {
        return 1;
    }
    if (run->cancelled) {
        finish(run, SONGYAN_SCRIPT_STEP_CANCELLED);
        return 1;
    }
    if (songyan_script_run_deadline_passed(run)) {
        run->timed_out = 1;
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_TIMEOUT,
                                 "the script ran longer than %u ms",
                                 (unsigned)run->limits.duration_ms);
        return 1;
    }
    return 0;
}

static void finish_invalid(songyan_script_run *run, const char *format, ...) {
    if (run->finished) {
        return;
    }
    run->result.error = SONGYAN_SCRIPT_OK;
    va_list arguments;
    va_start(arguments, format);
    set_result_message_va(run, format, arguments);
    va_end(arguments);
    finish(run, SONGYAN_SCRIPT_STEP_INVALID);
}

/* The first frame that points into the user's script gives the line the editor should show. */
static size_t stack_line(const char *stack) {
    static const char kMarker[] = "<script>:";
    if (stack == NULL) {
        return 0;
    }
    for (const char *cursor = stack; (cursor = strstr(cursor, kMarker)) != NULL;) {
        cursor += sizeof(kMarker) - 1;
        size_t line = 0;
        int digits = 0;
        while (*cursor >= '0' && *cursor <= '9') {
            line = line * 10 + (size_t)(*cursor - '0');
            cursor++;
            digits = 1;
        }
        if (digits) {
            return line;
        }
    }
    return 0;
}

void songyan_script_run_fail_from_exception(songyan_script_run *run, JSValue exception) {
    if (run->timed_out) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_TIMEOUT,
                                 "the script ran longer than %u ms",
                                 (unsigned)run->limits.duration_ms);
        return;
    }
    /* Only an allocation this bridge refused is a real out-of-memory; a script's own error text
     * is never used to guess. */
    if (run->allocation_failed) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                 "the script needed more than %zu bytes of memory",
                                 run->limits.heap_bytes);
        return;
    }
    char *raw = NULL;
    size_t error_line = 0;
    JSContext *context = run->context;
    if (!JS_IsUndefined(run->describe)) {
        JSValue described = JS_Call(context, run->describe, JS_UNDEFINED, 1, &exception);
        if (JS_IsException(described)) {
            JS_FreeValue(context, JS_GetException(context));
        } else {
            JSValue text = JS_GetPropertyStr(context, described, "message");
            const char *value = JS_ToCString(context, text);
            if (value != NULL) {
                raw = duplicate_bytes(value, strlen(value));
                JS_FreeCString(context, value);
            }
            JS_FreeValue(context, text);
            JSValue trace = JS_GetPropertyStr(context, described, "stack");
            const char *trace_text = JS_ToCString(context, trace);
            if (trace_text != NULL) {
                error_line = stack_line(trace_text);
                JS_FreeCString(context, trace_text);
            }
            JS_FreeValue(context, trace);
            JS_FreeValue(context, described);
        }
    }
    if (raw == NULL) {
        const char *value = JS_ToCString(context, exception);
        const char *fallback = value == NULL ? "the script failed" : value;
        raw = duplicate_bytes(fallback, strlen(fallback));
        if (value != NULL) {
            JS_FreeCString(context, value);
        }
    }
    if (run->allocation_failed) {
        free(raw);
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                 "the script needed more than %zu bytes of memory",
                                 run->limits.heap_bytes);
        return;
    }
    if (raw == NULL) {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                "the script failed and its error could not be read", error_line);
        return;
    }
    char *clean = NULL;
    size_t clean_length = 0;
    int copied = songyan_script_copy_utf8(run, raw, strlen(raw), &clean, &clean_length);
    free(raw);
    if (copied < 0) {
        return; /* the run stopped for time or cancellation; its terminal state is set */
    }
    if (copied == 0) {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                "the script failed and its error could not be read", error_line);
        return;
    }
    songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT, clean, error_line);
    free(clean);
}

/* console output is streamed to the host: the bridge keeps no copy and applies no byte cap, so
 * retention and any preview limit belong to the host and nothing is silently dropped here. */
static JSValue js_log(JSContext *context, JSValueConst this_value, int argc,
                      JSValueConst *argv) {
    (void)this_value;
    songyan_script_run *run = JS_GetContextOpaque(context);
    if (run == NULL || argc < 1) {
        return JS_UNDEFINED;
    }
    size_t length = 0;
    const char *text = JS_ToCStringLen(context, &length, argv[0]);
    if (text == NULL) {
        return JS_EXCEPTION;
    }
    char *clean = NULL;
    size_t clean_length = 0;
    int ok = songyan_script_copy_utf8(run, text, length, &clean, &clean_length);
    JS_FreeCString(context, text);
    if (ok < 0) {
        return JS_EXCEPTION;
    }
    if (!ok) {
        return JS_ThrowOutOfMemory(context);
    }
    if (run->host.log != NULL) {
        run->host.log(run->host.userdata, clean, clean_length);
    }
    free(clean);
    return JS_UNDEFINED;
}

static void release_outputs(char **outputs, size_t *lengths, size_t count) {
    for (size_t index = 0; index < count; index++) {
        free(outputs[index]);
    }
    free(outputs);
    free(lengths);
}

/* Grows the result arrays one element at a time. A sparse array therefore errors on its first
 * hole before anything large is allocated, and a dense array is already bounded by the injected
 * heap limit, so the bridge needs no fixed result count of its own. */
static int append_output(songyan_script_run *run, char ***outputs, size_t **lengths,
                         size_t *count, size_t *capacity, const char *text, size_t length) {
    if (*count == *capacity) {
        size_t next = *capacity == 0 ? 4 : *capacity * 2;
        size_t *grown_lengths = realloc(*lengths, next * sizeof(**lengths));
        if (grown_lengths == NULL) {
            return 0;
        }
        *lengths = grown_lengths;
        char **grown_outputs = realloc(*outputs, next * sizeof(**outputs));
        if (grown_outputs == NULL) {
            return 0;
        }
        *outputs = grown_outputs;
        *capacity = next;
    }
    char *clean = NULL;
    size_t clean_length = 0;
    int copied = songyan_script_copy_utf8(run, text, length, &clean, &clean_length);
    if (copied < 0) {
        return -1;
    }
    if (!copied) {
        return 0;
    }
    if (!charge_copy(run, clean_length + 1)) {
        free(clean);
        return 0;
    }
    (*outputs)[*count] = clean;
    (*lengths)[*count] = clean_length;
    (*count)++;
    return 1;
}

static void fail_result_memory(songyan_script_run *run) {
    if (run->copy_budget_exceeded) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                 "the script produced more results than the injected %zu byte "
                                 "memory limit allows",
                                 run->limits.heap_bytes);
    } else if (run->allocation_failed) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                 "the script needed more than %zu bytes of memory",
                                 run->limits.heap_bytes);
    } else {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                "not enough memory for the script result", 0);
    }
}

static int finish_outputs(songyan_script_run *run, JSValue value) {
    if (run->allocation_failed || run->copy_budget_exceeded) {
        fail_result_memory(run);
        return -1;
    }
    JSContext *context = run->context;
    if (JS_IsString(value)) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(context, &length, value);
        if (text == NULL) {
            songyan_script_run_fail_from_exception(run, JS_GetException(context));
            return -1;
        }
        char **outputs = NULL;
        size_t *lengths = NULL;
        size_t count = 0;
        size_t capacity = 0;
        int ok = append_output(run, &outputs, &lengths, &count, &capacity, text, length);
        JS_FreeCString(context, text);
        if (ok < 0) {
            release_outputs(outputs, lengths, count);
            return -1;
        }
        if (!ok) {
            release_outputs(outputs, lengths, count);
            fail_result_memory(run);
            return -1;
        }
        run->result.outputs = outputs;
        run->result.output_lengths = lengths;
        run->result.output_count = count;
        finish(run, SONGYAN_SCRIPT_STEP_DONE);
        return 0;
    }
    if (JS_IsArray(value)) {
        JSValue length_value = JS_GetPropertyStr(context, value, "length");
        uint32_t count = 0;
        int ok = !JS_IsException(length_value) && JS_ToUint32(context, &count, length_value) == 0;
        JS_FreeValue(context, length_value);
        if (!ok) {
            songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                    "the script returned an array whose length cannot be read", 0);
            return -1;
        }
        if (count == 0) {
            finish(run, SONGYAN_SCRIPT_STEP_DONE);
            return 0;
        }
        char **outputs = NULL;
        size_t *lengths = NULL;
        size_t written = 0;
        size_t capacity = 0;
        for (uint32_t index = 0; index < count; index++) {
            if (songyan_script_run_aborted(run)) {
                release_outputs(outputs, lengths, written);
                return -1;
            }
            JSValue item = JS_GetPropertyUint32(context, value, index);
            if (JS_IsException(item)) {
                release_outputs(outputs, lengths, written);
                songyan_script_run_fail_from_exception(run, JS_GetException(context));
                return -1;
            }
            if (!JS_IsString(item)) {
                JS_FreeValue(context, item);
                release_outputs(outputs, lengths, written);
                songyan_script_run_fail(
                    run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                    "the script returned an array with something other than strings in it", 0);
                return -1;
            }
            size_t length = 0;
            const char *text = JS_ToCStringLen(context, &length, item);
            JS_FreeValue(context, item);
            if (text == NULL) {
                release_outputs(outputs, lengths, written);
                songyan_script_run_fail_from_exception(run, JS_GetException(context));
                return -1;
            }
            ok = append_output(run, &outputs, &lengths, &written, &capacity, text, length);
            JS_FreeCString(context, text);
            if (ok < 0) {
                release_outputs(outputs, lengths, written);
                return -1;
            }
            if (!ok) {
                release_outputs(outputs, lengths, written);
                fail_result_memory(run);
                return -1;
            }
        }
        run->result.outputs = outputs;
        run->result.output_lengths = lengths;
        run->result.output_count = written;
        finish(run, SONGYAN_SCRIPT_STEP_DONE);
        return 0;
    }
    const char *kind = "object";
    if (JS_IsUndefined(value)) {
        kind = "undefined";
    } else if (JS_IsNull(value)) {
        kind = "null";
    } else if (JS_IsBool(value)) {
        kind = "boolean";
    } else if (JS_IsNumber(value)) {
        kind = "number";
    } else if (JS_IsFunction(context, value)) {
        kind = "function";
    }
    songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                             "the script returned %s; a string or an array of strings is required",
                             kind);
    return -1;
}

static int fail_fetch_error(songyan_script_run *run) {
    songyan_script_run_fail(run, run->fetch_error_code,
                            run->fetch_error_message == NULL ? "the request failed"
                                                             : run->fetch_error_message,
                            0);
    return -1;
}

/* Drives queued jobs and host requests until nothing more can happen without the host. Returns 1
 * when the host owes a fetch response, 0 when quiescent and -1 when the run has failed. */
static int pump(songyan_script_run *run) {
    for (;;) {
        if (run->cancelled) {
            finish(run, SONGYAN_SCRIPT_STEP_CANCELLED);
            return -1;
        }
        if (songyan_script_run_deadline_passed(run)) {
            run->timed_out = 1;
            JSValue ignored = JS_UNDEFINED;
            songyan_script_run_fail_from_exception(run, ignored);
            return -1;
        }
        int ran_jobs = 0;
        for (;;) {
            JSContext *job_context = NULL;
            int status = JS_ExecutePendingJob(run->runtime, &job_context);
            if (status < 0) {
                JSValue exception = JS_GetException(run->context);
                songyan_script_run_fail_from_exception(run, exception);
                JS_FreeValue(run->context, exception);
                return -1;
            }
            if (status == 0) {
                break;
            }
            ran_jobs = 1;
            if (run->cancelled) {
                finish(run, SONGYAN_SCRIPT_STEP_CANCELLED);
                return -1;
            }
            if (songyan_script_run_deadline_passed(run)) {
                run->timed_out = 1;
                JSValue ignored = JS_UNDEFINED;
                songyan_script_run_fail_from_exception(run, ignored);
                return -1;
            }
        }
        if (run->allocation_failed) {
            songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                     "the script needed more than %zu bytes of memory",
                                     run->limits.heap_bytes);
            return -1;
        }
        if (run->fetch_error) {
            return fail_fetch_error(run);
        }
        int progress = 0;
        int drained = songyan_script_fetch_drain(run, &progress);
        if (drained < 0) {
            return -1;
        }
        if (progress) {
            continue;
        }
        if (drained) {
            return 1;
        }
        if (!ran_jobs) {
            return 0;
        }
    }
}

static int validate_config(songyan_script_run *run) {
    if (run->config.header == NULL) {
        finish_invalid(run, "no parsed header was given to the run");
        return -1;
    }
    if (run->source == NULL || run->source_length == 0) {
        finish_invalid(run, "the script source is empty");
        return -1;
    }
    const char *missing[6];
    if (songyan_script_limits_missing(&run->limits, missing, 6) > 0) {
        finish_invalid(run, "the host must inject every resource limit");
        return -1;
    }
    if (run->source_length > run->limits.source_bytes) {
        finish_invalid(run, "the source is %zu bytes, over the %zu byte limit",
                       run->source_length, run->limits.source_bytes);
        return -1;
    }
    if (run->text_length > run->limits.input_text_bytes) {
        finish_invalid(run, "the input text is %zu bytes, over the %zu byte limit",
                       run->text_length, run->limits.input_text_bytes);
        return -1;
    }
    if (run->config.header->api != SONGYAN_SCRIPT_API_VERSION) {
        finish_invalid(run, "the header declares api %u but this host implements %u",
                       run->config.header->api, SONGYAN_SCRIPT_API_VERSION);
        return -1;
    }
    unsigned missing_capabilities = run->config.header->needs & ~run->config.host_capabilities;
    if (missing_capabilities != 0) {
        const char *name = (missing_capabilities & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0
                               ? songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_AUDIO)
                               : songyan_script_capability_name(SONGYAN_SCRIPT_CAPABILITY_TEXT);
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_CAPABILITY,
                                 "this host cannot provide %s input", name);
        return -1;
    }
    if ((run->config.header->needs & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0 &&
        run->audio_length == 0) {
        finish_invalid(run, "the header asks for audio input but the host supplied none");
        return -1;
    }
    return 0;
}

static int load_module_namespace(songyan_script_run *run) {
    run->module_namespace =
        JS_GetModuleNamespace(run->context, run->module_definition);
    if (JS_IsException(run->module_namespace)) {
        JSValue exception = JS_GetException(run->context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(run->context, exception);
        return -1;
    }
    return 0;
}

static int engine_start(songyan_script_run *run) {
    run->allocation_failed = 0;
    run->allocated_bytes = 0;
    run->runtime = JS_NewRuntime2(&kRunAllocator, run);
    if (run->runtime == NULL) {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                run->allocation_failed
                                    ? "the script engine does not fit in the injected heap limit"
                                    : "not enough memory for the script engine",
                                0);
        return -1;
    }
    JS_SetMaxStackSize(run->runtime, SONGYAN_SCRIPT_MAX_STACK_BYTES);
    JS_SetCanBlock(run->runtime, false);
    JS_SetInterruptHandler(run->runtime, interrupt_handler, run);
    run->context = JS_NewContext(run->runtime);
    if (run->context == NULL) {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                "not enough memory for the script engine", 0);
        return -1;
    }
    JS_SetContextOpaque(run->context, run);
    JSContext *context = run->context;
    JSValue global = JS_GetGlobalObject(context);
    JS_SetPropertyStr(context, global, "__songyanLog",
                      JS_NewCFunction(context, js_log, "__songyanLog", 1));
    if (songyan_script_fetch_install(run) < 0) {
        JS_FreeValue(context, global);
        return -1;
    }
    JSValue bootstrapped =
        JS_Eval(context, songyan_script_bootstrap, songyan_script_bootstrap_length,
                "<bootstrap>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(bootstrapped)) {
        JSValue exception = JS_GetException(context);
        JS_FreeValue(context, global);
        const char *text = JS_ToCString(context, exception);
        if (run->allocation_failed) {
            songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                    "the script engine does not fit in the injected heap limit", 0);
        } else {
            finish_invalid(run, "the script environment could not start: %s",
                           text == NULL ? "the bridge and bootstrap disagree" : text);
        }
        if (text != NULL) {
            JS_FreeCString(context, text);
        }
        JS_FreeValue(context, exception);
        return -1;
    }
    run->describe = JS_GetPropertyStr(context, bootstrapped, "describe");
    run->response_factory = JS_GetPropertyStr(context, bootstrapped, "response");
    JS_FreeValue(context, bootstrapped);
    JS_FreeValue(context, global);
    if (JS_IsException(run->describe) || JS_IsException(run->response_factory)) {
        finish_invalid(run, "the script environment is incomplete; the bridge and bootstrap disagree");
        return -1;
    }
    if (run->settings_json != NULL) {
        run->settings = JS_ParseJSON(context, run->settings_json, strlen(run->settings_json),
                                     "<settings>");
    } else {
        run->settings = JS_NewObject(context);
    }
    if (JS_IsException(run->settings) || !JS_IsObject(run->settings)) {
        JSValue exception = JS_IsException(run->settings) ? JS_GetException(context) : JS_UNDEFINED;
        JS_FreeValue(context, exception);
        run->settings = JS_UNDEFINED;
        finish_invalid(run, "the settings handed to the run are not a JSON object");
        return -1;
    }
    JSValue module = JS_Eval(context, run->source, run->source_length, "<script>",
                             JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(module)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        return -1;
    }
    /* The namespace may only be built after the module is instantiated; asking for it while the
     * module is still a compiled function object walks unlinked export slots. */
    run->module_definition = JS_VALUE_GET_PTR(module);
    JSValue evaluated = JS_EvalFunction(context, module);
    if (JS_IsException(evaluated)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        return -1;
    }
    if (JS_IsPromise(evaluated)) {
        run->awaited = evaluated;
        run->phase = SONGYAN_SCRIPT_PHASE_MODULE_AWAIT;
    } else {
        JS_FreeValue(context, evaluated);
        if (load_module_namespace(run) < 0) {
            return -1;
        }
        run->phase = SONGYAN_SCRIPT_PHASE_CALL;
    }
    return 0;
}

static int call_default(songyan_script_run *run) {
    JSContext *context = run->context;
    JSValue function = JS_GetPropertyStr(context, run->module_namespace, "default");
    if (JS_IsException(function)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        return -1;
    }
    if (!JS_IsFunction(context, function)) {
        JS_FreeValue(context, function);
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                "the script has no default export function", 0);
        return -1;
    }
    JSValue input = JS_NewObject(context);
    JS_SetPropertyStr(context, input, "settings", JS_DupValue(context, run->settings));
    if ((run->config.header->needs & SONGYAN_SCRIPT_CAPABILITY_AUDIO) != 0) {
        JS_SetPropertyStr(context, input, "audio",
                          JS_NewArrayBufferCopy(context, run->audio, run->audio_length));
    } else {
        JS_SetPropertyStr(context, input, "text",
                          JS_NewStringLen(context, run->text, run->text_length));
    }
    JSValue argv[1] = {input};
    JSValue result = JS_Call(context, function, JS_UNDEFINED, 1, argv);
    JS_FreeValue(context, function);
    JS_FreeValue(context, input);
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        return -1;
    }
    if (JS_IsPromise(result)) {
        run->awaited = result;
        run->phase = SONGYAN_SCRIPT_PHASE_CALL_AWAIT;
        return 0;
    }
    int failed = finish_outputs(run, result) < 0;
    JS_FreeValue(context, result);
    return failed ? -1 : 0;
}

songyan_script_run *songyan_script_run_create(const songyan_script_run_config *config) {
    if (config == NULL || config->source == NULL) {
        return NULL;
    }
    songyan_script_run *run = calloc(1, sizeof(*run));
    if (run == NULL) {
        return NULL;
    }
    run->config = *config;
    run->text = duplicate_bytes(config->text, config->text_length);
    run->source = duplicate_bytes(config->source, config->source_length);
    if (config->settings_json != NULL) {
        run->settings_json = duplicate_bytes(config->settings_json, strlen(config->settings_json));
    }
    if (config->audio != NULL && config->audio_length > 0) {
        run->audio = malloc(config->audio_length);
        if (run->audio != NULL) {
            memcpy(run->audio, config->audio, config->audio_length);
        }
    }
    run->source_length = config->source_length;
    run->text_length = config->text_length;
    run->audio_length = config->audio_length;
    if (config->limits != NULL) {
        run->limits = *config->limits;
    }
    run->host = config->host;
    run->phase = SONGYAN_SCRIPT_PHASE_NEW;
    run->awaited = JS_UNDEFINED;
    run->module_namespace = JS_UNDEFINED;
    run->describe = JS_UNDEFINED;
    run->response_factory = JS_UNDEFINED;
    run->settings = JS_UNDEFINED;
    run->terminal = SONGYAN_SCRIPT_STEP_RUNNING;
    run->result.message = duplicate_bytes("", 0);
    if (run->source == NULL || run->result.message == NULL || (config->text != NULL && run->text == NULL) ||
        (config->settings_json != NULL && run->settings_json == NULL) ||
        (config->audio != NULL && config->audio_length > 0 && run->audio == NULL)) {
        songyan_script_run_destroy(run);
        return NULL;
    }
    return run;
}

void songyan_script_run_cancel(songyan_script_run *run) {
    if (run != NULL) {
        run->cancelled = 1;
    }
}

uint32_t songyan_script_run_ms_left(const songyan_script_run *run) {
    if (run == NULL || run->deadline_ns == 0) {
        return run == NULL ? 0 : run->limits.duration_ms;
    }
    uint64_t now = songyan_script_now_ns();
    if (now >= run->deadline_ns) {
        return 0;
    }
    uint64_t remaining = (run->deadline_ns - now) / 1000000ull;
    if (remaining > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)remaining;
}

songyan_script_step songyan_script_run_step(songyan_script_run *run) {
    if (run == NULL) {
        return SONGYAN_SCRIPT_STEP_INVALID;
    }
    if (run->finished) {
        return run->terminal;
    }
    if (!run->started) {
        run->started = 1;
        if (run->limits.duration_ms > 0) {
            run->deadline_ns = songyan_script_now_ns() + (uint64_t)run->limits.duration_ms * 1000000ull;
        }
        if (validate_config(run) < 0) {
            return run->terminal;
        }
        if (engine_start(run) < 0) {
            return run->terminal;
        }
    }
    for (;;) {
        if (run->finished) {
            return run->terminal;
        }
        switch (run->phase) {
        case SONGYAN_SCRIPT_PHASE_MODULE_AWAIT:
        case SONGYAN_SCRIPT_PHASE_CALL_AWAIT: {
            int drained = pump(run);
            if (drained < 0) {
                return run->terminal;
            }
            if (drained > 0) {
                return SONGYAN_SCRIPT_STEP_PENDING;
            }
            if (!JS_IsPromise(run->awaited)) {
                songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                        "the script awaited a promise that never settles", 0);
                return run->terminal;
            }
            JSPromiseStateEnum state = JS_PromiseState(run->context, run->awaited);
            if (state == JS_PROMISE_PENDING) {
                songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                        "the script awaited a promise that never settles", 0);
                return run->terminal;
            }
            JSValue settled = JS_PromiseResult(run->context, run->awaited);
            JS_FreeValue(run->context, run->awaited);
            run->awaited = JS_UNDEFINED;
            int module_phase = run->phase == SONGYAN_SCRIPT_PHASE_MODULE_AWAIT;
            run->phase = module_phase ? SONGYAN_SCRIPT_PHASE_CALL : SONGYAN_SCRIPT_PHASE_DONE;
            if (state == JS_PROMISE_REJECTED) {
                songyan_script_run_fail_from_exception(run, settled);
                JS_FreeValue(run->context, settled);
                return run->terminal;
            }
            if (module_phase) {
                JS_FreeValue(run->context, settled);
                if (load_module_namespace(run) < 0) {
                    return run->terminal;
                }
            } else {
                int failed = finish_outputs(run, settled) < 0;
                JS_FreeValue(run->context, settled);
                if (failed) {
                    return run->terminal;
                }
            }
            continue;
        }
        case SONGYAN_SCRIPT_PHASE_CALL: {
            if (call_default(run) < 0) {
                return run->terminal;
            }
            continue;
        }
        case SONGYAN_SCRIPT_PHASE_DONE:
            return SONGYAN_SCRIPT_STEP_DONE;
        case SONGYAN_SCRIPT_PHASE_FAILED:
            return run->terminal;
        case SONGYAN_SCRIPT_PHASE_NEW:
            return SONGYAN_SCRIPT_STEP_INVALID;
        }
    }
}

const songyan_script_run_result *songyan_script_run_result_get(const songyan_script_run *run) {
    return run == NULL ? NULL : &run->result;
}

void songyan_script_run_result_free(songyan_script_run_result *result) {
    if (result == NULL) {
        return;
    }
    for (size_t index = 0; index < result->output_count; index++) {
        free(result->outputs[index]);
    }
    free(result->outputs);
    free(result->output_lengths);
    free(result->message);
    memset(result, 0, sizeof(*result));
}

void songyan_script_run_result_take(songyan_script_run *run,
                                    songyan_script_run_result *destination) {
    if (run == NULL || destination == NULL) {
        return;
    }
    *destination = run->result;
    memset(&run->result, 0, sizeof(run->result));
}

void songyan_script_run_destroy(songyan_script_run *run) {
    if (run == NULL) {
        return;
    }
    if (run->context != NULL) {
        JS_FreeValue(run->context, run->awaited);
        JS_FreeValue(run->context, run->module_namespace);
        JS_FreeValue(run->context, run->settings);
        JS_FreeValue(run->context, run->describe);
        JS_FreeValue(run->context, run->response_factory);
    }
    songyan_script_fetch_release(run);
    if (run->context != NULL) {
        JS_FreeContext(run->context);
    }
    if (run->runtime != NULL) {
        JS_FreeRuntime(run->runtime);
    }
    songyan_script_run_result_free(&run->result);
    free(run->fetch_error_message);
    free(run->source);
    free(run->settings_json);
    free(run->text);
    free(run->audio);
    memset(run, 0, sizeof(*run));
    free(run);
}
