// Standalone diagnostic (not part of the SwiftPM package): proves
// whether real audio reaches the driver's shared-memory ring buffer
// end to end. See test_shm_flow.swift's header comment for the plan —
// rewritten in C because Swift can't call shm_open (it's declared
// variadic in the Darwin header, which Swift refuses to bridge at all,
// even when the variadic arg is unused).
#include <CoreAudio/AudioHardware.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static CFStringRef CopyStringProperty(AudioObjectID objectID, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, &value);
    return value;
}

static AudioObjectID GetDefaultOutputDevice(void)
{
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID deviceID = 0;
    UInt32 size = sizeof(deviceID);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceID);
    return deviceID;
}

static OSStatus SetDefaultOutputDevice(AudioObjectID deviceID)
{
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(deviceID), &deviceID);
}

int main(int argc, char** argv)
{
    // argv[1] = device UID to target (default: main "SoundCast" device);
    // argv[2] = that device's shared-memory name (default matches the
    // main device). Generalized so this one tool can test any of the
    // 5 static device slots (design doc §7.3), not just the main one.
    const char* targetUID = (argc > 1) ? argv[1] : "com.soundcast.device";
    const char* shmName = (argc > 2) ? argv[2] : "/soundcast_output_v1";

    AudioObjectPropertyAddress devicesAddress = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 dataSize = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &dataSize);
    UInt32 count = dataSize / sizeof(AudioObjectID);
    AudioObjectID* ids = malloc(dataSize);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &dataSize, ids);

    AudioObjectID targetID = 0;
    for (UInt32 i = 0; i < count; i++) {
        CFStringRef uid = CopyStringProperty(ids[i], kAudioDevicePropertyDeviceUID);
        if (uid != NULL) {
            char buf[256];
            if (CFStringGetCString(uid, buf, sizeof(buf), kCFStringEncodingUTF8) && strcmp(buf, targetUID) == 0) {
                targetID = ids[i];
                CFRelease(uid);
                break;
            }
            CFRelease(uid);
        }
    }
    free(ids);

    if (targetID == 0) {
        printf("FAIL: device with UID '%s' not found in the Core Audio device list.\n", targetUID);
        return 1;
    }
    printf("Found device '%s', AudioObjectID = %u\n", targetUID, targetID);

    // Direct diagnostic: query BufferFrameSize ourselves, independent
    // of whatever "FetchAndLogFrameSize" in the system log is actually
    // reading, to isolate whether our driver's own property response
    // is the problem or something else entirely.
    {
        AudioObjectPropertyAddress addr = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 bfs = 0xFFFFFFFF;
        UInt32 size = sizeof(bfs);
        OSStatus st = AudioObjectGetPropertyData(targetID, &addr, 0, NULL, &size, &bfs);
        printf("Direct query, scope=output: BufferFrameSize=%u, status=%d\n", bfs, (int)st);
        addr.mScope = kAudioObjectPropertyScopeGlobal;
        bfs = 0xFFFFFFFF;
        size = sizeof(bfs);
        st = AudioObjectGetPropertyData(targetID, &addr, 0, NULL, &size, &bfs);
        printf("Direct query, scope=global: BufferFrameSize=%u, status=%d\n", bfs, (int)st);
    }

    AudioObjectID originalDefault = GetDefaultOutputDevice();
    printf("Original default output device ID: %u\n", originalDefault);

    OSStatus setStatus = SetDefaultOutputDevice(targetID);
    printf("Set default output to SoundCast: status=%d\n", (int)setStatus);
    if (setStatus != noErr) {
        printf("FAIL: could not set default output device.\n");
        return 1;
    }

    // StartIO (and therefore the shared memory segment's creation)
    // only fires once something actually begins using the device as
    // output — so play the first sound, THEN open the shared memory,
    // not before.
    printf("Playing a short system sound through it (brief, restoring your output right after)...\n");
    system("/usr/bin/afplay /System/Library/Sounds/Ping.aiff");
    usleep(300000);

    int fd = shm_open(shmName, O_RDONLY);
    if (fd < 0) {
        printf("FAIL: could not open shared memory even after playback (errno=%d: %s)\n", errno, strerror(errno));
        SetDefaultOutputDevice(originalDefault);
        return 1;
    }
    void* mapped = mmap(NULL, 20, PROT_READ, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        printf("FAIL: mmap failed, errno=%d\n", errno);
        SetDefaultOutputDevice(originalDefault);
        return 1;
    }
    uint32_t* header = (uint32_t*)mapped;
    uint32_t afterFirstPlay = header[1]; // writeIndexFrames
    printf("writeIndexFrames after first play: %u\n", afterFirstPlay);

    // Play again now that shm is confirmed open, to get a clean before/after delta.
    system("/usr/bin/afplay /System/Library/Sounds/Ping.aiff");
    usleep(300000);
    uint32_t afterSecondPlay = header[1];
    printf("writeIndexFrames after second play: %u\n", afterSecondPlay);

    SetDefaultOutputDevice(originalDefault);
    printf("Restored original default output device (ID %u).\n", originalDefault);

    if (afterFirstPlay > 0 || afterSecondPlay > afterFirstPlay) {
        printf("PASS: driver wrote real frames into shared memory (first play: %u, delta from second: %u) — the audio path works end to end.\n",
               afterFirstPlay, afterSecondPlay - afterFirstPlay);
        return 0;
    } else {
        printf("FAIL: writeIndexFrames stayed at 0 — DoIOOperation may not be firing or writing correctly.\n");
        return 1;
    }
}
