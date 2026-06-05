// SGRingBuffer.h
// Lock-free stereo float32 ring buffer shared between the Stimmgabel driver
// (DoIOOperation drain, XPC write handler) and test targets.
//
// Design:
//   - Capacity: SG_RING_CAPACITY frames (power-of-2 for efficient masking)
//   - Format:   interleaved float32 L/R (2 floats per frame)
//   - Producer: single writer (XPC callback thread)
//   - Consumer: single reader (CoreAudio I/O thread via DoIOOperation)
//   - Memory order: acquire/release on the atomic head indices
//
// All functions are re-entrant and do not allocate heap memory.

#ifndef SG_RING_BUFFER_H
#define SG_RING_BUFFER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Number of stereo frames the ring buffer can hold.
// Must be a power of two so index masking works correctly.
// 4096 frames @ 48 kHz ≈ 85 ms — absorbs ≥ 5 HAL cycles of 512-frame jitter.
#define SG_RING_CAPACITY 4096u

// Interleaved stereo float32 ring buffer.
// Callers must initialise with SG_RingBuffer_Init before use.
typedef struct {
    float       samples[SG_RING_CAPACITY * 2u]; // [L0,R0, L1,R1, …]
    _Atomic(uint32_t) writeHead; // next frame index to write (producer)
    _Atomic(uint32_t) readHead;  // next frame index to read  (consumer)
} SGRingBuffer;

// Zero-fill the sample array and reset both heads to zero.
// Not thread-safe — call once before first use.
void SG_RingBuffer_Init(SGRingBuffer *rb);

// Write up to frameCount interleaved stereo frames from src into the ring buffer.
// src must point to frameCount * 2 floats ([L0,R0, L1,R1, …]).
// Returns the number of frames actually written (fewer if the buffer is nearly full).
// Thread-safe for a single writer.
uint32_t SG_RingBuffer_Write(SGRingBuffer *rb,
                             const float  *src,
                             uint32_t      frameCount);

// Returns the number of complete frames available to read.
// Thread-safe: may be called from any thread.
uint32_t SG_RingBuffer_AvailableFrames(const SGRingBuffer *rb);

// Drain frameCount frames from the ring buffer into outLeft and outRight.
// outLeft  — receives the left-channel samples  (frameCount floats).
// outRight — receives the right-channel samples (frameCount floats).
// If the buffer holds fewer than frameCount frames, the missing frames are
// zero-filled (silence) so the caller always gets exactly frameCount frames.
// Thread-safe for a single reader.
void SG_RingBuffer_Drain(SGRingBuffer *rb,
                         float        *outLeft,
                         float        *outRight,
                         uint32_t      frameCount);

#ifdef __cplusplus
}
#endif

#endif // SG_RING_BUFFER_H
