#include "internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The bridge between the script's fetch() and the platform host. This file never opens a socket
 * and never decides whether an address is safe: it asks the host to authorize the requested URL
 * (and any redirect target the host reports), hands the request to the host transport and settles
 * the JavaScript promise when the host answers. That keeps the platform policy in the platform
 * proxy and stops the shared C layer from claiming an address is safe on its own. */

static char *copy_text(const char *text, size_t length) {
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

/* Everything handed to the host must be well-formed UTF-8; a JS string can carry a lone
 * surrogate, which JS_ToCString encodes as WTF-8. */
static int copy_js_text(songyan_script_run *run, const char *text, size_t length, char **output,
                        size_t *clean_length) {
    char *clean = NULL;
    size_t normalized = 0;
    int copied = songyan_script_copy_utf8(run, text, length, &clean, &normalized);
    if (copied <= 0) {
        return copied;
    }
    if (clean_length != NULL) {
        *clean_length = normalized;
    }
    *output = clean;
    return 1;
}

static void slot_release(songyan_script_run *run, songyan_script_fetch_slot *slot) {
    if (run->context != NULL) {
        JS_FreeValue(run->context, slot->resolve);
        JS_FreeValue(run->context, slot->reject);
    }
    free(slot->url);
    free(slot->method);
    free(slot->headers_json);
    free(slot->body);
    free(slot->response_body);
    free(slot->response_content_type);
    free(slot->response_final_url);
    free(slot->response_headers_json);
    memset(slot, 0, sizeof(*slot));
}

static void slot_remove(songyan_script_run *run, size_t index) {
    slot_release(run, &run->slots[index]);
    if (index + 1 < run->slot_count) {
        memmove(&run->slots[index], &run->slots[index + 1],
                (run->slot_count - index - 1) * sizeof(*run->slots));
    }
    run->slot_count--;
}

static int append_slot(songyan_script_run *run, songyan_script_fetch_slot **slot_out) {
    if (run->slot_count == run->slot_capacity) {
        size_t next = run->slot_capacity == 0 ? 4 : run->slot_capacity * 2;
        songyan_script_fetch_slot *grown =
            realloc(run->slots, next * sizeof(*run->slots));
        if (grown == NULL) {
            return 0;
        }
        run->slots = grown;
        run->slot_capacity = next;
    }
    songyan_script_fetch_slot *slot = &run->slots[run->slot_count++];
    memset(slot, 0, sizeof(*slot));
    slot->resolve = JS_UNDEFINED;
    slot->reject = JS_UNDEFINED;
    *slot_out = slot;
    return 1;
}

/* Marks the run failed with one of the contract's network errors and gives JavaScript an
 * exception it can see, while the next pump check makes the whole run fail even if the script
 * catches the exception. */
static JSValue fetch_fail(JSContext *context, songyan_script_run *run, songyan_script_error code,
                          const char *format, ...) {
    run->fetch_error = 1;
    run->fetch_error_code = code;
    va_list arguments;
    va_start(arguments, format);
    va_list copy;
    va_copy(copy, arguments);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        needed = 0;
    }
    char *message = malloc((size_t)needed + 1);
    if (message != NULL) {
        vsnprintf(message, (size_t)needed + 1, format, arguments);
        free(run->fetch_error_message);
        run->fetch_error_message = message;
    }
    va_end(arguments);
    return JS_ThrowTypeError(context, "%s", message == NULL ? "the request failed" : message);
}

static int authorize(songyan_script_run *run, const char *url,
                     songyan_script_fetch_phase phase) {
    if (run->host.authorize == NULL) {
        return 0;
    }
    return run->host.authorize(run->host.userdata, url, phase) == SONGYAN_SCRIPT_ADDRESS_ALLOWED;
}

static int copy_response_into(songyan_script_run *run, songyan_script_fetch_slot *slot,
                              const songyan_script_fetch_response *response) {
    slot->status = response->status;
    if (response->body != NULL && response->body_length > 0) {
        if (songyan_script_run_aborted(run)) {
            return -1;
        }
        slot->response_body = malloc(response->body_length);
        if (slot->response_body == NULL) {
            return 0;
        }
        size_t at = 0;
        while (at < response->body_length) {
            size_t step = response->body_length - at;
            if (step > 65536) {
                step = 65536;
            }
            memcpy(slot->response_body + at, response->body + at, step);
            at += step;
            if (songyan_script_run_aborted(run)) {
                free(slot->response_body);
                slot->response_body = NULL;
                return -1;
            }
        }
        slot->response_body_length = response->body_length;
    }
    if (response->content_type != NULL) {
        slot->response_content_type = copy_text(response->content_type,
                                                strlen(response->content_type));
        if (slot->response_content_type == NULL) {
            return 0;
        }
    }
    if (response->final_url != NULL) {
        slot->response_final_url = copy_text(response->final_url, strlen(response->final_url));
        if (slot->response_final_url == NULL) {
            return 0;
        }
    }
    if (response->headers_json != NULL) {
        slot->response_headers_json = copy_text(response->headers_json,
                                                strlen(response->headers_json));
        if (slot->response_headers_json == NULL) {
            return 0;
        }
    }
    return 1;
}

/* Builds the Response object through the bootstrap factory, settles the promise and drops the
 * slot. Returns -1 after failing the run. */
static int resolve_slot(songyan_script_run *run, size_t index) {
    songyan_script_fetch_slot *slot = &run->slots[index];
    if (slot->response_oversize) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
                                 "the response is %zu bytes, over the %zu byte limit",
                                 slot->response_declared_length, run->limits.response_bytes);
        slot_remove(run, index);
        return -1;
    }
    if (slot->response_final_url != NULL && strcmp(slot->response_final_url, slot->url) != 0 &&
        !authorize(run, slot->response_final_url, SONGYAN_SCRIPT_FETCH_REDIRECT)) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_ADDRESS_NOT_ALLOWED,
                                 "the redirect target %s is not allowed",
                                 slot->response_final_url);
        slot_remove(run, index);
        return -1;
    }
    JSContext *context = run->context;
    JSValue status = JS_NewInt32(context, (int32_t)slot->status);
    JSValue headers = JS_NewStringLen(context,
                                      slot->response_headers_json == NULL
                                          ? "{}"
                                          : slot->response_headers_json,
                                      slot->response_headers_json == NULL
                                          ? 2
                                          : strlen(slot->response_headers_json));
    JSValue body = JS_NewArrayBufferCopy(context, slot->response_body,
                                         slot->response_body_length);
    JSValue arguments[3] = {status, headers, body};
    JSValue response =
        JS_Call(context, run->response_factory, JS_UNDEFINED, 3, arguments);
    JS_FreeValue(context, status);
    JS_FreeValue(context, headers);
    JS_FreeValue(context, body);
    if (JS_IsException(response)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        slot_remove(run, index);
        return -1;
    }
    JSValue settled = JS_Call(context, slot->resolve, JS_UNDEFINED, 1, &response);
    JS_FreeValue(context, response);
    if (JS_IsException(settled)) {
        JSValue exception = JS_GetException(context);
        songyan_script_run_fail_from_exception(run, exception);
        JS_FreeValue(context, exception);
        slot_remove(run, index);
        return -1;
    }
    JS_FreeValue(context, settled);
    slot_remove(run, index);
    return 0;
}

/* Hands one queued request to the host. Returns 1 when the host kept it, 0 when it answered
 * immediately (and the promise was settled) and -1 after failing the run. */
static int submit_slot(songyan_script_run *run, size_t index) {
    songyan_script_fetch_slot *slot = &run->slots[index];
    songyan_script_fetch_request request;
    memset(&request, 0, sizeof(request));
    request.id = slot->id;
    request.url = slot->url;
    request.method = slot->method;
    request.headers_json = slot->headers_json;
    request.body = (unsigned char *)slot->body;
    request.body_length = slot->body_length;
    songyan_script_fetch_response response;
    memset(&response, 0, sizeof(response));
    const char *error_message = NULL;
    songyan_script_fetch_action action =
        run->host.fetch(run->host.userdata, run, &request, &response, &error_message);
    if (action == SONGYAN_SCRIPT_FETCH_PENDING) {
        slot->submitted = 1;
        return 1;
    }
    if (action == SONGYAN_SCRIPT_FETCH_REJECTED) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE, "%s",
                                 error_message == NULL ? "the request failed" : error_message);
        slot_remove(run, index);
        return -1;
    }
    slot->submitted = 1;
    slot->answered = 1;
    if (response.body_length > run->limits.response_bytes) {
        songyan_script_run_failf(run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
                                 "the response is %zu bytes, over the %zu byte limit",
                                 response.body_length, run->limits.response_bytes);
        slot_remove(run, index);
        return -1;
    }
    {
        int copied = copy_response_into(run, slot, &response);
        if (copied < 0) {
            slot_remove(run, index);
            return -1;
        }
        if (copied == 0) {
            songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_OUT_OF_MEMORY,
                                    "not enough memory for the script result", 0);
            slot_remove(run, index);
            return -1;
        }
    }
    return resolve_slot(run, index) < 0 ? -1 : 0;
}

int songyan_script_fetch_drain(songyan_script_run *run, int *progress) {
    int waiting = 0;
    *progress = 0;
    for (size_t index = 0; index < run->slot_count;) {
        songyan_script_fetch_slot *slot = &run->slots[index];
        if (slot->answered) {
            if (resolve_slot(run, index) < 0) {
                return -1;
            }
            *progress = 1;
            continue;
        }
        if (!slot->submitted) {
            int submitted = submit_slot(run, index);
            if (submitted < 0) {
                return -1;
            }
            *progress = 1;
            if (submitted == 1) {
                waiting = 1;
                index++;
            }
            continue;
        }
        waiting = 1;
        index++;
    }
    return waiting;
}

int songyan_script_run_complete_fetch(songyan_script_run *run, uint64_t id,
                                      const songyan_script_fetch_response *response) {
    if (run == NULL || response == NULL) {
        return 0;
    }
    for (size_t index = 0; index < run->slot_count; index++) {
        songyan_script_fetch_slot *slot = &run->slots[index];
        if (slot->id != id || !slot->submitted || slot->answered) {
            continue;
        }
        slot->answered = 1;
        if (response->body_length > run->limits.response_bytes) {
            slot->response_oversize = 1;
            slot->response_declared_length = response->body_length;
            return 1;
        }
        int copied = copy_response_into(run, slot, response);
        if (copied < 0) {
            slot->answered = 0;
            return 0;
        }
        if (copied == 0) {
            slot->answered = 0;
            return 0;
        }
        return 1;
    }
    return 0;
}

static JSValue js_fetch_raw(JSContext *context, JSValueConst this_value, int argc,
                            JSValueConst *argv) {
    (void)this_value;
    songyan_script_run *run = JS_GetContextOpaque(context);
    if (run == NULL) {
        return JS_ThrowInternalError(context, "fetch was called outside a run");
    }
    if (argc < 2) {
        return JS_ThrowTypeError(context, "fetch expects a URL and a method");
    }
    size_t url_length = 0;
    const char *url_text = JS_ToCStringLen(context, &url_length, argv[0]);
    if (url_text == NULL) {
        return JS_EXCEPTION;
    }
    size_t clean_url_length = 0;
    char *url = NULL;
    int copied = copy_js_text(run, url_text, url_length, &url, &clean_url_length);
    JS_FreeCString(context, url_text);
    if (copied < 0) {
        return JS_EXCEPTION;
    }
    if (copied == 0) {
        return JS_ThrowOutOfMemory(context);
    }
    url_length = clean_url_length;
    if (url_length == 0) {
        free(url);
        return fetch_fail(context, run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
                          "the URL is empty");
    }
    size_t method_length = 0;
    const char *method_text = JS_ToCStringLen(context, &method_length, argv[1]);
    char *method = NULL;
    int method_copied = 0;
    if (method_text != NULL) {
        method_copied = copy_js_text(run, method_text, method_length, &method, NULL);
        JS_FreeCString(context, method_text);
    }
    if (method_copied < 0) {
        free(url);
        return JS_EXCEPTION;
    }
    if (method_copied == 0) {
        free(url);
        return JS_ThrowOutOfMemory(context);
    }
    char *headers_json = NULL;
    if (argc > 2 && JS_IsString(argv[2])) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(context, &length, argv[2]);
        if (text == NULL) {
            free(url);
            free(method);
            return JS_EXCEPTION;
        }
        int headers_copied = copy_js_text(run, text, length, &headers_json, NULL);
        JS_FreeCString(context, text);
        if (headers_copied < 0) {
            free(url);
            free(method);
            return JS_EXCEPTION;
        }
        if (headers_copied == 0) {
            free(url);
            free(method);
            return JS_ThrowOutOfMemory(context);
        }
    }
    char *body_text = NULL;
    size_t body_text_length = 0;
    if (argc > 3 && JS_IsString(argv[3])) {
        const char *text = JS_ToCStringLen(context, &body_text_length, argv[3]);
        if (text == NULL) {
            free(url);
            free(method);
            free(headers_json);
            return JS_EXCEPTION;
        }
        size_t clean_body_length = 0;
        int body_copied = copy_js_text(run, text, body_text_length, &body_text,
                                       &clean_body_length);
        body_text_length = clean_body_length;
        JS_FreeCString(context, text);
        if (body_copied < 0) {
            free(url);
            free(method);
            free(headers_json);
            return JS_EXCEPTION;
        }
        if (body_copied == 0) {
            free(url);
            free(method);
            free(headers_json);
            return JS_ThrowOutOfMemory(context);
        }
    }
    unsigned char *body = NULL;
    size_t body_length = 0;
    if (argc > 4 && JS_IsArrayBuffer(argv[4])) {
        uint8_t *bytes = JS_GetArrayBuffer(context, &body_length, argv[4]);
        if (bytes == NULL) {
            free(url);
            free(method);
            free(headers_json);
            free(body_text);
            return JS_EXCEPTION;
        }
        if (body_length > 0) {
            body = malloc(body_length);
            if (body == NULL) {
                free(url);
                free(method);
                free(headers_json);
                free(body_text);
                return JS_ThrowOutOfMemory(context);
            }
            memcpy(body, bytes, body_length);
        }
    } else if (body_text != NULL) {
        body = (unsigned char *)body_text;
        body_length = body_text_length;
        body_text = NULL;
    }
    free(body_text);
    if (run->host.fetch == NULL) {
        free(url);
        free(method);
        free(headers_json);
        free(body);
        return fetch_fail(context, run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
                          "this host does not provide network access");
    }
    if (!authorize(run, url, SONGYAN_SCRIPT_FETCH_INITIAL)) {
        JSValue failure = fetch_fail(context, run, SONGYAN_SCRIPT_ERROR_ADDRESS_NOT_ALLOWED,
                                     "the address %s is not allowed", url);
        free(url);
        free(method);
        free(headers_json);
        free(body);
        return failure;
    }
    if (run->request_count >= run->limits.request_count) {
        free(url);
        free(method);
        free(headers_json);
        free(body);
        return fetch_fail(context, run, SONGYAN_SCRIPT_ERROR_NETWORK_FAILURE,
                          "the script made more than %u requests",
                          (unsigned)run->limits.request_count);
    }
    run->request_count++;
    JSValue functions[2];
    JSValue promise = JS_NewPromiseCapability(context, functions);
    if (JS_IsException(promise)) {
        free(url);
        free(method);
        free(headers_json);
        free(body);
        return JS_EXCEPTION;
    }
    songyan_script_fetch_slot *slot = NULL;
    if (!append_slot(run, &slot)) {
        JS_FreeValue(context, functions[0]);
        JS_FreeValue(context, functions[1]);
        JS_FreeValue(context, promise);
        free(url);
        free(method);
        free(headers_json);
        free(body);
        return JS_ThrowOutOfMemory(context);
    }
    slot->id = ++run->next_fetch_id;
    slot->url = url;
    slot->url_length = url_length;
    slot->method = method;
    slot->headers_json = headers_json;
    slot->body = body;
    slot->body_length = body_length;
    slot->resolve = functions[0];
    slot->reject = functions[1];
    return promise;
}

int songyan_script_fetch_install(songyan_script_run *run) {
    JSContext *context = run->context;
    JSValue global = JS_GetGlobalObject(context);
    JSValue function = JS_NewCFunction(context, js_fetch_raw, "__songyanFetchRaw", 5);
    int status = JS_SetPropertyStr(context, global, "__songyanFetchRaw", function);
    JS_FreeValue(context, global);
    if (status < 0) {
        songyan_script_run_fail(run, SONGYAN_SCRIPT_ERROR_SCRIPT,
                                "the bridge could not install fetch", 0);
        return -1;
    }
    return 0;
}

void songyan_script_fetch_release(songyan_script_run *run) {
    for (size_t index = 0; index < run->slot_count; index++) {
        slot_release(run, &run->slots[index]);
    }
    free(run->slots);
    run->slots = NULL;
    run->slot_count = 0;
    run->slot_capacity = 0;
}
