// StimmgabelDriver.c
// Audio Server Plugin for Stimmgabel.
//
// Exposes a virtual microphone device at 48 kHz / float32 / stereo
// (non-interleaved). Audio data is sourced from the app process via POSIX
// shared memory (SHMAudioBuffer) with Darwin notify signals for consumer-active
// state changes.
//
// IPC architecture (ADR 0012):
//   - App creates POSIX SHM "/stimmgabel-audio-v1" and writes interleaved
//     stereo float32 frames into SHMAudioBuffer.samples using lock-free
//     producer/consumer index arithmetic.
//   - Driver opens the same SHM segment and drains frames in DoIOOperation.
//   - Consumer-active signals:
//       StartIO  → notify_post("com.innoq.stimmgabel.consumer-active")
//       StopIO   → notify_post("com.innoq.stimmgabel.consumer-inactive")
//     The app registers with notify_register_dispatch to receive these.
//
// On macOS 26, AudioServerPlugins run as Remote Driver Services in a sandbox
// that blocks Mach service registration; XPC is therefore not viable.
// This SHM approach is sandbox-safe (ADR 0012).
//
// Reference: Apple AudioServerPlugIn.h, Apple SampleAudioDevice example,
// Background Music BGMDriver, Apple QA1811.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../../../Sources/DriverIPC/include/SGSharedAudio.h"

#define SGLog(fmt, ...)      os_log(OS_LOG_DEFAULT, "[Stimmgabel] " fmt, ##__VA_ARGS__)
#define SGFault(fmt, ...)    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_FAULT, "[Stimmgabel][FAULT] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define kDeviceUID           "com.innoq.stimmgabel.virtualmic"
#define kDeviceName          "Stimmgabel"
#define kManufacturerName    "INNOQ"

#define kSampleRate          48000.0
#define kChannelCount        1u     // mono — simplest layout coreaudiod handles natively
#define kBytesPerSample      4u     // float32
#define kFramesPerPacket     1u
#define kBytesPerFrame       (kChannelCount * kBytesPerSample)
// ZeroTimeStamp period in frames
#define kZeroTimeStampPeriod 512u

// Fixed object IDs
#define kObjectID_PlugIn     1u
#define kObjectID_Device     2u
#define kObjectID_Stream     3u
#define kObjectID_Mute       4u

// ---------------------------------------------------------------------------
// Device state
// ---------------------------------------------------------------------------

typedef struct {
    pthread_mutex_t         mutex;
    OSStatus                ioStatus;       // kAudioHardwareNoError when I/O is running
    UInt64                  startHostTime;
    UInt64                  frameCount;
    Boolean                 muteEnabled;
    AudioServerPlugInHostRef hostRef;

    // Shared memory — app writes, driver reads in DoIOOperation
    int                     shmFd;
    SHMAudioBuffer         *shmBuf;
} SGDriverState;

static SGDriverState gState;
static mach_timebase_info_data_t gMachTimebaseInfo;
static uint64_t      gReadPos = 0;  // sequential SHM consumer read pointer (DoIOOperation)

// ---------------------------------------------------------------------------
// Forward declarations (vtable signatures)
// ---------------------------------------------------------------------------

static HRESULT    SGDriver_QueryInterface(void *, REFIID, LPVOID *);
static ULONG      SGDriver_AddRef(void *);
static ULONG      SGDriver_Release(void *);

static OSStatus   SGDriver_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus   SGDriver_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus   SGDriver_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus   SGDriver_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus   SGDriver_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus   SGDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus   SGDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);

static Boolean    SGDriver_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus   SGDriver_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus   SGDriver_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus   SGDriver_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus   SGDriver_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);

static OSStatus   SGDriver_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus   SGDriver_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus   SGDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus   SGDriver_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus   SGDriver_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus   SGDriver_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus   SGDriver_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

// ---------------------------------------------------------------------------
// Driver interface vtable
// ---------------------------------------------------------------------------

static AudioServerPlugInDriverInterface gDriverInterface = {
    .QueryInterface                  = SGDriver_QueryInterface,
    .AddRef                          = SGDriver_AddRef,
    .Release                         = SGDriver_Release,
    .Initialize                      = SGDriver_Initialize,
    .CreateDevice                    = SGDriver_CreateDevice,
    .DestroyDevice                   = SGDriver_DestroyDevice,
    .AddDeviceClient                 = SGDriver_AddDeviceClient,
    .RemoveDeviceClient              = SGDriver_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = SGDriver_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange  = SGDriver_AbortDeviceConfigurationChange,
    .HasProperty                     = SGDriver_HasProperty,
    .IsPropertySettable              = SGDriver_IsPropertySettable,
    .GetPropertyDataSize             = SGDriver_GetPropertyDataSize,
    .GetPropertyData                 = SGDriver_GetPropertyData,
    .SetPropertyData                 = SGDriver_SetPropertyData,
    .StartIO                         = SGDriver_StartIO,
    .StopIO                          = SGDriver_StopIO,
    .GetZeroTimeStamp                = SGDriver_GetZeroTimeStamp,
    .WillDoIOOperation               = SGDriver_WillDoIOOperation,
    .BeginIOOperation                = SGDriver_BeginIOOperation,
    .DoIOOperation                   = SGDriver_DoIOOperation,
    .EndIOOperation                  = SGDriver_EndIOOperation
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef           = &gDriverInterfacePtr;

// ---------------------------------------------------------------------------
// SHM helpers
// ---------------------------------------------------------------------------

// Close and unmap the current SHM mapping (if any).
// Safe to call even if shmBuf is NULL.
static void SG_SHM_Close(void)
{
    pthread_mutex_lock(&gState.mutex);
    if (gState.shmBuf != NULL) {
        munmap((void *)gState.shmBuf, sizeof(SHMAudioBuffer));
        gState.shmBuf = NULL;
        SGLog("SHM: unmapped old segment");
    }
    pthread_mutex_unlock(&gState.mutex);
}

// Open the POSIX shared memory segment created by the app and mmap it read-only.
// Called from Initialize AND from StartIO (always re-maps so the driver picks up
// the current segment even if the app restarted since Initialize).
// The driver never creates or resizes the SHM — that is the app's responsibility.
// Read-only mapping: the driver only reads samples and writePos; it does not
// update readPos (the latest-frame read model needs no consumer pointer).
static void SG_SHM_Open(void)
{
    // O_RDONLY: the driver's sandbox allows read-only SHM access.
    // No O_CREAT: only open if the app has already created the segment.
    int fd = shm_open(SG_SHM_NAME, O_RDONLY, 0);
    if (fd < 0) {
        // ENOENT means the app hasn't started yet — silent, will retry on StartIO.
        if (errno != ENOENT) {
            SGFault("SHM: shm_open(%s) failed: errno=%d", SG_SHM_NAME, errno);
        } else {
            SGLog("SHM: segment not found yet (app not started), will retry");
        }
        return;
    }

    size_t sz = sizeof(SHMAudioBuffer);
    // PROT_READ only — no write access needed; no ftruncate needed.
    void *mapped = mmap(NULL, sz, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);   // fd no longer needed after mmap
    if (mapped == MAP_FAILED) {
        SGFault("SHM: mmap(%zu) failed: errno=%d", sz, errno);
        return;
    }

    pthread_mutex_lock(&gState.mutex);
    gState.shmFd  = -1;   // fd was closed above
    gState.shmBuf = (SHMAudioBuffer *)mapped;
    pthread_mutex_unlock(&gState.mutex);

    uint64_t wp = atomic_load_explicit(&((SHMAudioBuffer *)mapped)->writePos,
                                       memory_order_acquire);
    SGFault("SHM: mapped %zu bytes read-only at %p (writePos=%llu)",
            sz, mapped, (unsigned long long)wp);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void *AudioServerPlugInDriverCreate(CFAllocatorRef inAllocator)
{
    (void)inAllocator;
    pthread_mutex_init(&gState.mutex, NULL);
    gState.ioStatus      = kAudioHardwareIllegalOperationError;
    gState.frameCount    = 0;
    gState.muteEnabled   = false;
    gState.hostRef       = NULL;
    gState.shmFd         = -1;
    gState.shmBuf        = NULL;
    mach_timebase_info(&gMachTimebaseInfo);
    SGLog("AudioServerPlugInDriverCreate called — driver ref %p", (void*)gDriverRef);
    return gDriverRef;
}

// ---------------------------------------------------------------------------
// IUnknown
// ---------------------------------------------------------------------------

static HRESULT SGDriver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    (void)inDriver;
    // kAudioServerPlugInDriverInterfaceUUID bytes: EEA5773D-CC43-49F1-8E00-8F96E7D23B17
    static const UInt8 kInterfaceBytes[16] = {
        0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1,
        0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17
    };
    // REFIID is CFUUIDBytes (a 16-byte struct by value) in the macOS 26 SDK.
    // Compare the bytes directly — no need for CFUUIDGetUUIDBytes().
    if (memcmp(&inUUID, kInterfaceBytes, sizeof(CFUUIDBytes)) == 0) {
        SGLog("QueryInterface -> S_OK");
        *outInterface = gDriverRef;
        return S_OK;
    }
    SGLog("QueryInterface -> E_NOINTERFACE");
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG SGDriver_AddRef(void *inDriver)  { (void)inDriver; return 1; }
static ULONG SGDriver_Release(void *inDriver) { (void)inDriver; return 1; }

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

static OSStatus SGDriver_Initialize(AudioServerPlugInDriverRef inDriver,
                                    AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    SGFault("Initialize called — host %p", (void*)inHost);
    pthread_mutex_lock(&gState.mutex);
    gState.hostRef = inHost;
    pthread_mutex_unlock(&gState.mutex);

    // Open shared memory before notifying coreaudiod of the device.
    SG_SHM_Open();

    // Notify coreaudiod asynchronously (must not call PropertiesChanged from
    // Initialize directly — the proxy is not fully set up yet).
    AudioServerPlugInHostRef capturedHost = inHost;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        SGLog("PropertiesChanged dispatch firing — host %p", (void*)capturedHost);
        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        OSStatus err = capturedHost->PropertiesChanged(capturedHost, kAudioObjectSystemObject, 1, &addr);
        SGLog("PropertiesChanged returned %d", (int)err);
    });

    SGLog("Initialize returning noError");
    return kAudioHardwareNoError;
}

static OSStatus SGDriver_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef dict,
                                      const AudioServerPlugInClientInfo *ci, AudioObjectID *out)
{ (void)d; (void)dict; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError; }

static OSStatus SGDriver_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id)
{ (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }

static OSStatus SGDriver_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                          const AudioServerPlugInClientInfo *ci)
{ (void)d; (void)id; (void)ci; return kAudioHardwareNoError; }

static OSStatus SGDriver_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id,
                                             const AudioServerPlugInClientInfo *ci)
{ (void)d; (void)id; (void)ci; return kAudioHardwareNoError; }

static OSStatus SGDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                           AudioObjectID id, UInt64 a, void *b)
{ (void)d; (void)id; (void)a; (void)b; return kAudioHardwareNoError; }

static OSStatus SGDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                         AudioObjectID id, UInt64 a, void *b)
{ (void)d; (void)id; (void)a; (void)b; return kAudioHardwareNoError; }

// ---------------------------------------------------------------------------
// HasProperty
// ---------------------------------------------------------------------------

static Boolean SGDriver_HasProperty(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientPID,
                                    const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver; (void)inClientPID;

    if (inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Device) {
        SGLog("HasProperty obj=%u sel=0x%X", (unsigned)inObjectID, (unsigned)inAddress->mSelector);
    }

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default: return false;
        }

    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyStreamConfiguration:  // required by PortAudio / AUHAL
        case kAudioDevicePropertyBufferFrameSize:      // non-fatal but needed for accurate latency
        case kAudioDevicePropertyBufferFrameSizeRange: // non-fatal but needed for buffer clamping
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        default: return false;
        }

    case kObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default: return false;
        }

    case kObjectID_Mute:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue:
            return true;
        default: return false;
        }

    default: return false;
    }
}

// ---------------------------------------------------------------------------
// IsPropertySettable
// ---------------------------------------------------------------------------

static OSStatus SGDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inObjectID,
                                            pid_t inClientPID,
                                            const AudioObjectPropertyAddress *inAddress,
                                            Boolean *outIsSettable)
{
    (void)inDriver; (void)inClientPID;
    *outIsSettable = false;
    switch (inObjectID) {
    case kObjectID_Device:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) *outIsSettable = true;
        break;
    case kObjectID_Stream:
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)
            *outIsSettable = true;
        break;
    case kObjectID_Mute:
        if (inAddress->mSelector == kAudioBooleanControlPropertyValue) *outIsSettable = true;
        break;
    default: break;
    }
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// GetPropertyDataSize
// ---------------------------------------------------------------------------

static OSStatus SGDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inObjectID,
                                             pid_t inClientPID,
                                             const AudioObjectPropertyAddress *inAddress,
                                             UInt32 inQualifierDataSize,
                                             const void *inQualifierData,
                                             UInt32 *outDataSize)
{
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;

    if (inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Device) {
        SGLog("GetPropertyDataSize obj=%u sel=0x%X", (unsigned)inObjectID, (unsigned)inAddress->mSelector);
    }

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle: *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:  *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:  *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIsHidden:  *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyStreams:
            *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeOutput)
                           ? 0 : sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreamConfiguration:
            if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = (UInt32)(offsetof(AudioBufferList, mBuffers));
            } else {
                *outDataSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
            }
            return kAudioHardwareNoError;
        case kAudioDevicePropertyBufferFrameSize:      *outDataSize = sizeof(UInt32);           return kAudioHardwareNoError;
        case kAudioDevicePropertyBufferFrameSizeRange: *outDataSize = sizeof(AudioValueRange);  return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        case kAudioDevicePropertyIcon: *outDataSize = sizeof(CFURLRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 s = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription));
            *outDataSize = s;
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:   *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Mute:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue: *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }

    default: return kAudioHardwareBadObjectError;
    }
}

// ---------------------------------------------------------------------------
// Stream format helper
// ---------------------------------------------------------------------------

static AudioStreamBasicDescription SGStreamFormat(void)
{
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;
    f.mBitsPerChannel   = 32;
    f.mChannelsPerFrame = kChannelCount;        // 1 (mono)
    f.mBytesPerFrame    = kBytesPerFrame;       // 4 bytes (1 channel × float32)
    f.mFramesPerPacket  = kFramesPerPacket;
    f.mBytesPerPacket   = kBytesPerFrame;
    return f;
}

// ---------------------------------------------------------------------------
// GetPropertyData
// ---------------------------------------------------------------------------

static OSStatus SGDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inObjectID,
                                         pid_t inClientPID,
                                         const AudioObjectPropertyAddress *inAddress,
                                         UInt32 inQualifierDataSize,
                                         const void *inQualifierData,
                                         UInt32 inDataSize,
                                         UInt32 *outDataSize,
                                         void *outData)
{
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inDataSize;

#define WU32(v) do { *outDataSize = sizeof(UInt32); *((UInt32*)outData) = (UInt32)(v); } while(0)
#define WF64(v) do { *outDataSize = sizeof(Float64); *((Float64*)outData) = (v); } while(0)
#define WCF(v)  do { CFStringRef _s = (v); *outDataSize = sizeof(CFStringRef); *((CFStringRef*)outData) = _s; CFRetain(_s); } while(0)
#define WID(v)  do { *outDataSize = sizeof(AudioObjectID); *((AudioObjectID*)outData) = (AudioObjectID)(v); } while(0)

    if (inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Device) {
        SGLog("GetPropertyData obj=%u sel=0x%X", (unsigned)inObjectID, (unsigned)inAddress->mSelector);
    }

    switch (inObjectID) {

    // --- PlugIn ---
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioPlugInClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kAudioObjectSystemObject); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer: WCF(CFSTR(kManufacturerName)); return kAudioHardwareNoError;
        case kAudioPlugInPropertyResourceBundle: WCF(CFSTR("")); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = *((CFStringRef*)inQualifierData);
            if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) {
                WID(kObjectID_Device);
            } else {
                WID(kAudioObjectUnknown);
            }
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    // --- Device ---
    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioDeviceClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kObjectID_PlugIn); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:      WCF(CFSTR(kDeviceName)); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer: WCF(CFSTR(kManufacturerName)); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID: WCF(CFSTR(kDeviceUID)); return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:  WCF(CFSTR(kDeviceUID)); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType: WU32(kAudioDeviceTransportTypeVirtual); return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain: WU32(0); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive: WU32(1); return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gState.mutex);
            UInt32 r = (gState.ioStatus == kAudioHardwareNoError) ? 1u : 0u;
            pthread_mutex_unlock(&gState.mutex);
            WU32(r); return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            WU32(inAddress->mScope != kAudioObjectPropertyScopeOutput ? 1 : 0);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:  WU32(0); return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:    WU32(0); return kAudioHardwareNoError;
        case kAudioDevicePropertySafetyOffset: WU32(0); return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod: WU32(kZeroTimeStampPeriod); return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate: WF64(kSampleRate); return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:   WU32(0); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: {
            *outDataSize = sizeof(AudioObjectID) * 2;
            ((AudioObjectID*)outData)[0] = kObjectID_Stream;
            ((AudioObjectID*)outData)[1] = kObjectID_Mute;
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = sizeof(AudioObjectID);
            ((AudioObjectID*)outData)[0] = kObjectID_Mute;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = 0;
            } else {
                *outDataSize = sizeof(AudioObjectID);
                ((AudioObjectID*)outData)[0] = kObjectID_Stream;
            }
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange *r = (AudioValueRange*)outData;
            r->mMinimum = kSampleRate; r->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIcon: {
            CFURLRef url = CFURLCreateWithString(NULL, CFSTR(""), NULL);
            *((CFURLRef*)outData) = url;
            *outDataSize = sizeof(CFURLRef);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 sz = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription));
            AudioChannelLayout *l = (AudioChannelLayout*)outData;
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mChannelBitmap    = 0;
            l->mNumberChannelDescriptions = 1;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            l->mChannelDescriptions[0].mChannelFlags = 0;
            l->mChannelDescriptions[0].mCoordinates[0] = 0;
            l->mChannelDescriptions[0].mCoordinates[1] = 0;
            l->mChannelDescriptions[0].mCoordinates[2] = 0;
            *outDataSize = sz;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyStreamConfiguration: {
            // Mono input: 1 buffer, 1 channel.
            AudioBufferList *abl = (AudioBufferList *)outData;
            if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                abl->mNumberBuffers = 0;
                *outDataSize = (UInt32)offsetof(AudioBufferList, mBuffers);
            } else {
                abl->mNumberBuffers = 1;
                abl->mBuffers[0].mNumberChannels = 1;
                abl->mBuffers[0].mDataByteSize   = 0;
                abl->mBuffers[0].mData           = NULL;
                *outDataSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
            }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyBufferFrameSize: {
            // Fixed buffer size matching our render period (kZeroTimeStampPeriod = 512).
            WU32(kZeroTimeStampPeriod);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyBufferFrameSizeRange: {
            // Fixed-size device — only one valid buffer size.
            AudioValueRange *r = (AudioValueRange *)outData;
            r->mMinimum = kZeroTimeStampPeriod;
            r->mMaximum = kZeroTimeStampPeriod;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    // --- Stream ---
    case kObjectID_Stream:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioStreamClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kObjectID_Device); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:  WU32(1); return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection: WU32(1); return kAudioHardwareNoError;  // 1 = input
        case kAudioStreamPropertyTerminalType: WU32(kAudioStreamTerminalTypeMicrophone); return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel: WU32(1); return kAudioHardwareNoError;
        case kAudioStreamPropertyLatency:   WU32(0); return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription fmt = SGStreamFormat();
            memcpy(outData, &fmt, sizeof(fmt));
            *outDataSize = sizeof(fmt);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription *r = (AudioStreamRangedDescription*)outData;
            r->mFormat = SGStreamFormat();
            r->mSampleRateRange.mMinimum = kSampleRate;
            r->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(*r);
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    // --- Mute control ---
    case kObjectID_Mute:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioMuteControlClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kObjectID_Device); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope:    WU32(kAudioObjectPropertyScopeInput); return kAudioHardwareNoError;
        case kAudioControlPropertyElement:  WU32(kAudioObjectPropertyElementMain); return kAudioHardwareNoError;
        case kAudioBooleanControlPropertyValue: {
            pthread_mutex_lock(&gState.mutex);
            UInt32 m = gState.muteEnabled ? 1u : 0u;
            pthread_mutex_unlock(&gState.mutex);
            WU32(m); return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    default: return kAudioHardwareBadObjectError;
    }

#undef WU32
#undef WF64
#undef WCF
#undef WID
}

// ---------------------------------------------------------------------------
// SetPropertyData
// ---------------------------------------------------------------------------

static OSStatus SGDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inObjectID,
                                         pid_t inClientPID,
                                         const AudioObjectPropertyAddress *inAddress,
                                         UInt32 inQualifierDataSize,
                                         const void *inQualifierData,
                                         UInt32 inDataSize,
                                         const void *inData)
{
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;

    switch (inObjectID) {
    case kObjectID_Device:
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            // Only accept 48000 Hz — reject any other rate so PortAudio / Audacity
            // receive an explicit error (-9997) instead of silent inconsistency.
            if (inDataSize >= sizeof(Float64) && inData != NULL) {
                Float64 requested = *((const Float64*)inData);
                if (requested != kSampleRate) {
                    SGLog("SetPropertyData: rejected sample rate %.0f (only %.0f supported)",
                          requested, kSampleRate);
                    return kAudioDeviceUnsupportedFormatError;
                }
            }
            return kAudioHardwareNoError;
        }
        break;
    case kObjectID_Stream:
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)
            return kAudioHardwareNoError;
        break;
    case kObjectID_Mute:
        if (inAddress->mSelector == kAudioBooleanControlPropertyValue && inDataSize >= sizeof(UInt32)) {
            Boolean newVal = (*((const UInt32*)inData)) != 0;
            pthread_mutex_lock(&gState.mutex);
            gState.muteEnabled = newVal;
            AudioServerPlugInHostRef host = gState.hostRef;
            pthread_mutex_unlock(&gState.mutex);

            if (host != NULL) {
                AudioObjectPropertyAddress addr = {
                    kAudioBooleanControlPropertyValue,
                    kAudioObjectPropertyScopeInput,
                    kAudioObjectPropertyElementMain
                };
                host->PropertiesChanged(host, kObjectID_Mute, 1, &addr);
            }
            return kAudioHardwareNoError;
        }
        break;
    default: break;
    }

    return kAudioHardwareUnsupportedOperationError;
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

static OSStatus SGDriver_StartIO(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inDeviceObjectID,
                                 UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    gState.ioStatus      = kAudioHardwareNoError;
    gState.startHostTime = mach_absolute_time();
    gState.frameCount    = 0;
    pthread_mutex_unlock(&gState.mutex);

    // Always re-map SHM on StartIO so the driver picks up the current segment.
    // The app may have restarted since Initialize (creating a new SHM segment);
    // without re-mapping the driver would read from the old orphaned segment
    // and see only zeros — delivering permanent silence to consumers.
    SG_SHM_Close();
    SG_SHM_Open();

    // Reset sequential read pointer to current writePos so we don't
    // replay stale audio from a previous session.
    gReadPos = gState.shmBuf
               ? atomic_load_explicit(&gState.shmBuf->writePos, memory_order_acquire)
               : 0;

    // Notify the app that a consumer has started reading (ADR 0012).
    notify_post(SG_NOTIFY_ACTIVE);
    SGLog("StartIO: consumer active — notified %s", SG_NOTIFY_ACTIVE);

    return kAudioHardwareNoError;
}

static OSStatus SGDriver_StopIO(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inDeviceObjectID,
                                UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    gState.ioStatus = kAudioHardwareIllegalOperationError;
    pthread_mutex_unlock(&gState.mutex);

    // Notify the app that the consumer stopped (ADR 0012).
    notify_post(SG_NOTIFY_INACTIVE);
    SGLog("StopIO: consumer inactive — notified %s", SG_NOTIFY_INACTIVE);

    return kAudioHardwareNoError;
}

// GetZeroTimeStamp: report the sample time and corresponding host time for the
// most recent period boundary.  outHostTime must advance correctly so coreaudiod
// can track the virtual clock rate and avoid repeated ADAPT cycles.
static OSStatus SGDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          Float64 *outSampleTime,
                                          UInt64 *outHostTime,
                                          UInt64 *outSeed)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gState.mutex);
    UInt64 fc = gState.frameCount;
    UInt64 st = gState.startHostTime;
    pthread_mutex_unlock(&gState.mutex);

    // Floor frameCount to the nearest period boundary.
    UInt64 periodNum = fc / kZeroTimeStampPeriod;
    Float64 zeroSampleTime = (Float64)(periodNum * kZeroTimeStampPeriod);

    // Compute the host time that corresponds to this zero sample time.
    // zeroSampleTime frames at kSampleRate = zeroSampleTime / kSampleRate seconds
    //   = zeroSampleTime * 1e9 / kSampleRate nanoseconds
    //   = ns * (denom / numer) mach absolute time units.
    double ns = (double)zeroSampleTime / kSampleRate * 1.0e9;
    UInt64 machOffset = (UInt64)(ns * (double)gMachTimebaseInfo.denom
                                    / (double)gMachTimebaseInfo.numer);

    *outSampleTime = zeroSampleTime;
    *outHostTime   = st + machOffset;
    *outSeed       = 1;     // constant: no discontinuities in our virtual clock
    return kAudioHardwareNoError;
}

static OSStatus SGDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID,
                                           UInt32 inOperationID,
                                           Boolean *outWillDo,
                                           Boolean *outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    *outWillDo        = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus SGDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

// DoIOOperation: called per I/O cycle per channel (non-interleaved, 2 channels).
// ioMainBuffer is a flat float* for inIOBufferFrameSize mono samples.
// Mono device: 1 channel, no interleaving, no ABL header.
// ---------------------------------------------------------------------------

static uint32_t gDoIOCallCount = 0;

// DoIOOperation for a mono input device.
//
// ioMainBuffer is a flat float* for inIOBufferFrameSize samples.
// Fill with mono mix (L+R)/2 from the SHM ring buffer.
static OSStatus SGDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       AudioObjectID inStreamObjectID,
                                       UInt32 inClientID,
                                       UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                       void *ioMainBuffer,
                                       void *ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID;
    (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID != kAudioServerPlugInIOOperationReadInput)
        return kAudioHardwareNoError;

    if (ioMainBuffer == NULL)
        return kAudioHardwareNoError;

    gDoIOCallCount++;

    AudioBufferList *abl    = (AudioBufferList *)ioMainBuffer;
    SHMAudioBuffer  *shm   = gState.shmBuf;
    uint32_t         frames = inIOBufferFrameSize;
    uint64_t         w      = shm ? atomic_load_explicit(&shm->writePos, memory_order_acquire) : 0;

    // Sequential consumer model: read from gReadPos, advance by frames.
    // This avoids the "latest-frame" repetition that occurred when the writer
    // (IOProc, 512 frames/10.67ms) and reader (DoIO, 192 frames/4ms) run at
    // different granularities — previously the same 192 frames were delivered
    // 2-3 times before the next write, causing robotic stuttering.
    float *out = (float *)ioMainBuffer;

    if (shm != NULL && (w - gReadPos) >= (uint64_t)frames) {
        // Enough new data — read sequentially and advance.
        for (uint32_t i = 0u; i < frames; i++) {
            uint64_t slot = (gReadPos + i) % SG_SHM_CAPACITY;
            out[i] = (shm->samples[slot * 2u] + shm->samples[slot * 2u + 1u]) * 0.5f;
        }
        gReadPos += frames;
    } else {
        // Underrun: not enough new data yet — emit silence.
        memset(out, 0, frames * sizeof(float));
    }

    // Diagnostic: log every ~500 calls (~5 s).
    if (gDoIOCallCount % 500 == 1) {
        SGLog("DoIO #%u: frames=%u writePos=%llu readPos=%llu buffered=%llu",
              gDoIOCallCount, frames, (unsigned long long)w,
              (unsigned long long)gReadPos,
              (unsigned long long)(w - gReadPos));
    }

    // Advance the frame counter once per IO cycle.
    pthread_mutex_lock(&gState.mutex);
    gState.frameCount += frames;
    pthread_mutex_unlock(&gState.mutex);

    return kAudioHardwareNoError;
}

static OSStatus SGDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
