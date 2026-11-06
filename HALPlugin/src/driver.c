/*
 * SoundCastDriver — AudioServerPlugIn publishing multiple virtual
 * output devices ("SoundCast" + 4 presets, design doc §7.1/§7.3).
 * Any app/system that selects one of these as its output device has
 * its audio written here via
 * DoIOOperation(kAudioServerPlugInIOOperationWriteMix), which we copy
 * into that device's OWN POSIX shared-memory ring buffer — each device
 * is fully independent, so different apps can simultaneously target
 * different presets (e.g. one app → "SoundCast - Preset 1" routed to
 * the living room, another → "SoundCast - Preset 2" routed elsewhere).
 * The SoundCast.app menu bar app reads each ring buffer separately and
 * fans each out to whichever rooms that preset is assigned to.
 *
 * Room presets use a STATIC table (fixed at compile time), not dynamic
 * CreateDevice/DestroyDevice calls — design doc §7.3 flagged dynamic
 * device creation as the less-traveled, riskier part of this API, and
 * given how much iteration even the ONE static device needed to get
 * working correctly (§7.2's three-fix chase), a fixed table of a
 * generous-enough number of slots is the pragmatic choice over an
 * untested dynamic-creation path.
 *
 * All struct layouts, UUIDs, and property selector values below were
 * copied/verified field-for-field against this exact Mac's installed
 * Xcode 26.5 SDK headers (CoreAudio.framework/Headers/AudioServerPlugIn.h
 * and AudioHardwareBase.h), not from memory — see design doc §7.2 for
 * the earlier go/no-go test that proved coreaudiod will load a
 * self-signed bundle like this one on this Mac.
 *
 * Object model (fixed, static):
 *   AudioObjectID 1 = the plug-in itself (kAudioObjectPlugInObject, host-defined)
 *   Each slot below contributes one device object ID and one stream object ID.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>

// kAudioDevicePropertyBufferFrameSize/Range live in AudioHardware.h (the
// client-facing HAL API header), which AudioServerPlugIn.h doesn't pull
// in — defined directly here from their confirmed FourCC values,
// verified against this Mac's AudioHardware.h, rather than adding a
// broader header dependency a plugin shouldn't need.
#ifndef kAudioDevicePropertyBufferFrameSize
#define kAudioDevicePropertyBufferFrameSize 'fsiz'
#endif
#ifndef kAudioDevicePropertyBufferFrameSizeRange
#define kAudioDevicePropertyBufferFrameSizeRange 'fsz#'
#endif
// Same situation as above: AudioHardware.h-only selectors, FourCCs
// verified against the SDK. Defined after the includes so they can't
// shadow anything a header declares.
#ifndef kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
#define kAudioDevicePropertyDeviceCanBeDefaultSystemDevice 'sflt'
#endif
#ifndef kAudioDevicePropertyPreferredChannelsForStereo
#define kAudioDevicePropertyPreferredChannelsForStereo 'dch2'
#endif
#include <fcntl.h>
#include <pthread.h>
#include <syslog.h>
#include <stdatomic.h>
#include <string.h>
#include <errno.h>
#include <stdbool.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma mark - Device constants (shared across all slots)

static const UInt32 kDeviceSampleRate = 48000;
static const UInt32 kDeviceChannelCount = 2;
static const UInt32 kDeviceBufferFrameSizeMin = 1;
static const UInt32 kDeviceBufferFrameSizeMax = 4096;
// kAudioDevicePropertyZeroTimeStampPeriod — required for a plugin-hosted
// virtual device with a synthetic clock (declared directly in
// AudioServerPlugIn.h, not just AudioHardwareBase.h, specifically for
// this reason). Doc comment states a hard minimum of 10923 sample
// frames; 16384 is comfortably above that. This, ClockDomain, IsHidden,
// and the stream's TerminalType were the actual root cause of the
// original single-device "frame size is 0" / 'nope' failure chased
// across several earlier, wrong fix attempts — see design doc §7 for
// the full story.
static const UInt32 kDeviceZeroTimeStampPeriod = 16384;

#pragma mark - Shared memory ring buffer (one independent instance per device slot)

// Reader (SoundCast.app) tracks its own read position locally — the
// driver only ever publishes a monotonically increasing write counter.
// Unsigned-wraparound subtraction on the reader side
// ((uint32_t)(writeIndex - readIndex)) handles the eventual counter
// wrap correctly as long as the two never drift by more than 2^31
// frames apart, which no realistic buffering scenario approaches.
#define SOUNDCAST_SHM_CAPACITY_FRAMES (48000u * 4u) // 4 seconds at 48kHz

typedef struct {
    _Atomic uint32_t initialized;
    _Atomic uint32_t writeIndexFrames;
    uint32_t capacityFrames;
    uint32_t channelCount;
    uint32_t sampleRateHz;
    float ring[SOUNDCAST_SHM_CAPACITY_FRAMES * 2]; // channelCount fixed at 2 for this struct's static sizing
} SoundCastSharedRing;

#pragma mark - Device slot table

typedef struct {
    AudioObjectID deviceID;
    AudioObjectID streamID;
    CFStringRef name;
    CFStringRef uid;
    const char* shmName;
    // Backed by a real variable (not a shared constant) because each
    // slot negotiates its own buffer size independently — one app using
    // "SoundCast" at a small buffer shouldn't force a different app on
    // "SoundCast - Preset 1" to the same size.
    _Atomic UInt32 currentBufferFrameSize;
    // Written once under sharedRingInitLock, read lock-free on the IO
    // thread — hence atomic (release on store, acquire on load).
    _Atomic(SoundCastSharedRing*) sharedRing; // NULL until this slot's first StartIO
    pthread_mutex_t sharedRingInitLock;
    // Synthetic device clock: anchored at the host time of the first
    // StartIO, then derived purely from elapsed host time (see
    // GetZeroTimeStamp). startCount lets multiple clients start/stop IO.
    _Atomic uint64_t anchorHostTime;
    _Atomic uint32_t startCount;
} SoundCastDeviceSlot;

// Saved in Initialize so property changes can be announced to the host.
static AudioServerPlugInHostRef gHost = NULL;

#define NUM_SOUNDCAST_DEVICES 5

static SoundCastDeviceSlot gDeviceSlots[NUM_SOUNDCAST_DEVICES] = {
    { 2, 3, CFSTR("SoundCast"), CFSTR("com.soundcast.device"),
      "/soundcast_output_v1", 512, NULL, PTHREAD_MUTEX_INITIALIZER },
    { 4, 5, CFSTR("SoundCast - Preset 1"), CFSTR("com.soundcast.device.preset1"),
      "/soundcast_output_preset1", 512, NULL, PTHREAD_MUTEX_INITIALIZER },
    { 6, 7, CFSTR("SoundCast - Preset 2"), CFSTR("com.soundcast.device.preset2"),
      "/soundcast_output_preset2", 512, NULL, PTHREAD_MUTEX_INITIALIZER },
    { 8, 9, CFSTR("SoundCast - Preset 3"), CFSTR("com.soundcast.device.preset3"),
      "/soundcast_output_preset3", 512, NULL, PTHREAD_MUTEX_INITIALIZER },
    { 10, 11, CFSTR("SoundCast - Preset 4"), CFSTR("com.soundcast.device.preset4"),
      "/soundcast_output_preset4", 512, NULL, PTHREAD_MUTEX_INITIALIZER },
};

static SoundCastDeviceSlot* SoundCastNull_FindSlotByDeviceID(AudioObjectID deviceID)
{
    for (int i = 0; i < NUM_SOUNDCAST_DEVICES; i++) {
        if (gDeviceSlots[i].deviceID == deviceID) { return &gDeviceSlots[i]; }
    }
    return NULL;
}

static SoundCastDeviceSlot* SoundCastNull_FindSlotByStreamID(AudioObjectID streamID)
{
    for (int i = 0; i < NUM_SOUNDCAST_DEVICES; i++) {
        if (gDeviceSlots[i].streamID == streamID) { return &gDeviceSlots[i]; }
    }
    return NULL;
}

// Only the main "SoundCast" device (slot 0) may become the system default
// output. The presets are for per-app routing: left default-eligible,
// coreaudiod picked "SoundCast - Preset 2" as the default output on its
// own after a restart, silencing the Mac. Apps can still select a preset
// explicitly in their own output picker.
static bool SoundCastNull_CanBeDefault(const SoundCastDeviceSlot* slot)
{
    return slot == &gDeviceSlots[0];
}

// Returns true if the slot has a usable ring afterwards. Every failure
// is logged (syslog -> Console.app, process coreaudiod) so a silent
// "selected the device, hear nothing" can be diagnosed.
//
// The segment is deliberately NOT unlinked/recreated if one already
// exists with the right size: an app that already mapped it keeps seeing
// live data across coreaudiod restarts. writeIndexFrames is left alone
// on reuse (readers compute (write - theirRead) with unsigned wraparound,
// so resetting it would look like a huge lag).
static bool SoundCastNull_EnsureSharedRing(SoundCastDeviceSlot* slot)
{
    pthread_mutex_lock(&slot->sharedRingInitLock);
    if (atomic_load_explicit(&slot->sharedRing, memory_order_acquire) == NULL) {
        const size_t totalSize = sizeof(SoundCastSharedRing);
        int fd = shm_open(slot->shmName, O_CREAT | O_RDWR, 0666);
        if (fd < 0) {
            syslog(LOG_ERR, "SoundCast driver: shm_open(%s) failed: errno %d", slot->shmName, errno);
        } else {
            struct stat st;
            bool fresh = false;
            if (fstat(fd, &st) == 0 && st.st_size != 0 && (size_t)st.st_size != totalSize) {
                // Stale segment from an incompatible layout: replace it.
                close(fd);
                shm_unlink(slot->shmName);
                fd = shm_open(slot->shmName, O_CREAT | O_RDWR, 0666);
                if (fd < 0) {
                    syslog(LOG_ERR, "SoundCast driver: shm_open(%s) after unlink failed: errno %d", slot->shmName, errno);
                }
                st.st_size = 0;
            }
            if (fd >= 0) {
                if (st.st_size == 0) {
                    // macOS only allows sizing a POSIX shm object once.
                    if (ftruncate(fd, (off_t)totalSize) != 0) {
                        syslog(LOG_ERR, "SoundCast driver: ftruncate(%s) failed: errno %d", slot->shmName, errno);
                        close(fd);
                        fd = -1;
                    }
                    fresh = true;
                }
            }
            if (fd >= 0) {
                // shm_open's mode is filtered by coreaudiod's umask;
                // make the segment openable by the (non-root) app.
                fchmod(fd, 0666);
                void* mapped = mmap(NULL, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
                if (mapped == MAP_FAILED) {
                    syslog(LOG_ERR, "SoundCast driver: mmap(%s) failed: errno %d", slot->shmName, errno);
                } else {
                    SoundCastSharedRing* ring = (SoundCastSharedRing*)mapped;
                    ring->capacityFrames = SOUNDCAST_SHM_CAPACITY_FRAMES;
                    ring->channelCount = kDeviceChannelCount;
                    ring->sampleRateHz = kDeviceSampleRate;
                    if (fresh) { atomic_store(&ring->writeIndexFrames, 0); }
                    atomic_store(&ring->initialized, 1);
                    atomic_store_explicit(&slot->sharedRing, ring, memory_order_release);
                }
                close(fd); // mapping stays valid after close
            }
        }
    }
    bool ok = atomic_load_explicit(&slot->sharedRing, memory_order_acquire) != NULL;
    pthread_mutex_unlock(&slot->sharedRingInitLock);
    return ok;
}

static void SoundCastNull_WriteFrames(SoundCastDeviceSlot* slot, const float* interleavedStereo, UInt32 frameCount)
{
    SoundCastSharedRing* ring = atomic_load_explicit(&slot->sharedRing, memory_order_acquire);
    if (ring == NULL) { return; }
    uint32_t capacity = ring->capacityFrames;
    uint32_t startFrame = atomic_load(&ring->writeIndexFrames) % capacity;

    uint32_t firstChunkFrames = frameCount;
    uint32_t wrapChunkFrames = 0;
    if (startFrame + frameCount > capacity) {
        firstChunkFrames = capacity - startFrame;
        wrapChunkFrames = frameCount - firstChunkFrames;
    }

    memcpy(&ring->ring[startFrame * kDeviceChannelCount],
           interleavedStereo,
           (size_t)firstChunkFrames * kDeviceChannelCount * sizeof(float));
    if (wrapChunkFrames > 0) {
        memcpy(&ring->ring[0],
               interleavedStereo + (size_t)firstChunkFrames * kDeviceChannelCount,
               (size_t)wrapChunkFrames * kDeviceChannelCount * sizeof(float));
    }

    atomic_fetch_add(&ring->writeIndexFrames, frameCount);
}

#pragma mark - Forward declarations (vtable field order, verified against the real SDK header)

static HRESULT SoundCastNull_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG SoundCastNull_AddRef(void* inDriver);
static ULONG SoundCastNull_Release(void* inDriver);
static OSStatus SoundCastNull_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SoundCastNull_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus SoundCastNull_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SoundCastNull_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SoundCastNull_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SoundCastNull_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus SoundCastNull_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean SoundCastNull_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SoundCastNull_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SoundCastNull_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SoundCastNull_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SoundCastNull_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus SoundCastNull_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SoundCastNull_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SoundCastNull_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus SoundCastNull_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus SoundCastNull_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus SoundCastNull_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus SoundCastNull_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - The interface singleton

static AudioServerPlugInDriverInterface gSoundCastNullInterface = {
    NULL,
    SoundCastNull_QueryInterface, SoundCastNull_AddRef, SoundCastNull_Release,
    SoundCastNull_Initialize,
    SoundCastNull_CreateDevice, SoundCastNull_DestroyDevice,
    SoundCastNull_AddDeviceClient, SoundCastNull_RemoveDeviceClient,
    SoundCastNull_PerformDeviceConfigurationChange, SoundCastNull_AbortDeviceConfigurationChange,
    SoundCastNull_HasProperty, SoundCastNull_IsPropertySettable,
    SoundCastNull_GetPropertyDataSize, SoundCastNull_GetPropertyData, SoundCastNull_SetPropertyData,
    SoundCastNull_StartIO, SoundCastNull_StopIO,
    SoundCastNull_GetZeroTimeStamp,
    SoundCastNull_WillDoIOOperation, SoundCastNull_BeginIOOperation,
    SoundCastNull_DoIOOperation, SoundCastNull_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gSoundCastNullInterfacePtr = &gSoundCastNullInterface;
static AudioServerPlugInDriverRef gSoundCastNullDriverRef = &gSoundCastNullInterfacePtr;
static _Atomic UInt32 gRefCount = 1;

#pragma mark - CFPlugIn factory entry point

void* SoundCastNullDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* SoundCastNullDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) { return NULL; }
    SoundCastNull_AddRef(gSoundCastNullDriverRef);
    return gSoundCastNullDriverRef;
}

#pragma mark - IUnknown

static HRESULT SoundCastNull_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    (void)inDriver;
    if (outInterface == NULL) { return E_POINTER; }
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requestedUUID == NULL) { return E_NOINTERFACE; }
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requestedUUID, IUnknownUUID) || CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        SoundCastNull_AddRef(gSoundCastNullDriverRef);
        *outInterface = gSoundCastNullDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
    }
    CFRelease(requestedUUID);
    return result;
}

static ULONG SoundCastNull_AddRef(void* inDriver) { (void)inDriver; return atomic_fetch_add(&gRefCount, 1) + 1; }
static ULONG SoundCastNull_Release(void* inDriver)
{
    (void)inDriver;
    // Never decrement below zero (an unbalanced Release must not wrap the count).
    UInt32 cur = atomic_load(&gRefCount);
    while (cur > 0 && !atomic_compare_exchange_weak(&gRefCount, &cur, cur - 1)) { }
    return cur > 0 ? cur - 1 : 0;
}

#pragma mark - Basic operations

static OSStatus SoundCastNull_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;
    return noErr;
}

static OSStatus SoundCastNull_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError; // static device table for this increment — see file header
}
static OSStatus SoundCastNull_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{ (void)inDriver; (void)inDeviceObjectID; return kAudioHardwareUnsupportedOperationError; }
static OSStatus SoundCastNull_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo; return noErr; }
static OSStatus SoundCastNull_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo; return noErr; }
static OSStatus SoundCastNull_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo; return kAudioHardwareUnsupportedOperationError; }
static OSStatus SoundCastNull_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo; return kAudioHardwareUnsupportedOperationError; }

#pragma mark - Property operations

static Boolean SoundCastNull_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    UInt32 sel = inAddress->mSelector;

    if (inObjectID == kAudioObjectPlugInObject) {
        return (sel == kAudioObjectPropertyBaseClass
                || sel == kAudioObjectPropertyClass || sel == kAudioObjectPropertyOwner
                || sel == kAudioObjectPropertyManufacturer || sel == kAudioObjectPropertyOwnedObjects
                || sel == kAudioPlugInPropertyDeviceList
                || sel == kAudioPlugInPropertyTranslateUIDToDevice);
    }
    if (SoundCastNull_FindSlotByDeviceID(inObjectID) != NULL) {
        return (sel == kAudioObjectPropertyBaseClass
                || sel == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
                || sel == kAudioDevicePropertyPreferredChannelsForStereo
                || sel == kAudioObjectPropertyClass || sel == kAudioObjectPropertyOwner
                || sel == kAudioObjectPropertyName || sel == kAudioObjectPropertyManufacturer
                || sel == kAudioObjectPropertyOwnedObjects || sel == kAudioObjectPropertyControlList
                || sel == kAudioDevicePropertyDeviceUID || sel == kAudioDevicePropertyDeviceIsAlive
                || sel == kAudioDevicePropertyDeviceCanBeDefaultDevice
                || sel == kAudioDevicePropertyLatency || sel == kAudioDevicePropertyStreams
                || sel == kAudioDevicePropertySafetyOffset || sel == kAudioDevicePropertyNominalSampleRate
                || sel == kAudioDevicePropertyAvailableNominalSampleRates
                || sel == kAudioDevicePropertyBufferFrameSize || sel == kAudioDevicePropertyBufferFrameSizeRange
                || sel == kAudioDevicePropertyTransportType
                || sel == kAudioDevicePropertyClockDomain || sel == kAudioDevicePropertyIsHidden
                || sel == kAudioDevicePropertyZeroTimeStampPeriod);
    }
    if (SoundCastNull_FindSlotByStreamID(inObjectID) != NULL) {
        return (sel == kAudioObjectPropertyBaseClass
                || sel == kAudioObjectPropertyClass || sel == kAudioObjectPropertyOwner
                || sel == kAudioStreamPropertyIsActive || sel == kAudioStreamPropertyDirection
                || sel == kAudioStreamPropertyStartingChannel || sel == kAudioStreamPropertyTerminalType
                || sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyAvailableVirtualFormats
                || sel == kAudioStreamPropertyPhysicalFormat || sel == kAudioStreamPropertyAvailablePhysicalFormats);
    }
    return false;
}

static OSStatus SoundCastNull_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    // BufferFrameSize must be settable — see design doc §7 for why
    // (hosts negotiate buffer size via Get *and* Set; this was the
    // actual root cause of the original single-device start failure).
    *outIsSettable = (SoundCastNull_FindSlotByDeviceID(inObjectID) != NULL
                       && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize);
    return noErr;
}

static void SoundCastNull_FillASBD(AudioStreamBasicDescription* f)
{
    f->mSampleRate = kDeviceSampleRate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    f->mBytesPerFrame = kDeviceChannelCount * sizeof(Float32);
    f->mFramesPerPacket = 1;
    f->mBytesPerPacket = f->mBytesPerFrame * f->mFramesPerPacket;
    f->mChannelsPerFrame = kDeviceChannelCount;
    f->mBitsPerChannel = 32;
    f->mReserved = 0;
}

// Shared by GetPropertyDataSize (reports it) and GetPropertyData (uses it
// to bounds-check the caller's buffer). Unknown objects/properties are
// reported as errors, never as a successful empty answer.
// OwnedObjects (and similar) queries carry a qualifier: a list of class IDs
// the caller wants. The HAL uses this to ask a device for its *controls*
// ('levl', 'slid', ...) separately from its streams. Answering with the
// stream for every qualifier made coreaudiod treat the stream as a control
// and throw ("creating a control with invalid class ID 0"). No qualifier
// means "everything"; kAudioObjectClassID matches any object.
static bool SoundCastNull_QualifierMatches(UInt32 qualifierSize, const void* qualifier, AudioClassID objectClass)
{
    if (qualifier == NULL || qualifierSize < sizeof(AudioClassID)) { return true; }
    const AudioClassID* classes = (const AudioClassID*)qualifier;
    UInt32 count = qualifierSize / (UInt32)sizeof(AudioClassID);
    for (UInt32 i = 0; i < count; i++) {
        if (classes[i] == objectClass || classes[i] == kAudioObjectClassID) { return true; }
    }
    return false;
}

static OSStatus SoundCastNull_PropertySize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    UInt32 sel = inAddress->mSelector;
    *outDataSize = 0;

    SoundCastDeviceSlot* deviceSlot = SoundCastNull_FindSlotByDeviceID(inObjectID);
    SoundCastDeviceSlot* streamSlot = SoundCastNull_FindSlotByStreamID(inObjectID);

    if (inObjectID != kAudioObjectPlugInObject && deviceSlot == NULL && streamSlot == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!SoundCastNull_HasProperty(NULL, inObjectID, 0, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioClassID); break;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); break;
            case kAudioObjectPropertyManufacturer: *outDataSize = sizeof(CFStringRef); break;
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = SoundCastNull_QualifierMatches(inQualifierDataSize, inQualifierData, kAudioDeviceClassID)
                    ? NUM_SOUNDCAST_DEVICES * sizeof(AudioObjectID) : 0;
                break;
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = NUM_SOUNDCAST_DEVICES * sizeof(AudioObjectID); break;
            default: break;
        }
    } else if (deviceSlot != NULL) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioClassID); break;
            case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); break;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); break;
            case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
                *outDataSize = sizeof(CFStringRef); break;
            case kAudioObjectPropertyOwnedObjects:
                // Only the stream is ours; a qualifier asking for controls matches nothing.
                *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput
                                || !SoundCastNull_QualifierMatches(inQualifierDataSize, inQualifierData, kAudioStreamClassID))
                    ? 0 : sizeof(AudioObjectID);
                break;
            case kAudioDevicePropertyStreams:
                // Must match GetPropertyData's scope handling below — a
                // host calling Size-then-Get for input scope (we have
                // no input capability) would otherwise get a 4-byte
                // size here but 0 bytes of actual data from Get.
                *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; break; // no volume/mute controls
            case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyBufferFrameSize: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); break;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); break;
            case kAudioDevicePropertyBufferFrameSizeRange: *outDataSize = sizeof(AudioValueRange); break;
            default: break;
        }
    } else if (streamSlot != NULL) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioClassID); break;
            case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyTerminalType:
                *outDataSize = sizeof(UInt32); break;
            case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); break;
            case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription); break;
            default: break;
        }
    }
    return noErr;
}

static OSStatus SoundCastNull_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inDriver; (void)inClientProcessID;
    return SoundCastNull_PropertySize(inObjectID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
}

static OSStatus SoundCastNull_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inDriver; (void)inClientProcessID;
    UInt32 sel = inAddress->mSelector;
    *outDataSize = 0;

    // Reject unknown objects/properties and undersized caller buffers
    // before anything is written to outData.
    UInt32 requiredSize = 0;
    OSStatus sizeStatus = SoundCastNull_PropertySize(inObjectID, inAddress, inQualifierDataSize, inQualifierData, &requiredSize);
    if (sizeStatus != noErr) { return sizeStatus; }
    if (inDataSize < requiredSize) { return kAudioHardwareBadPropertySizeError; }

    SoundCastDeviceSlot* deviceSlot = SoundCastNull_FindSlotByDeviceID(inObjectID);
    SoundCastDeviceSlot* streamSlot = SoundCastNull_FindSlotByStreamID(inObjectID);

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                // Qualifier is the device UID (CFString); answer is its object ID, or kAudioObjectUnknown.
                AudioObjectID found = kAudioObjectUnknown;
                if (inQualifierData != NULL && inQualifierDataSize == sizeof(CFStringRef)) {
                    CFStringRef uid = *(const CFStringRef*)inQualifierData;
                    for (int i = 0; uid != NULL && i < NUM_SOUNDCAST_DEVICES; i++) {
                        if (CFEqual(uid, gDeviceSlots[i].uid)) { found = gDeviceSlots[i].deviceID; break; }
                    }
                }
                *(AudioObjectID*)outData = found; *outDataSize = sizeof(AudioObjectID);
                break;
            }
            case kAudioObjectPropertyClass:
                *(AudioClassID*)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID*)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); break;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef*)outData = CFSTR("SoundCast"); *outDataSize = sizeof(CFStringRef); break;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                // requiredSize already reflects the qualifier filter (0 if it excludes devices).
                AudioObjectID* ids = (AudioObjectID*)outData;
                for (int i = 0; requiredSize > 0 && i < NUM_SOUNDCAST_DEVICES; i++) { ids[i] = gDeviceSlots[i].deviceID; }
                *outDataSize = requiredSize;
                break;
            }
            default: break;
        }
    } else if (deviceSlot != NULL) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *(UInt32*)outData = (inAddress->mScope != kAudioObjectPropertyScopeInput && SoundCastNull_CanBeDefault(deviceSlot)) ? 1 : 0;
                *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2;
                *outDataSize = 2 * sizeof(UInt32); break;
            case kAudioObjectPropertyClass:
                *(AudioClassID*)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID*)outData = kAudioObjectPlugInObject; *outDataSize = sizeof(AudioObjectID); break;
            case kAudioObjectPropertyName:
                *(CFStringRef*)outData = deviceSlot->name; *outDataSize = sizeof(CFStringRef); break;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef*)outData = CFSTR("SoundCast"); *outDataSize = sizeof(CFStringRef); break;
            case kAudioDevicePropertyDeviceUID:
                *(CFStringRef*)outData = deviceSlot->uid; *outDataSize = sizeof(CFStringRef); break;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                // Output-scope only has this device's one stream; input
                // scope (no input capability) and non-matching qualifiers
                // (e.g. a request for controls) correctly have none.
                // requiredSize already encodes all of that.
                if (requiredSize == 0) { *outDataSize = 0; }
                else { *(AudioObjectID*)outData = deviceSlot->streamID; *outDataSize = sizeof(AudioObjectID); }
                break;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; break;
            case kAudioDevicePropertyDeviceIsAlive:
                *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                *(UInt32*)outData = (inAddress->mScope != kAudioObjectPropertyScopeInput && SoundCastNull_CanBeDefault(deviceSlot)) ? 1 : 0;
                *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyBufferFrameSize:
                *(UInt32*)outData = atomic_load(&deviceSlot->currentBufferFrameSize); *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyBufferFrameSizeRange:
                ((AudioValueRange*)outData)->mMinimum = kDeviceBufferFrameSizeMin;
                ((AudioValueRange*)outData)->mMaximum = kDeviceBufferFrameSizeMax;
                *outDataSize = sizeof(AudioValueRange); break;
            case kAudioDevicePropertyTransportType:
                *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyClockDomain:
                *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyIsHidden:
                *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *(UInt32*)outData = kDeviceZeroTimeStampPeriod; *outDataSize = sizeof(UInt32); break;
            case kAudioDevicePropertyNominalSampleRate:
                *(Float64*)outData = (Float64)kDeviceSampleRate; *outDataSize = sizeof(Float64); break;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                ((AudioValueRange*)outData)->mMinimum = kDeviceSampleRate;
                ((AudioValueRange*)outData)->mMaximum = kDeviceSampleRate;
                *outDataSize = sizeof(AudioValueRange); break;
            default: break;
        }
    } else if (streamSlot != NULL) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioObjectPropertyClass:
                *(AudioClassID*)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); break;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID*)outData = streamSlot->deviceID; *outDataSize = sizeof(AudioObjectID); break;
            case kAudioStreamPropertyIsActive:
                *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); break;
            case kAudioStreamPropertyDirection:
                *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); break; // 0 = output, verified against SDK doc comment
            case kAudioStreamPropertyStartingChannel:
                *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); break;
            case kAudioStreamPropertyTerminalType:
                *(UInt32*)outData = kAudioStreamTerminalTypeSpeaker; *outDataSize = sizeof(UInt32); break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                SoundCastNull_FillASBD((AudioStreamBasicDescription*)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription); break;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
                SoundCastNull_FillASBD(&r->mFormat);
                r->mSampleRateRange.mMinimum = kDeviceSampleRate;
                r->mSampleRateRange.mMaximum = kDeviceSampleRate;
                *outDataSize = sizeof(AudioStreamRangedDescription); break;
            }
            default: break;
        }
    }
    return noErr;
}

static OSStatus SoundCastNull_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    SoundCastDeviceSlot* slot = SoundCastNull_FindSlotByDeviceID(inObjectID);
    if (slot != NULL && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize && inDataSize == sizeof(UInt32)) {
        UInt32 requested = *(const UInt32*)inData;
        if (requested < kDeviceBufferFrameSizeMin) { requested = kDeviceBufferFrameSizeMin; }
        if (requested > kDeviceBufferFrameSizeMax) { requested = kDeviceBufferFrameSizeMax; }
        UInt32 previous = atomic_exchange(&slot->currentBufferFrameSize, requested);
        if (previous != requested && gHost != NULL) {
            AudioObjectPropertyAddress changed = { kAudioDevicePropertyBufferFrameSize,
                                                   kAudioObjectPropertyScopeGlobal,
                                                   kAudioObjectPropertyElementMain };
            gHost->PropertiesChanged(gHost, inObjectID, 1, &changed);
        }
        return noErr;
    }
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO operations

static OSStatus SoundCastNull_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    SoundCastDeviceSlot* slot = SoundCastNull_FindSlotByDeviceID(inDeviceObjectID);
    if (slot == NULL) { return kAudioHardwareBadObjectError; }
    // Fail loudly rather than "start" a device whose audio goes nowhere
    // (the reason is already in syslog from EnsureSharedRing).
    if (!SoundCastNull_EnsureSharedRing(slot)) { return kAudioHardwareUnspecifiedError; }
    // First start anchors the synthetic clock to the current host time.
    if (atomic_fetch_add(&slot->startCount, 1) == 0) {
        atomic_store(&slot->anchorHostTime, mach_absolute_time());
    }
    return noErr;
}

static OSStatus SoundCastNull_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    SoundCastDeviceSlot* slot = SoundCastNull_FindSlotByDeviceID(inDeviceObjectID);
    if (slot == NULL) { return kAudioHardwareBadObjectError; }
    // Never decrement below zero; mapping is kept — see EnsureSharedRing's note.
    UInt32 cur = atomic_load(&slot->startCount);
    while (cur > 0 && !atomic_compare_exchange_weak(&slot->startCount, &cur, cur - 1)) { }
    return noErr;
}

static OSStatus SoundCastNull_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    // Synthetic clock driven purely by elapsed host time since StartIO
    // (NOT by how much audio has been written — that would be circular,
    // since the host schedules IO from this clock). Each call reports the
    // most recent multiple of kDeviceZeroTimeStampPeriod frames, paired
    // with the host time at which that sample time occurred. Returning an
    // error here broke AudioDeviceStart entirely (design doc §7).
    SoundCastDeviceSlot* slot = SoundCastNull_FindSlotByDeviceID(inDeviceObjectID);
    if (slot == NULL) { return kAudioHardwareBadObjectError; }

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    // Host ticks per one zero-timestamp period.
    const Float64 ticksPerPeriod = ((Float64)kDeviceZeroTimeStampPeriod / (Float64)kDeviceSampleRate)
                                   * 1000000000.0 * ((Float64)tb.denom / (Float64)tb.numer);

    UInt64 now = mach_absolute_time();
    UInt64 anchor = atomic_load(&slot->anchorHostTime);
    if (anchor == 0 || now < anchor) { anchor = now; } // not started yet / clock skew guard
    UInt64 periods = (UInt64)((Float64)(now - anchor) / ticksPerPeriod);

    *outSampleTime = (Float64)(periods * (UInt64)kDeviceZeroTimeStampPeriod);
    *outHostTime = anchor + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus SoundCastNull_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    // WriteMix is the operation we actually act on (DoIOOperation
    // copies audio out of it). Thread/Cycle are IO-lifecycle
    // bookkeeping operations, not data operations — acknowledging them
    // defensively since the host's start-up sequencing turned out to
    // care about more than just the data operations (see GetZeroTimeStamp).
    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix
                       || inOperationID == kAudioServerPlugInIOOperationThread
                       || inOperationID == kAudioServerPlugInIOOperationCycle);
    *outWillDo = willDo;
    *outWillDoInPlace = true; // we only read ioMainBuffer, never need a secondary buffer
    return noErr;
}

static OSStatus SoundCastNull_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo; return noErr; }

static OSStatus SoundCastNull_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && ioMainBuffer != NULL) {
        SoundCastDeviceSlot* slot = SoundCastNull_FindSlotByDeviceID(inDeviceObjectID);
        if (slot != NULL) {
            SoundCastNull_WriteFrames(slot, (const float*)ioMainBuffer, inIOBufferFrameSize);
        }
    }
    return noErr;
}

static OSStatus SoundCastNull_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo; return noErr; }
