// SGRingBuffer.c
// Lock-free single-producer / single-reader ring buffer for interleaved stereo
// float32 audio frames. See SGRingBuffer.h for the full API contract.
//
// Head indices are unsigned 32-bit frame counters that wrap naturally at 2^32.
// Because SG_RING_CAPACITY is a power of two, modulo arithmetic is correct even
// across natural uint32 wraparound.

#include "include/SGRingBuffer.h"

#include <stdatomic.h>
#include <string.h>

// Map a frame index to a sample-array slot.
#define SG_SLOT(n) ((n) & (SG_RING_CAPACITY - 1u))

void SG_RingBuffer_Init(SGRingBuffer *rb)
{
    memset(rb->samples, 0, sizeof(rb->samples));
    atomic_store_explicit(&rb->writeHead, 0u, memory_order_relaxed);
    atomic_store_explicit(&rb->readHead,  0u, memory_order_relaxed);
}

uint32_t SG_RingBuffer_AvailableFrames(const SGRingBuffer *rb)
{
    // Acquire on writeHead: ensures we see all samples written before this store.
    uint32_t w = atomic_load_explicit(&rb->writeHead, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&rb->readHead,  memory_order_relaxed);
    // Unsigned subtraction wraps correctly at 2^32 when SG_RING_CAPACITY <= 2^31.
    return w - r;
}

uint32_t SG_RingBuffer_Write(SGRingBuffer *rb,
                             const float  *src,
                             uint32_t      frameCount)
{
    uint32_t r    = atomic_load_explicit(&rb->readHead, memory_order_acquire);
    uint32_t w    = atomic_load_explicit(&rb->writeHead, memory_order_relaxed);
    uint32_t used = w - r;                               // frames already in buffer
    uint32_t free = (used < SG_RING_CAPACITY) ? (SG_RING_CAPACITY - used) : 0u;

    if (frameCount > free) frameCount = free;
    if (frameCount == 0u) return 0u;

    for (uint32_t i = 0u; i < frameCount; i++) {
        uint32_t slot = SG_SLOT(w + i);
        rb->samples[slot * 2u]      = src[i * 2u];       // L
        rb->samples[slot * 2u + 1u] = src[i * 2u + 1u];  // R
    }

    // Release: makes written samples visible to the consumer before advancing head.
    atomic_store_explicit(&rb->writeHead, w + frameCount, memory_order_release);
    return frameCount;
}

void SG_RingBuffer_Drain(SGRingBuffer *rb,
                         float        *outLeft,
                         float        *outRight,
                         uint32_t      frameCount)
{
    uint32_t w     = atomic_load_explicit(&rb->writeHead, memory_order_acquire);
    uint32_t r     = atomic_load_explicit(&rb->readHead,  memory_order_relaxed);
    uint32_t avail = w - r;

    uint32_t readFrames = (frameCount <= avail) ? frameCount : avail;

    for (uint32_t i = 0u; i < readFrames; i++) {
        uint32_t slot = SG_SLOT(r + i);
        outLeft[i]  = rb->samples[slot * 2u];
        outRight[i] = rb->samples[slot * 2u + 1u];
    }

    // Zero-fill remainder on underrun (silence for the missing frames)
    for (uint32_t i = readFrames; i < frameCount; i++) {
        outLeft[i]  = 0.0f;
        outRight[i] = 0.0f;
    }

    // Release: pairs with the acquire in Write so the producer sees the updated
    // read head before deciding how much free space remains.
    atomic_store_explicit(&rb->readHead, r + readFrames, memory_order_release);
}
