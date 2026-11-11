#ifndef SONGYAN_SCRIPT_RUN_H
#define SONGYAN_SCRIPT_RUN_H

/* Execution layer of the shared script contract: one engine per run, the default export of the
 * script, the injected resource limits and the host callbacks a script can reach.
 *
 * A run is a small state machine. songyan_script_run_create copies the source, the input and the
 * settings, so the caller may free its buffers immediately. songyan_script_run_step then drives
 * the engine until it finishes or needs the host:
 *
 *   for (;;) {
 *       step = songyan_script_run_step(run);
 *       if (step == SONGYAN_SCRIPT_STEP_PENDING) { ... host finishes the fetch ...; continue; }
 *       if (step == SONGYAN_SCRIPT_STEP_RUNNING) continue;
 *       break;
 *   }
 *   result = songyan_script_run_result_take(run);   // owns the outputs and logs
 *   songyan_script_run_destroy(run);
 *
 * Every run creates a fresh JSRuntime and JSContext and frees both afterwards, so scripts cannot
 * see each other and a finished run leaves no engine behind.
 *
 * Limits are policy, not implementation: songyan_script_limits is injected by the host on every
 * run and the bridge carries no numbers of its own. The bridge enforces the heap limit with
 * JS_SetMemoryLimit, the duration with its interrupt handler and the request count and response
 * size while it dispatches fetch. Source size and text length belong to the import and editor
 * steps the host owns; the bridge refuses an input that already violates them as a caller error
 * rather than inventing a user-facing script error.
 *
 * A script is one implementation of the keyboard's single tool interface, not a separate tool
 * system. The host wraps a run in the shared tool session: the parsed header supplies the tool
 * identity (title) and required capabilities, songyan_script_run_* is the execution step, the
 * result's strings are the tool's candidates and cancellation maps to songyan_script_run_cancel.
 * Preview, replace/insert, undo and the panel belong to that shared session and the editor
 * gateway, so this bridge never grows a second run/preview/write-back flow. The cross-platform
 * file format, the sandbox and the independent installation of external extensions are unchanged.
 *
 * Exhausting memory is terminal. When the bridge's accounting allocator refuses an allocation,
 * or when the bytes it copies out of the engine (results and diagnostics) exceed the injected heap
 * limit, the run ends with outOfMemory. That is a contract rather than a guess made from an
 * exception's text: a script cannot catch an allocation refusal and continue, and an unrelated
 * later exception is never reported in its place. A script's own error whose message merely says
 * "out of memory" stays a script error with its original words.
 *
 * Network access is owned by the host, not by this bridge. fetch() never opens a socket here: it
 * queues a request, the step returns SONGYAN_SCRIPT_STEP_PENDING and the host performs the
 * request with its own transport and policy. The host also decides address authorization through
 * host.authorize, which the bridge calls for the requested URL and again for every redirect
 * target the host reports; the bridge does not judge addresses itself, so both platforms can
 * apply their own policy (declared hosts, user settings, full access, LAN rules) and cannot be
 * silently weakened by the shared C layer. When a host supplies no fetch callback, fetch fails
 * with networkFailure instead of pretending the address is safe. */

#include <stddef.h>
#include <stdint.h>

#include "songyan_script.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The bridge keeps no result or console buffer of its own: outputs are returned once, and every
 * console.log line is handed to the host through songyan_script_host.log, so retention and any
 * display limit belong to the host instead of a hard-coded product number here.
 *
 * The one fixed guard is the native stack cap. Without it a recursive script can overflow the
 * embedder's thread stack, which is not a policy the injected limits can express; it protects the
 * process rather than the user. */
#define SONGYAN_SCRIPT_MAX_STACK_BYTES (512u * 1024u)

typedef struct songyan_script_run songyan_script_run;

/* One step of a run. RUNNING means more work is available right now; PENDING means the host has a
 * fetch to finish (complete it, then step again). DONE and FAILED are terminal, CANCELLED is the
 * host's own cancellation and carries no user-facing error. */
typedef enum {
    SONGYAN_SCRIPT_STEP_RUNNING = 0,
    SONGYAN_SCRIPT_STEP_PENDING,
    SONGYAN_SCRIPT_STEP_DONE,
    SONGYAN_SCRIPT_STEP_FAILED,
    SONGYAN_SCRIPT_STEP_CANCELLED,
    SONGYAN_SCRIPT_STEP_INVALID
} songyan_script_step;

/* What the host did with a fetch request handed to it. ACCEPTED means it filled the response in
 * the same call. PENDING means it kept the request id and will call
 * songyan_script_run_complete_fetch later, possibly on a later turn of the host's run loop.
 * REJECTED means its transport refused; error_message is shown as the developer diagnostic. */
typedef enum {
    SONGYAN_SCRIPT_FETCH_ACCEPTED = 0,
    SONGYAN_SCRIPT_FETCH_PENDING,
    SONGYAN_SCRIPT_FETCH_REJECTED
} songyan_script_fetch_action;

typedef enum {
    SONGYAN_SCRIPT_FETCH_INITIAL = 0,
    SONGYAN_SCRIPT_FETCH_REDIRECT
} songyan_script_fetch_phase;

typedef enum {
    SONGYAN_SCRIPT_ADDRESS_ALLOWED = 0,
    SONGYAN_SCRIPT_ADDRESS_DENIED
} songyan_script_address_decision;

typedef struct {
    uint64_t id;
    const char *url; /* absolute URL, bridge-owned until the request is completed */
    const char *method; /* upper-case HTTP token, validated by the environment, bridge-owned */
    const char *headers_json; /* JSON object of request headers, or NULL */
    unsigned char *body; /* NULL when there is no body; bridge-owned */
    size_t body_length;
} songyan_script_fetch_request;

typedef struct {
    unsigned status;
    unsigned char *body; /* copied by the bridge; NULL when the body is empty */
    size_t body_length;
    const char *content_type; /* optional; copied, may be NULL */
    const char *final_url; /* optional absolute URL after redirects; re-authorized by the bridge */
    const char *headers_json; /* optional JSON object of response headers */
} songyan_script_fetch_response;

typedef struct {
    void *userdata;
    /* Address authorization owned by the host. Called with the URL the script asked for and,
     * when the host reports a final URL that differs, with SONGYAN_SCRIPT_FETCH_REDIRECT. The
     * host must also apply the same policy to every redirect it follows itself. Returning
     * DENIED fails the run with addressNotAllowed. NULL means the host cannot authorize any
     * request, and fetch fails. */
    songyan_script_address_decision (*authorize)(void *userdata, const char *url,
                                                 songyan_script_fetch_phase phase);
    /* Performs one request or hands it to a transport that completes it later. NULL means this
     * host has no network access and fetch fails with networkFailure. */
    songyan_script_fetch_action (*fetch)(void *userdata, songyan_script_run *run,
                                         const songyan_script_fetch_request *request,
                                         songyan_script_fetch_response *response,
                                         const char **error_message);
    /* Receives every console.log line as well-formed UTF-8. The bridge does not keep a copy and
     * applies no byte cap, so the host decides what to retain and how much the preview shows; a
     * host that does not want console output leaves this NULL. */
    void (*log)(void *userdata, const char *text, size_t length);
} songyan_script_host;

typedef struct {
    const char *source;
    size_t source_length;
    const songyan_script_header *header; /* parsed by songyan_script_header_parse; outlives the run */
    unsigned host_capabilities; /* songyan_script_capability bits this host can offer */
    const songyan_script_limits *limits; /* every field must be non-zero */
    const char *settings_json; /* user-filled settings and secrets, a JSON object; NULL means {} */
    const char *text; /* text input, NULL when empty */
    size_t text_length;
    const unsigned char *audio; /* audio input for @input audio, NULL when none */
    size_t audio_length;
    songyan_script_host host;
} songyan_script_run_config;

typedef struct {
    songyan_script_error error; /* SONGYAN_SCRIPT_OK on success */
    /* English developer diagnostic, a heap string owned by the result and freed with it. A
     * script's own words are kept as-is and never truncated by the bridge. */
    char *message;
    size_t line; /* 1-based line of a thrown script error, 0 when unknown */
    char **outputs; /* well-formed UTF-8 results owned by the result; 1 or more, may be empty */
    size_t *output_lengths;
    size_t output_count;
} songyan_script_run_result;

/* Copies the configuration and allocates the result. Returns NULL only when memory runs out; an
 * invalid configuration is reported by the first step as SONGYAN_SCRIPT_STEP_INVALID. */
songyan_script_run *songyan_script_run_create(const songyan_script_run_config *config);

/* Drives the run. See the state machine above; call again after ACCEPTED or a completed fetch. */
songyan_script_step songyan_script_run_step(songyan_script_run *run);

/* Hands the host's response for a pending request back to the engine. Returns 1 when the id is a
 * pending request of this run, 0 otherwise. Copy the response before returning: the bridge keeps
 * its own copy. */
int songyan_script_run_complete_fetch(songyan_script_run *run, uint64_t id,
                                      const songyan_script_fetch_response *response);

/* Asks the run to stop at the next engine check. The result is SONGYAN_SCRIPT_STEP_CANCELLED. */
void songyan_script_run_cancel(songyan_script_run *run);

/* Milliseconds left before the duration limit, or 0 when it already passed. A host with an
 * asynchronous fetch uses this to schedule its own timeout instead of guessing. */
uint32_t songyan_script_run_ms_left(const songyan_script_run *run);

const songyan_script_run_result *songyan_script_run_result_get(const songyan_script_run *run);

/* Moves the result out of the run so the host may destroy the run immediately after. The
 * destination must be zeroed or already freed; the run's copy becomes empty. */
void songyan_script_run_result_take(songyan_script_run *run,
                                    songyan_script_run_result *destination);
void songyan_script_run_result_free(songyan_script_run_result *result);

void songyan_script_run_destroy(songyan_script_run *run);

#ifdef __cplusplus
}
#endif

#endif
