// SGSharedAudio.h
// Shared memory layout for Stimmgabel driver IPC.
//
// The app process creates the POSIX shared memory segment; the driver opens it.
// Audio frames are transferred via SHMAudioBuffer using lock-free index arithmetic
// (single producer: app / single consumer: driver I/O thread).
//
// ADR 0012: Driver IPC on macOS 26 — POSIX SHM + Darwin notify

#pragma once
#include <stdint.h>
#include <stdatomic.h>

// POSIX shared memory name (passed to shm_open).
#define SG_SHM_NAME      "/stimmgabel-audio-v1"

// Capacity in stereo frames (power of 2, ~85 ms @ 48 kHz).
#define SG_SHM_CAPACITY  4096u

// Darwin notify names for consumer-active signalling.
#define SG_NOTIFY_ACTIVE   "com.innoq.stimmgabel.consumer-active"
#define SG_NOTIFY_INACTIVE "com.innoq.stimmgabel.consumer-inactive"

// Shared memory layout.
// writePos: incremented by the app after writing frames (producer).
// readPos:  incremented by the driver after consuming frames (consumer).
// samples:  interleaved stereo float32 — samples[frame*2] = L, samples[frame*2+1] = R.
typedef struct {
    _Atomic(uint64_t) writePos;
    _Atomic(uint64_t) readPos;
    float             samples[SG_SHM_CAPACITY * 2];
} SHMAudioBuffer;
