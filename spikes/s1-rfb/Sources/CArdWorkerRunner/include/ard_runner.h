#ifndef SANJBOX_ARD_RUNNER_H
#define SANJBOX_ARD_RUNNER_H
#include <stddef.h>
#include <stdint.h>
typedef struct ard_cancel ard_cancel;
ard_cancel *ard_cancel_create(void);
void ard_cancel_set(ard_cancel *);
void ard_cancel_destroy(ard_cancel *);
enum { ARD_RUN_OK=0, ARD_RUN_EXECUTABLE=1, ARD_RUN_IO=2, ARD_RUN_TIMEOUT=3,
       ARD_RUN_CANCELLED=4, ARD_RUN_OUTPUT=5, ARD_RUN_EXIT=6, ARD_RUN_CLEANUP=7,
       ARD_RUN_CALLER=8 };
/* macOS-only, synthetic local worker, no network. timeout is 1..10000 ms.
 * Output is retained only on complete EOF + exit 0. Cancellation is thread safe.
 * Caller MUST keep SIGCHLD=SIG_DFL, no SA_NOCLDWAIT and no competing child reaper
 * throughout the call. This is an offline fixture boundary, not a generic process API. */
int ard_run_worker(const char *, const uint8_t *, size_t, uint8_t *, size_t *,
    unsigned timeout_ms, const ard_cancel *);
#endif
