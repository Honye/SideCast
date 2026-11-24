//
//  DriverTests.c
//  SideCast
//
//  Exercises the audio driver through its plug-in interface with a fake Core Audio host, without
//  installing it. Run with Driver/Tests/run-tests.sh.
//

#include "../Source/SideCastAudioDriver.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int gFailures = 0;
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); gFailures++; } } while (0)

#pragma mark - Fake host

static CFMutableDictionaryRef gStorage;
static int gDeviceListNotifications = 0;
static AudioObjectID gLastChangedObject = 0;

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress addresses[]) {
    (void)host;
    for (UInt32 i = 0; i < count; i++) {
        if (objectID == kAudioObjectPlugInObject && addresses[i].mSelector == kAudioPlugInPropertyDeviceList) gDeviceListNotifications++;
    }
    gLastChangedObject = objectID;
    return noErr;
}

static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *outData) {
    (void)host;
    CFPropertyListRef value = CFDictionaryGetValue(gStorage, key);
    *outData = value ? CFRetain(value) : NULL;
    return noErr;
}

static OSStatus HostWriteToStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) {
    (void)host;
    CFDictionarySetValue(gStorage, key, data);
    return noErr;
}

static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host;
    CFDictionaryRemoveValue(gStorage, key);
    return noErr;
}

static OSStatus HostRequestConfigurationChange(AudioServerPlugInHostRef host, AudioObjectID device, UInt64 action, void *info) {
    (void)host; (void)device; (void)action; (void)info;
    return noErr;
}

static AudioServerPlugInHostInterface gHostInterface = {
    HostPropertiesChanged,
    HostCopyFromStorage,
    HostWriteToStorage,
    HostDeleteFromStorage,
    HostRequestConfigurationChange,
};

#pragma mark - Helpers

static AudioServerPlugInDriverRef gDriver;

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    return address;
}

static OSStatus Get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, UInt32 qualifierSize, const void *qualifier, UInt32 size, void *data, UInt32 *outSize) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    UInt32 written = 0;
    OSStatus status = (*gDriver)->GetPropertyData(gDriver, object, 0, &address, qualifierSize, qualifier, size, &written, data);
    if (outSize) *outSize = written;
    return status;
}

static UInt32 GetUInt32(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    UInt32 value = 0xFFFFFFFF;
    Get(object, selector, scope, 0, NULL, sizeof value, &value, NULL);
    return value;
}

static Float32 GetFloat32(AudioObjectID object, AudioObjectPropertySelector selector) {
    Float32 value = NAN;
    Get(object, selector, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof value, &value, NULL);
    return value;
}

static OSStatus Set(AudioObjectID object, AudioObjectPropertySelector selector, UInt32 size, const void *data) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    return (*gDriver)->SetPropertyData(gDriver, object, 0, &address, 0, NULL, size, data);
}

static UInt32 DeviceList(AudioObjectID *ids) {
    UInt32 size = 0;
    Get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(AudioObjectID) * kSideCastMaxDevices, ids, &size);
    return size / sizeof(AudioObjectID);
}

static AudioObjectID Translate(CFStringRef uid) {
    AudioObjectID device = 0xFFFFFFFF;
    Get(kAudioObjectPlugInObject, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, sizeof uid, &uid, sizeof device, &device, NULL);
    return device;
}

static CFStringRef CopyString(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    Get(object, selector, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof value, &value, NULL);
    return value;
}

static bool StringIs(CFStringRef value, const char *expected) {
    CFStringRef wanted = CFStringCreateWithCString(NULL, expected, kCFStringEncodingUTF8);
    bool equal = value && CFEqual(value, wanted);
    CFRelease(wanted);
    return equal;
}

static void Publish(int count, const char *const *uids, const char *const *names) {
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        CFStringRef uid = CFStringCreateWithCString(NULL, uids[i], kCFStringEncodingUTF8);
        CFStringRef name = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
        const void *keys[] = { CFSTR("uid"), CFSTR("name") };
        const void *values[] = { uid, name };
        CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(list, entry);
        CFRelease(entry);
        CFRelease(uid);
        CFRelease(name);
    }
    CFPropertyListRef value = list;
    CHECK(Set(kAudioObjectPlugInObject, kSideCastPropertyDevices, sizeof value, &value) == noErr);
    CFRelease(list);
}

/// Waits for notifications the driver sends from its queue.
static void Settle(void) {
    usleep(100000);
}

#define UID_A kSideCastDeviceUIDPrefix "AAAA"
#define UID_B kSideCastDeviceUIDPrefix "BBBB"

#pragma mark - Tests

static void TestLoading(void) {
    void *created = SideCastAudioDriver_Create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(created != NULL);
    CHECK(SideCastAudioDriver_Create(NULL, kAudioServerPlugInDriverInterfaceUUID) == NULL);
    AudioServerPlugInDriverRef driver = NULL;
    CFUUIDBytes interfaceID = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    CHECK((*(AudioServerPlugInDriverRef)created)->QueryInterface(created, interfaceID, (void **)&driver) == S_OK);
    CHECK(driver == created);
    gDriver = driver;
    CHECK((*gDriver)->Initialize(gDriver, &gHostInterface) == noErr);

    AudioObjectID ids[kSideCastMaxDevices];
    CHECK(DeviceList(ids) == 0);
    CHECK(GetUInt32(kAudioObjectPlugInObject, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioPlugInClassID);
    CFStringRef version = CopyString(kAudioObjectPlugInObject, kSideCastPropertyVersion);
    char expected[16];
    snprintf(expected, sizeof expected, "%d", kSideCastDriverVersion);
    CHECK(StringIs(version, expected));
    if (version) CFRelease(version);

    AudioServerPlugInCustomPropertyInfo info[4];
    UInt32 size = 0;
    Get(kAudioObjectPlugInObject, kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof info, info, &size);
    CHECK(size == 2 * sizeof(AudioServerPlugInCustomPropertyInfo));
    CHECK(info[0].mSelector == kSideCastPropertyDevices && info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);

    AudioObjectPropertyAddress devices = Address(kSideCastPropertyDevices, kAudioObjectPropertyScopeGlobal);
    Boolean settable = false;
    CHECK((*gDriver)->IsPropertySettable(gDriver, kAudioObjectPlugInObject, 0, &devices, &settable) == noErr && settable);
    CHECK((*gDriver)->HasProperty(gDriver, kAudioObjectPlugInObject, 0, &devices));
}

static void TestPublishing(void) {
    const char *uids[] = { UID_A, UID_B, "someone.else.device", UID_A };
    const char *names[] = { "iPad (SideCast)", "iPhone (SideCast)", "Not ours", "Duplicate" };
    int before = gDeviceListNotifications;
    Publish(4, uids, names);
    Settle();
    CHECK(gDeviceListNotifications == before + 1);

    AudioObjectID ids[kSideCastMaxDevices];
    CHECK(DeviceList(ids) == 2);
    AudioObjectID a = Translate(CFSTR(UID_A));
    AudioObjectID b = Translate(CFSTR(UID_B));
    CHECK(a == ids[0] && b == ids[1]);
    CHECK(Translate(CFSTR("missing")) == kAudioObjectUnknown);

    CFStringRef name = CopyString(a, kAudioObjectPropertyName);
    CHECK(StringIs(name, "iPad (SideCast)"));
    if (name) CFRelease(name);
    CFStringRef uid = CopyString(b, kAudioDevicePropertyDeviceUID);
    CHECK(StringIs(uid, UID_B));
    if (uid) CFRelease(uid);

    CHECK(GetUInt32(a, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioDeviceClassID);
    CHECK(GetUInt32(a, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual);
    CHECK(GetUInt32(a, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 1);
    CHECK(GetUInt32(a, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 0);

    // Republishing the same list changes nothing.
    before = gDeviceListNotifications;
    const char *same[] = { UID_A, UID_B };
    const char *sameNames[] = { "iPad (SideCast)", "iPhone (SideCast)" };
    Publish(2, same, sameNames);
    Settle();
    CHECK(gDeviceListNotifications == before);
    CHECK(Translate(CFSTR(UID_A)) == a);
}

static void TestStreamsAndControls(void) {
    AudioObjectID device = Translate(CFSTR(UID_A));
    AudioObjectID streams[2];
    UInt32 size = 0;
    Get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, NULL, sizeof streams, streams, &size);
    CHECK(size == sizeof(AudioObjectID));
    Get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, NULL, sizeof streams, streams + 1, &size);
    CHECK(size == 0);
    AudioObjectID stream = streams[0];
    CHECK(GetUInt32(stream, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioStreamClassID);
    CHECK(GetUInt32(stream, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0);

    AudioStreamBasicDescription format;
    Get(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof format, &format, NULL);
    CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32);
    CHECK(Set(stream, kAudioStreamPropertyVirtualFormat, sizeof format, &format) == noErr);
    format.mSampleRate = 44100;
    CHECK(Set(stream, kAudioStreamPropertyVirtualFormat, sizeof format, &format) == kAudioDeviceUnsupportedFormatError);

    // Owned objects, filtered by class.
    AudioObjectID owned[4];
    AudioClassID volumeClass = kAudioVolumeControlClassID;
    Get(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof owned, owned, &size);
    CHECK(size == 3 * sizeof(AudioObjectID));
    Get(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, sizeof volumeClass, &volumeClass, sizeof owned, owned, &size);
    CHECK(size == sizeof(AudioObjectID));
    AudioObjectID volume = owned[0];
    AudioClassID muteClass = kAudioMuteControlClassID;
    Get(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, sizeof muteClass, &muteClass, sizeof owned, owned, &size);
    AudioObjectID mute = owned[0];
    CHECK(GetUInt32(volume, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioVolumeControlClassID);
    CHECK(GetUInt32(mute, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioMuteControlClassID);
    CHECK(GetUInt32(volume, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal) == kAudioObjectPropertyScopeOutput);

    // Volume starts at full and maps scalar <-> decibels.
    CHECK(GetFloat32(volume, kAudioLevelControlPropertyScalarValue) == 1.0f);
    CHECK(GetFloat32(volume, kAudioLevelControlPropertyDecibelValue) == 0.0f);
    Float32 half = 0.5f;
    CHECK(Set(volume, kAudioLevelControlPropertyScalarValue, sizeof half, &half) == noErr);
    CHECK(gLastChangedObject == volume);
    CHECK(fabsf(GetFloat32(volume, kAudioLevelControlPropertyDecibelValue) - (40.0f * log10f(0.5f))) < 0.01f);
    Float32 floor = kSideCastMinDecibels;
    CHECK(Set(volume, kAudioLevelControlPropertyDecibelValue, sizeof floor, &floor) == noErr);
    CHECK(GetFloat32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f);
    Float32 convert = 0.25f;
    Get(volume, kAudioLevelControlPropertyConvertScalarToDecibels, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof convert, &convert, NULL);
    CHECK(fabsf(convert - (40.0f * log10f(0.25f))) < 0.01f);
    Float32 tooLoud = 3.0f;
    CHECK(Set(volume, kAudioLevelControlPropertyScalarValue, sizeof tooLoud, &tooLoud) == noErr);
    CHECK(GetFloat32(volume, kAudioLevelControlPropertyScalarValue) == 1.0f);

    // Settle on 0.7 and muted, which should be stored.
    Float32 stored = 0.7f;
    Set(volume, kAudioLevelControlPropertyScalarValue, sizeof stored, &stored);
    UInt32 on = 1;
    CHECK(Set(mute, kAudioBooleanControlPropertyValue, sizeof on, &on) == noErr);
    CHECK(GetUInt32(mute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 1);

    // Read-only properties refuse to be set.
    Float64 rate = 44100;
    CHECK(Set(device, kAudioDevicePropertyNominalSampleRate, sizeof rate, &rate) == kAudioHardwareUnsupportedOperationError);
    CHECK(Set(9999, kAudioObjectPropertyName, sizeof rate, &rate) == kAudioHardwareBadObjectError);
}

static void TestRemoveRestoreRename(void) {
    AudioObjectID oldA = Translate(CFSTR(UID_A));
    const char *onlyB[] = { UID_B };
    const char *onlyBName[] = { "iPhone (SideCast)" };
    int before = gDeviceListNotifications;
    Publish(1, onlyB, onlyBName);
    Settle();
    CHECK(gDeviceListNotifications == before + 1);
    AudioObjectID ids[kSideCastMaxDevices];
    CHECK(DeviceList(ids) == 1);
    CHECK(Translate(CFSTR(UID_A)) == kAudioObjectUnknown);
    CHECK(GetUInt32(oldA, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == 0xFFFFFFFF);

    // A comes back with a new object ID and its saved volume and mute.
    const char *both[] = { UID_B, UID_A };
    const char *bothNames[] = { "iPhone (SideCast)", "Jun's iPad (SideCast)" };
    Publish(2, both, bothNames);
    Settle();
    AudioObjectID a = Translate(CFSTR(UID_A));
    CHECK(a != kAudioObjectUnknown && a != oldA);
    AudioObjectID owned[1];
    AudioClassID volumeClass = kAudioVolumeControlClassID;
    Get(a, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, sizeof volumeClass, &volumeClass, sizeof owned, owned, NULL);
    CHECK(fabsf(GetFloat32(owned[0], kAudioLevelControlPropertyScalarValue) - 0.7f) < 0.001f);
    AudioClassID muteClass = kAudioMuteControlClassID;
    Get(a, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, sizeof muteClass, &muteClass, sizeof owned, owned, NULL);
    CHECK(GetUInt32(owned[0], kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 1);

    // Renaming keeps the device and tells the host.
    AudioObjectID b = Translate(CFSTR(UID_B));
    const char *renamed[] = { "Living Room iPhone (SideCast)", "Jun's iPad (SideCast)" };
    before = gDeviceListNotifications;
    Publish(2, both, renamed);
    Settle();
    CHECK(gDeviceListNotifications == before);
    CHECK(Translate(CFSTR(UID_B)) == b);
    CHECK(gLastChangedObject == b);
    CFStringRef name = CopyString(b, kAudioObjectPropertyName);
    CHECK(StringIs(name, "Living Room iPhone (SideCast)"));
    if (name) CFRelease(name);

    // The list reads back.
    CFArrayRef list = NULL;
    Get(kAudioObjectPlugInObject, kSideCastPropertyDevices, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof list, &list, NULL);
    CHECK(list && CFArrayGetCount(list) == 2);
    if (list) CFRelease(list);
}

static void TestClock(void) {
    AudioObjectID device = Translate(CFSTR(UID_A));
    CHECK((*gDriver)->StartIO(gDriver, device, 1) == noErr);
    CHECK(GetUInt32(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1);
    Float64 sampleTime = -1;
    UInt64 hostTime = 0, seed = 0;
    CHECK((*gDriver)->GetZeroTimeStamp(gDriver, device, 1, &sampleTime, &hostTime, &seed) == noErr);
    CHECK(sampleTime == 0 && seed == 1);
    usleep((useconds_t)(1e6 * kSideCastZeroTimeStampPeriod / kSideCastSampleRate) + 50000);
    UInt64 firstHostTime = hostTime;
    CHECK((*gDriver)->GetZeroTimeStamp(gDriver, device, 1, &sampleTime, &hostTime, &seed) == noErr);
    CHECK(sampleTime == kSideCastZeroTimeStampPeriod);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double seconds = (double)(hostTime - firstHostTime) * timebase.numer / timebase.denom / 1e9;
    CHECK(fabs(seconds - kSideCastZeroTimeStampPeriod / kSideCastSampleRate) < 0.001);

    Boolean willDo = false, inPlace = false;
    (*gDriver)->WillDoIOOperation(gDriver, device, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
    CHECK(willDo);
    (*gDriver)->WillDoIOOperation(gDriver, device, 1, kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace);
    CHECK(!willDo);
    CHECK((*gDriver)->StopIO(gDriver, device, 1) == noErr);
    CHECK(GetUInt32(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0);
}

static void TestHeartbeat(void) {
    // Built with a 1 s timeout; the driver checks every 2 s.
    AudioObjectID ids[kSideCastMaxDevices];
    CHECK(DeviceList(ids) == 2);
    sleep(5);
    CHECK(DeviceList(ids) == 0);
}

int main(void) {
    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    TestLoading();
    TestPublishing();
    TestStreamsAndControls();
    TestRemoveRestoreRename();
    TestClock();
    TestHeartbeat();
    if (gFailures) {
        fprintf(stderr, "%d check(s) failed\n", gFailures);
        return 1;
    }
    printf("All driver tests passed\n");
    return 0;
}
