// SGSharedMemory.h
// Thin C wrappers for shm_open and shm_unlink so that Swift code can call them.
//
// shm_open is declared as variadic in sys/mman.h, which makes it unavailable
// from Swift.  These wrappers accept mode_t explicitly and forward the call.
//
// ADR 0012: Driver IPC on macOS 26 — POSIX SHM

#ifndef SG_SHARED_MEMORY_H
#define SG_SHARED_MEMORY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Open (or create) a POSIX shared memory object.
/// Returns a file descriptor >= 0 on success, or -1 on error (errno set).
int sg_shm_open(const char *name, int oflag, unsigned short mode);

/// Unlink a POSIX shared memory object.
/// Returns 0 on success, or -1 on error (errno set).
int sg_shm_unlink(const char *name);

#ifdef __cplusplus
}
#endif

#endif // SG_SHARED_MEMORY_H
