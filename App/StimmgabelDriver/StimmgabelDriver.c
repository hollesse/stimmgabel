// StimmgabelDriver.c
// Audio Server Plugin walking skeleton for Stimmgabel.
//
// Produces silence (all-zero samples) at 48 kHz, float32, stereo (non-interleaved).
// This is the spike implementation — no IPC/ring buffer yet. Real audio sourcing
// comes in a later feature task.
//
// Reference: Apple AudioServerPlugIn.h, Apple SampleAudioDevice example,
// Background Music BGMDriver.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define kDeviceUID           "com.innoq.stimmgabel.virtualmic"
#define kDeviceName          "Stimmgabel"
#define kManufacturerName    "INNOQ"
#define kBoxUID              "com.innoq.stimmgabel.box"

#define kSampleRate          48000.0
#define kChannelCount        2u
#define kBytesPerSample      4u     // float32
#define kFramesPerPacket     1u
#define kBytesPerFrame       (kChannelCount * kBytesPerSample)
// ZeroTimeStamp period in frames — how many frames between successive zero timestamps
#define kZeroTimeStampPeriod 512u

// Fixed object IDs assigned by this plug-in
#define kObjectID_PlugIn     1u
#define kObjectID_Box        2u
#define kObjectID_Device     3u
#define kObjectID_Stream     4u
#define kObjectID_Mute       5u

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
} SGDriverState;

static SGDriverState gState;

// ---------------------------------------------------------------------------
// Forward declarations (match the vtable signatures exactly)
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
    if (memcmp(&inUUID, kInterfaceBytes, 16) == 0) {
        *outInterface = gDriverRef;
        return S_OK;
    }
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
    pthread_mutex_lock(&gState.mutex);
    gState.hostRef = inHost;
    pthread_mutex_unlock(&gState.mutex);
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

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default: return false;
        }

    case kObjectID_Box:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyDeviceList:
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

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle: *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:   *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Box:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:     *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioBoxPropertyBoxUID:       *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioBoxPropertyAcquired:     *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioBoxPropertyDeviceList:   *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
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
        case kAudioDevicePropertyStreams:   *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        case kAudioDevicePropertyIcon: *outDataSize = sizeof(CFURLRef); return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 s = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
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
    f.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel   = 32;
    f.mChannelsPerFrame = kChannelCount;
    f.mBytesPerFrame    = kBytesPerSample;      // non-interleaved: per-channel frame size
    f.mFramesPerPacket  = kFramesPerPacket;
    f.mBytesPerPacket   = kBytesPerSample;
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
        case kAudioPlugInPropertyBoxList:
            *outDataSize = sizeof(AudioObjectID);
            ((AudioObjectID*)outData)[0] = kObjectID_Box;
            return kAudioHardwareNoError;
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

    // --- Box ---
    case kObjectID_Box:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioBoxClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kObjectID_PlugIn); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:      WCF(CFSTR(kDeviceName)); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer: WCF(CFSTR(kManufacturerName)); return kAudioHardwareNoError;
        case kAudioBoxPropertyBoxUID:       WCF(CFSTR(kBoxUID)); return kAudioHardwareNoError;
        case kAudioBoxPropertyAcquired:     WU32(1); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioBoxPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            ((AudioObjectID*)outData)[0] = kObjectID_Device;
            return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }

    // --- Device ---
    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: WU32(kAudioObjectClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:     WU32(kAudioDeviceClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:     WU32(kObjectID_Box); return kAudioHardwareNoError;
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
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:        WU32(1); return kAudioHardwareNoError;
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
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyStreams:
            *outDataSize = sizeof(AudioObjectID);
            ((AudioObjectID*)outData)[0] = kObjectID_Stream;
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
            UInt32 sz = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
            AudioChannelLayout *l = (AudioChannelLayout*)outData;
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mChannelBitmap    = 0;
            l->mNumberChannelDescriptions = kChannelCount;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            l->mChannelDescriptions[0].mChannelFlags = 0;
            l->mChannelDescriptions[0].mCoordinates[0] = 0;
            l->mChannelDescriptions[0].mCoordinates[1] = 0;
            l->mChannelDescriptions[0].mCoordinates[2] = 0;
            l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            l->mChannelDescriptions[1].mChannelFlags = 0;
            l->mChannelDescriptions[1].mCoordinates[0] = 0;
            l->mChannelDescriptions[1].mCoordinates[1] = 0;
            l->mChannelDescriptions[1].mCoordinates[2] = 0;
            *outDataSize = sz;
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
        // Only one sample rate supported; silently accept.
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
            return kAudioHardwareNoError;
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
    return kAudioHardwareNoError;
}

// GetZeroTimeStamp has three output params: sample time, host time, seed
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

    *outSampleTime = (Float64)(fc - (fc % kZeroTimeStampPeriod));
    *outHostTime   = st;
    *outSeed       = 1;
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

// DoIOOperation has an extra ioSecondaryBuffer parameter vs the old signature
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

    // Emit silence — spike does not source real samples yet.
    if (ioMainBuffer != NULL)
        memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kBytesPerSample);

    pthread_mutex_lock(&gState.mutex);
    gState.frameCount += inIOBufferFrameSize;
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
