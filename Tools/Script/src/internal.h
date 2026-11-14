#ifndef SONGYAN_SCRIPT_INTERNAL_H
#define SONGYAN_SCRIPT_INTERNAL_H

/* Shared state between the run driver and the fetch bridge. Not installed or installed with the
 * library: the public surface is include/songyan_script_run.h. */

#include "quickjs.h"
#include "songyan_script_run.h"

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t id;
    char *url;
    size_t url_length;
    char *method;
    char *headers_json;
    unsigned char *body;
    size_t body_length;
    JSValue resolve;
    JSValue reject;
    int submitted; /* handed to the host, awaiting its response */
    int answered; /* the host completed it; the next step settles the promise */
    unsigned status;
    unsigned char *response_body;
    size_t response_body_length;
    /* A response over the injected size limit is rejected before its bytes are copied; only the
     * declared length is kept so the diagnostic can still name it. */
    size_t response_declared_length;
    int response_oversize;
    char *response_content_type;
    char *response_final_url;
    char *response_headers_json;
} songyan_script_fetch_slot;

typedef enum {
    SONGYAN_SCRIPT_PHASE_NEW = 0,
    SONGYAN_SCRIPT_PHASE_MODULE_AWAIT,
    SONGYAN_SCRIPT_PHASE_CALL,
    SONGYAN_SCRIPT_PHASE_CALL_AWAIT,
    SONGYAN_SCRIPT_PHASE_DONE,
    SONGYAN_SCRIPT_PHASE_FAILED
} songyan_script_phase;

struct songyan_script_run {
    songyan_script_run_config config;
    char *source;
    size_t source_length;
    char *settings_json;
    char *text;
    size_t text_length;
    unsigned char *audio;
    size_t audio_length;
    songyan_script_limits limits;
    songyan_script_host host;

    JSRuntime *runtime;
    JSContext *context;
    JSValue describe;
    JSValue response_factory;
    JSValue settings;
    JSValue awaited;
    JSValue module_namespace;
    JSModuleDef *module_definition;

    songyan_script_phase phase;
    songyan_script_run_result result;
    songyan_script_step terminal;
    int started;
    int finished;

    uint64_t deadline_ns;
    /* Engine time used by finished steps, and the start of the step in progress (0 between
     * steps), so the compute limit ignores the time the host spends on a fetch. */
    uint64_t compute_used_ns;
    uint64_t step_started_ns;
    int cancelled;
    int timed_out;
    int fetch_error;
    songyan_script_error fetch_error_code;
    char *fetch_error_message;

    songyan_script_fetch_slot *slots;
    size_t slot_count;
    size_t slot_capacity;
    uint64_t next_fetch_id;
    unsigned request_count;
    /* The engine allocates through the bridge so a refused allocation is an observable event,
     * not a guess made from an exception's text. */
    size_t allocated_bytes;
    int allocation_failed;
    /* Bytes copied out of the engine (results and diagnostics) are charged against the same
     * injected heap limit, so a script cannot multiply one large string into an unbounded host
     * allocation by referencing it many times. */
    size_t copy_budget_used;
    int copy_budget_exceeded;
};

/* run.c */
uint64_t songyan_script_now_ns(void);
/* Fails the run with a formatted diagnostic; the message is heap-owned by the result. */
void songyan_script_run_failf(songyan_script_run *run, songyan_script_error code,
                              const char *format, ...);
/* Copies a string that came out of the engine as well-formed UTF-8, replacing lone surrogates and
 * other ill-formed sequences with U+FFFD. Checks cancellation and the duration limit while it
 * walks the bytes. Returns 1 on success, 0 when memory runs out and -1 when the run was stopped
 * (the run already has its terminal state in that case). */
int songyan_script_copy_utf8(songyan_script_run *run, const char *input, size_t length,
                             char **output, size_t *output_length);
/* Returns 1 when the run must stop now: cancellation or an expired duration limit. The run's
 * terminal state is set in that case, so callers just unwind without producing partial results. */
int songyan_script_run_aborted(songyan_script_run *run);
void songyan_script_run_fail(songyan_script_run *run, songyan_script_error code,
                             const char *message, size_t line);
void songyan_script_run_fail_from_exception(songyan_script_run *run, JSValue exception);
/* Stop and restart the compute clock around a host call that may block. */
void songyan_script_run_pause_compute(songyan_script_run *run);
void songyan_script_run_resume_compute(songyan_script_run *run);
/* Returns 1 when the wall-clock duration or the compute time is used up. */
int songyan_script_run_deadline_passed(const songyan_script_run *run);

/* fetch.c */
int songyan_script_fetch_install(songyan_script_run *run);
/* Settles promises the host answered, hands new requests to the host and reports whether the host
 * still owes a response. Returns 1 when the run must wait, 0 when nothing is outstanding and -1
 * after failing the run. progress is set when a slot was settled or removed, which means new jobs
 * are queued and the driver must keep going instead of declaring the run idle. */
int songyan_script_fetch_drain(songyan_script_run *run, int *progress);
void songyan_script_fetch_release(songyan_script_run *run);

#endif
