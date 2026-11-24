//
//  SideCastAudioDriver.c
//  SideCast
//
//  An AudioServerPlugIn that publishes one output device per connected SideCast receiver, so
//  receivers show up in macOS Sound settings and the menu bar sound menu.
//
//  The devices are silent sinks: they keep time and discard what they are given. SideCast picks
//  up the audio sent to them with a Core Audio process tap on the device and streams it to the
//  receiver. The volume and mute controls are only stored here; SideCast reads them and applies
//  them to the stream.
//
//  The app tells the driver which devices to publish through a custom property on the plug-in
//  object (see SideCastAudioDriver.h).
//

#include "SideCastAudioDriver.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#pragma mark - State

typedef struct {
    bool active;
    AudioObjectID device;
    AudioObjectID stream;
    AudioObjectID volume;
    AudioObjectID mute;
    CFStringRef uid;
    CFStringRef name;
    Float32 volumeScalar;
    bool muted;
    bool streamActive;
    UInt32 ioClients;
    UInt64 anchorHostTime;
    UInt64 timestampCount;
} Device;

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static Device gDevices[kSideCastMaxDevices];
static AudioObjectID gNextObjectID = 100;
static UInt64 gLastHeartbeat = 0;
static Float64 gHostTicksPerFrame = 0;
static Float64 gHostTicksPerSecond = 0;
static dispatch_queue_t gQueue = NULL;
static dispatch_source_t gHeartbeatTimer = NULL;
static os_log_t gLog = NULL;

#pragma mark - Helpers

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = kSideCastSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(Float32) * kSideCastChannels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * kSideCastChannels;
    format.mChannelsPerFrame = kSideCastChannels;
    format.mBitsPerChannel = 32;
    return format;
}

static bool IsOurFormat(const AudioStreamBasicDescription *format) {
    AudioStreamBasicDescription ours = StreamFormat();
    return format->mSampleRate == ours.mSampleRate
        && format->mFormatID == ours.mFormatID
        && format->mFormatFlags == ours.mFormatFlags
        && format->mChannelsPerFrame == ours.mChannelsPerFrame
        && format->mBitsPerChannel == ours.mBitsPerChannel;
}

static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar <= 0) return kSideCastMinDecibels;
    if (scalar >= 1) return kSideCastMaxDecibels;
    Float32 decibels = 40.0f * log10f(scalar);
    return decibels < kSideCastMinDecibels ? kSideCastMinDecibels : decibels;
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (decibels <= kSideCastMinDecibels) return 0;
    if (decibels >= kSideCastMaxDecibels) return 1;
    return powf(10.0f, decibels / 40.0f);
}

static Float32 Clamp01(Float32 value) {
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

/// Called with gLock held.
static Device *DeviceWithID(AudioObjectID objectID) {
    for (int i = 0; i < kSideCastMaxDevices; i++) {
        if (gDevices[i].active && gDevices[i].device == objectID) return &gDevices[i];
    }
    return NULL;
}

typedef enum { KindNone, KindPlugIn, KindDevice, KindStream, KindVolume, KindMute } Kind;

/// Called with gLock held.
static Kind Resolve(AudioObjectID objectID, Device **outDevice) {
    *outDevice = NULL;
    if (objectID == kAudioObjectPlugInObject) return KindPlugIn;
    for (int i = 0; i < kSideCastMaxDevices; i++) {
        Device *device = &gDevices[i];
        if (!device->active) continue;
        *outDevice = device;
        if (objectID == device->device) return KindDevice;
        if (objectID == device->stream) return KindStream;
        if (objectID == device->volume) return KindVolume;
        if (objectID == device->mute) return KindMute;
    }
    *outDevice = NULL;
    return KindNone;
}

/// Whether an object of `objectClass` is a `requestedClass`, following the class hierarchy.
static bool ClassIsA(AudioClassID objectClass, AudioClassID requestedClass) {
    if (objectClass == requestedClass || requestedClass == kAudioObjectClassID) return true;
    switch (objectClass) {
    case kAudioVolumeControlClassID:
        return requestedClass == kAudioLevelControlClassID || requestedClass == kAudioControlClassID;
    case kAudioMuteControlClassID:
        return requestedClass == kAudioBooleanControlClassID || requestedClass == kAudioControlClassID;
    default:
        return false;
    }
}

/// Whether an object passes a kAudioObjectPropertyOwnedObjects class qualifier.
static bool PassesQualifier(AudioClassID objectClass, UInt32 qualifierSize, const void *qualifier) {
    UInt32 count = qualifierSize / sizeof(AudioClassID);
    if (count == 0 || qualifier == NULL) return true;
    const AudioClassID *classes = qualifier;
    for (UInt32 i = 0; i < count; i++) {
        if (ClassIsA(objectClass, classes[i])) return true;
    }
    return false;
}

static CFStringRef StorageKey(CFStringRef uid) {
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("volume.%@"), uid);
}

#pragma mark - Replies

/// Destination for a property value; `data` is NULL when only the size is wanted.
typedef struct {
    void *data;
    UInt32 capacity;
    UInt32 size;
} Reply;

static OSStatus ReplyBytes(Reply *reply, const void *bytes, UInt32 size) {
    if (reply->data) {
        if (reply->capacity < size) return kAudioHardwareBadPropertySizeError;
        memcpy(reply->data, bytes, size);
    }
    reply->size = size;
    return noErr;
}

static OSStatus ReplyUInt32(Reply *reply, UInt32 value) { return ReplyBytes(reply, &value, sizeof value); }
static OSStatus ReplyFloat32(Reply *reply, Float32 value) { return ReplyBytes(reply, &value, sizeof value); }
static OSStatus ReplyFloat64(Reply *reply, Float64 value) { return ReplyBytes(reply, &value, sizeof value); }

/// Replies with a CF object; the caller gets its own reference.
static OSStatus ReplyCF(Reply *reply, CFTypeRef value) {
    if (reply->data) {
        if (reply->capacity < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
        if (value) CFRetain(value);
        *(CFTypeRef *)reply->data = value;
    }
    reply->size = sizeof(CFTypeRef);
    return noErr;
}

/// Replies with an array; it is truncated to the space given, as Core Audio expects.
static OSStatus ReplyArray(Reply *reply, const void *items, UInt32 itemSize, UInt32 count) {
    if (reply->data) {
        UInt32 fits = reply->capacity / itemSize;
        if (fits < count) count = fits;
        if (count > 0) memcpy(reply->data, items, (size_t)itemSize * count);
    }
    reply->size = itemSize * count;
    return noErr;
}

#pragma mark - Properties

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, Reply *reply) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        return ReplyUInt32(reply, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        return ReplyUInt32(reply, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner:
        return ReplyUInt32(reply, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer:
        return ReplyCF(reply, CFSTR("SideCast"));
    case kAudioPlugInPropertyResourceBundle:
        return ReplyCF(reply, CFSTR(""));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[kSideCastMaxDevices];
        UInt32 count = 0;
        bool filtered = address->mSelector == kAudioObjectPropertyOwnedObjects;
        for (int i = 0; i < kSideCastMaxDevices; i++) {
            if (!gDevices[i].active) continue;
            if (filtered && !PassesQualifier(kAudioDeviceClassID, qualifierSize, qualifier)) continue;
            ids[count++] = gDevices[i].device;
        }
        return ReplyArray(reply, ids, sizeof(AudioObjectID), count);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (reply->data) {
            if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            for (int i = 0; uid && i < kSideCastMaxDevices; i++) {
                if (gDevices[i].active && CFEqual(gDevices[i].uid, uid)) found = gDevices[i].device;
            }
        }
        return ReplyUInt32(reply, found);
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info[2] = {
            { kSideCastPropertyDevices, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
            { kSideCastPropertyVersion, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone },
        };
        return ReplyArray(reply, info, sizeof(AudioServerPlugInCustomPropertyInfo), 2);
    }
    case kSideCastPropertyVersion: {
        if (!reply->data) return ReplyCF(reply, NULL);
        CFStringRef version = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), kSideCastDriverVersion);
        OSStatus status = ReplyCF(reply, version);
        CFRelease(version);
        return status;
    }
    case kSideCastPropertyDevices: {
        if (!reply->data) return ReplyCF(reply, NULL);
        CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (int i = 0; i < kSideCastMaxDevices; i++) {
            if (!gDevices[i].active) continue;
            const void *keys[] = { CFSTR("uid"), CFSTR("name") };
            const void *values[] = { gDevices[i].uid, gDevices[i].name };
            CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(list, entry);
            CFRelease(entry);
        }
        OSStatus status = ReplyCF(reply, list);
        CFRelease(list);
        return status;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(Device *device, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, Reply *reply) {
    bool input = address->mScope == kAudioObjectPropertyScopeInput;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        return ReplyUInt32(reply, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        return ReplyUInt32(reply, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner:
        return ReplyUInt32(reply, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName:
        return ReplyCF(reply, device->name);
    case kAudioObjectPropertyManufacturer:
        return ReplyCF(reply, CFSTR("SideCast"));
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID ids[3];
        UInt32 count = 0;
        if (!input) {
            if (PassesQualifier(kAudioStreamClassID, qualifierSize, qualifier)) ids[count++] = device->stream;
            if (PassesQualifier(kAudioVolumeControlClassID, qualifierSize, qualifier)) ids[count++] = device->volume;
            if (PassesQualifier(kAudioMuteControlClassID, qualifierSize, qualifier)) ids[count++] = device->mute;
        }
        return ReplyArray(reply, ids, sizeof(AudioObjectID), count);
    }
    case kAudioDevicePropertyStreams: {
        AudioObjectID stream = device->stream;
        return ReplyArray(reply, &stream, sizeof stream, input ? 0 : 1);
    }
    case kAudioObjectPropertyControlList: {
        AudioObjectID ids[2] = { device->volume, device->mute };
        return ReplyArray(reply, ids, sizeof(AudioObjectID), 2);
    }
    case kAudioDevicePropertyDeviceUID:
        return ReplyCF(reply, device->uid);
    case kAudioDevicePropertyModelUID:
        return ReplyCF(reply, CFSTR("com.imarkr.SideCast.receiver"));
    case kAudioDevicePropertyConfigurationApplication:
        return ReplyCF(reply, CFSTR("com.imarkr.SideCast"));
    case kAudioDevicePropertyTransportType:
        return ReplyUInt32(reply, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID self = device->device;
        return ReplyArray(reply, &self, sizeof self, 1);
    }
    case kAudioDevicePropertyClockDomain:
        return ReplyUInt32(reply, 0);
    case kAudioDevicePropertyDeviceIsAlive:
        return ReplyUInt32(reply, 1);
    case kAudioDevicePropertyDeviceIsRunning:
        return ReplyUInt32(reply, device->ioClients > 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        return ReplyUInt32(reply, input ? 0 : 1);
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
        return ReplyUInt32(reply, 0);
    case kAudioDevicePropertyNominalSampleRate:
        return ReplyFloat64(reply, kSideCastSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = { kSideCastSampleRate, kSideCastSampleRate };
        return ReplyArray(reply, &range, sizeof range, 1);
    }
    case kAudioDevicePropertyIsHidden:
        return ReplyUInt32(reply, 0);
    case kAudioDevicePropertyClockIsStable:
        return ReplyUInt32(reply, 1);
    case kAudioDevicePropertyZeroTimeStampPeriod:
        return ReplyUInt32(reply, kSideCastZeroTimeStampPeriod);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 channels[2] = { 1, 2 };
        return ReplyBytes(reply, channels, sizeof channels);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt8 storage[offsetof(AudioChannelLayout, mChannelDescriptions) + 2 * sizeof(AudioChannelDescription)];
        memset(storage, 0, sizeof storage);
        AudioChannelLayout *layout = (AudioChannelLayout *)storage;
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = 2;
        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        return ReplyBytes(reply, storage, sizeof storage);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(Device *device, const AudioObjectPropertyAddress *address, Reply *reply) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        return ReplyUInt32(reply, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        return ReplyUInt32(reply, kAudioStreamClassID);
    case kAudioObjectPropertyOwner:
        return ReplyUInt32(reply, device->device);
    case kAudioObjectPropertyOwnedObjects:
        return ReplyArray(reply, NULL, sizeof(AudioObjectID), 0);
    case kAudioStreamPropertyIsActive:
        return ReplyUInt32(reply, device->streamActive);
    case kAudioStreamPropertyDirection:
        return ReplyUInt32(reply, 0); // output
    case kAudioStreamPropertyTerminalType:
        return ReplyUInt32(reply, kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel:
        return ReplyUInt32(reply, 1);
    case kAudioStreamPropertyLatency:
        return ReplyUInt32(reply, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription format = StreamFormat();
        return ReplyBytes(reply, &format, sizeof format);
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription format = { StreamFormat(), { kSideCastSampleRate, kSideCastSampleRate } };
        return ReplyArray(reply, &format, sizeof format, 1);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ControlProperty(Device *device, Kind kind, const AudioObjectPropertyAddress *address, Reply *reply) {
    bool volume = kind == KindVolume;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        return ReplyUInt32(reply, volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass:
        return ReplyUInt32(reply, volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner:
        return ReplyUInt32(reply, device->device);
    case kAudioObjectPropertyOwnedObjects:
        return ReplyArray(reply, NULL, sizeof(AudioObjectID), 0);
    case kAudioControlPropertyScope:
        return ReplyUInt32(reply, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement:
        return ReplyUInt32(reply, kAudioObjectPropertyElementMain);
    default:
        break;
    }
    if (!volume) {
        if (address->mSelector == kAudioBooleanControlPropertyValue) return ReplyUInt32(reply, device->muted);
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
    case kAudioLevelControlPropertyScalarValue:
        return ReplyFloat32(reply, device->volumeScalar);
    case kAudioLevelControlPropertyDecibelValue:
        return ReplyFloat32(reply, ScalarToDecibels(device->volumeScalar));
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange range = { kSideCastMinDecibels, kSideCastMaxDecibels };
        return ReplyBytes(reply, &range, sizeof range);
    }
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar: {
        // The value to convert comes in the same buffer.
        Float32 value = 0;
        if (reply->data) {
            if (reply->capacity < sizeof value) return kAudioHardwareBadPropertySizeError;
            value = *(Float32 *)reply->data;
            value = address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
                ? ScalarToDecibels(Clamp01(value))
                : DecibelsToScalar(value);
        }
        return ReplyFloat32(reply, value);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

/// Answers a property question. Called with gLock held.
static OSStatus Property(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, Reply *reply) {
    Device *device = NULL;
    Kind kind = Resolve(objectID, &device);
    switch (kind) {
    case KindPlugIn:
        return PlugInProperty(address, qualifierSize, qualifier, reply);
    case KindDevice:
        return DeviceProperty(device, address, qualifierSize, qualifier, reply);
    case KindStream:
        return StreamProperty(device, address, reply);
    case KindVolume:
    case KindMute:
        return ControlProperty(device, kind, address, reply);
    case KindNone:
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareBadObjectError;
}

static bool Settable(Kind kind, AudioObjectPropertySelector selector) {
    switch (kind) {
    case KindPlugIn:
        return selector == kSideCastPropertyDevices;
    case KindStream:
        return selector == kAudioStreamPropertyIsActive
            || selector == kAudioStreamPropertyVirtualFormat
            || selector == kAudioStreamPropertyPhysicalFormat;
    case KindVolume:
        return selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue;
    case KindMute:
        return selector == kAudioBooleanControlPropertyValue;
    default:
        return false;
    }
}

#pragma mark - Device list

static void NotifyDeviceListChanged(void) {
    AudioServerPlugInHostRef host = gHost;
    if (!host) return;
    dispatch_async(gQueue, ^{
        AudioObjectPropertyAddress addresses[2] = {
            { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        host->PropertiesChanged(host, kAudioObjectPlugInObject, 2, addresses);
    });
}

static void NotifyNameChanged(AudioObjectID deviceID) {
    AudioServerPlugInHostRef host = gHost;
    if (!host) return;
    dispatch_async(gQueue, ^{
        AudioObjectPropertyAddress address = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        host->PropertiesChanged(host, deviceID, 1, &address);
    });
}

/// Reads a device's saved volume and mute from the host's storage.
static void LoadStoredVolume(AudioObjectID deviceID, CFStringRef uid) {
    if (!gHost || !gHost->CopyFromStorage) return;
    CFStringRef key = StorageKey(uid);
    CFPropertyListRef stored = NULL;
    gHost->CopyFromStorage(gHost, key, &stored);
    CFRelease(key);
    if (!stored) return;
    if (CFGetTypeID(stored) == CFDictionaryGetTypeID()) {
        Float32 volume = 1;
        CFNumberRef number = CFDictionaryGetValue(stored, CFSTR("volume"));
        CFBooleanRef muted = CFDictionaryGetValue(stored, CFSTR("muted"));
        bool hasVolume = number && CFGetTypeID(number) == CFNumberGetTypeID() && CFNumberGetValue(number, kCFNumberFloat32Type, &volume);
        pthread_mutex_lock(&gLock);
        Device *device = DeviceWithID(deviceID);
        if (device) {
            if (hasVolume) device->volumeScalar = Clamp01(volume);
            if (muted && CFGetTypeID(muted) == CFBooleanGetTypeID()) device->muted = CFBooleanGetValue(muted);
        }
        pthread_mutex_unlock(&gLock);
    }
    CFRelease(stored);
}

static void SaveVolume(CFStringRef uid, Float32 volume, bool muted) {
    if (!gHost || !gHost->WriteToStorage) return;
    CFStringRef key = StorageKey(uid);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat32Type, &volume);
    const void *keys[] = { CFSTR("volume"), CFSTR("muted") };
    const void *values[] = { number, muted ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef dictionary = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    gHost->WriteToStorage(gHost, key, dictionary);
    CFRelease(dictionary);
    CFRelease(number);
    CFRelease(key);
}

typedef struct {
    CFStringRef uid;
    CFStringRef name;
} Entry;

/// Parses the app's device list. Returns how many valid entries were copied into `entries`.
static UInt32 ParseDeviceList(CFPropertyListRef list, Entry *entries) {
    if (!list || CFGetTypeID(list) != CFArrayGetTypeID()) return 0;
    CFIndex total = CFArrayGetCount(list);
    UInt32 count = 0;
    CFStringRef prefix = CFSTR(kSideCastDeviceUIDPrefix);
    for (CFIndex i = 0; i < total && count < kSideCastMaxDevices; i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(list, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFStringRef uid = CFDictionaryGetValue(item, CFSTR("uid"));
        CFStringRef name = CFDictionaryGetValue(item, CFSTR("name"));
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || !CFStringHasPrefix(uid, prefix)) continue;
        if (!name || CFGetTypeID(name) != CFStringGetTypeID() || CFStringGetLength(name) == 0) continue;
        bool duplicate = false;
        for (UInt32 j = 0; j < count; j++) {
            if (CFEqual(entries[j].uid, uid)) duplicate = true;
        }
        if (duplicate) continue;
        entries[count].uid = CFStringCreateCopy(NULL, uid);
        entries[count].name = CFStringCreateCopy(NULL, name);
        count++;
    }
    return count;
}

/// Publishes exactly the given devices: keeps existing ones, adds new ones, removes the rest.
static void ApplyDeviceList(Entry *entries, UInt32 count) {
    CFStringRef released[2 * kSideCastMaxDevices];
    UInt32 releasedCount = 0;
    AudioObjectID added[kSideCastMaxDevices];
    CFStringRef addedUIDs[kSideCastMaxDevices];
    UInt32 addedCount = 0;
    AudioObjectID renamed[kSideCastMaxDevices];
    UInt32 renamedCount = 0;
    bool changed = false;

    pthread_mutex_lock(&gLock);
    gLastHeartbeat = mach_absolute_time();
    // Remove devices that are no longer listed.
    for (int i = 0; i < kSideCastMaxDevices; i++) {
        Device *device = &gDevices[i];
        if (!device->active) continue;
        bool listed = false;
        for (UInt32 j = 0; j < count; j++) {
            if (CFEqual(entries[j].uid, device->uid)) listed = true;
        }
        if (listed) continue;
        device->active = false;
        released[releasedCount++] = device->uid;
        released[releasedCount++] = device->name;
        device->uid = NULL;
        device->name = NULL;
        changed = true;
    }
    // Rename or add the listed ones.
    for (UInt32 j = 0; j < count; j++) {
        Device *existing = NULL;
        for (int i = 0; i < kSideCastMaxDevices; i++) {
            if (gDevices[i].active && CFEqual(gDevices[i].uid, entries[j].uid)) existing = &gDevices[i];
        }
        if (existing) {
            if (!CFEqual(existing->name, entries[j].name)) {
                released[releasedCount++] = existing->name;
                existing->name = CFRetain(entries[j].name);
                renamed[renamedCount++] = existing->device;
            }
            continue;
        }
        Device *slot = NULL;
        for (int i = 0; i < kSideCastMaxDevices && !slot; i++) {
            if (!gDevices[i].active) slot = &gDevices[i];
        }
        if (!slot) break;
        memset(slot, 0, sizeof *slot);
        slot->active = true;
        slot->device = gNextObjectID++;
        slot->stream = gNextObjectID++;
        slot->volume = gNextObjectID++;
        slot->mute = gNextObjectID++;
        slot->uid = CFRetain(entries[j].uid);
        slot->name = CFRetain(entries[j].name);
        slot->volumeScalar = 1;
        slot->streamActive = true;
        added[addedCount] = slot->device;
        addedUIDs[addedCount] = CFRetain(entries[j].uid);
        addedCount++;
        changed = true;
    }
    pthread_mutex_unlock(&gLock);

    for (UInt32 i = 0; i < releasedCount; i++) {
        if (released[i]) CFRelease(released[i]);
    }
    for (UInt32 i = 0; i < addedCount; i++) {
        LoadStoredVolume(added[i], addedUIDs[i]);
        CFRelease(addedUIDs[i]);
    }
    for (UInt32 i = 0; i < renamedCount; i++) {
        NotifyNameChanged(renamed[i]);
    }
    if (changed) {
        if (gLog) os_log(gLog, "SideCast audio driver now publishes %u device(s)", count);
        NotifyDeviceListChanged();
    }
}

static void CheckHeartbeat(void) {
    pthread_mutex_lock(&gLock);
    bool any = false;
    for (int i = 0; i < kSideCastMaxDevices; i++) {
        if (gDevices[i].active) any = true;
    }
    Float64 elapsed = (Float64)(mach_absolute_time() - gLastHeartbeat) / gHostTicksPerSecond;
    pthread_mutex_unlock(&gLock);
    if (any && elapsed > kSideCastHeartbeatTimeout) {
        if (gLog) os_log(gLog, "SideCast stopped updating its devices; removing them");
        ApplyDeviceList(NULL, 0);
    }
}

#pragma mark - Interface

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePointer;

void *SideCastAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gLock);
        gRefCount++;
        pthread_mutex_unlock(&gLock);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gLock);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gLock);
    return count;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gLock);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gLock);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gLog = os_log_create(kSideCastDriverBundleID, "driver");

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = gHostTicksPerSecond / kSideCastSampleRate;
    gLastHeartbeat = mach_absolute_time();

    gQueue = dispatch_queue_create(kSideCastDriverBundleID, DISPATCH_QUEUE_SERIAL);
    gHeartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gHeartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gHeartbeatTimer, ^{ CheckHeartbeat(); });
    dispatch_resume(gHeartbeatTimer);
    os_log(gLog, "SideCast audio driver %d loaded", kSideCastDriverVersion);
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress) return false;
    Reply reply = {0};
    pthread_mutex_lock(&gLock);
    OSStatus status = Property(inObjectID, inAddress, 0, NULL, &reply);
    pthread_mutex_unlock(&gLock);
    return status == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    Reply reply = {0};
    pthread_mutex_lock(&gLock);
    Device *device = NULL;
    Kind kind = Resolve(inObjectID, &device);
    OSStatus status = Property(inObjectID, inAddress, 0, NULL, &reply);
    pthread_mutex_unlock(&gLock);
    if (status != noErr) return status;
    *outIsSettable = Settable(kind, inAddress->mSelector);
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    Reply reply = {0};
    pthread_mutex_lock(&gLock);
    OSStatus status = Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, &reply);
    pthread_mutex_unlock(&gLock);
    if (status == noErr) *outDataSize = reply.size;
    return status;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    Reply reply = { outData, inDataSize, 0 };
    pthread_mutex_lock(&gLock);
    OSStatus status = Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, &reply);
    pthread_mutex_unlock(&gLock);
    if (status == noErr) *outDataSize = reply.size;
    return status;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gLock);
    Device *device = NULL;
    Kind kind = Resolve(inObjectID, &device);
    if (kind == KindNone) {
        pthread_mutex_unlock(&gLock);
        return kAudioHardwareBadObjectError;
    }
    if (!Settable(kind, inAddress->mSelector)) {
        Reply reply = {0};
        OSStatus exists = Property(inObjectID, inAddress, 0, NULL, &reply);
        pthread_mutex_unlock(&gLock);
        return exists == noErr ? kAudioHardwareUnsupportedOperationError : exists;
    }

    if (kind == KindPlugIn) {
        pthread_mutex_unlock(&gLock);
        if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        Entry entries[kSideCastMaxDevices];
        UInt32 count = ParseDeviceList(*(const CFPropertyListRef *)inData, entries);
        ApplyDeviceList(entries, count);
        for (UInt32 i = 0; i < count; i++) {
            CFRelease(entries[i].uid);
            CFRelease(entries[i].name);
        }
        return noErr;
    }

    if (kind == KindStream) {
        OSStatus status = noErr;
        if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
            if (inDataSize < sizeof(UInt32)) status = kAudioHardwareBadPropertySizeError;
            else device->streamActive = *(const UInt32 *)inData != 0;
        } else if (inDataSize < sizeof(AudioStreamBasicDescription)) {
            status = kAudioHardwareBadPropertySizeError;
        } else if (!IsOurFormat(inData)) {
            status = kAudioDeviceUnsupportedFormatError;
        }
        pthread_mutex_unlock(&gLock);
        return status;
    }

    // Volume or mute.
    AudioObjectID controlID = inObjectID;
    if (kind == KindVolume) {
        if (inDataSize < sizeof(Float32)) {
            pthread_mutex_unlock(&gLock);
            return kAudioHardwareBadPropertySizeError;
        }
        Float32 value = *(const Float32 *)inData;
        device->volumeScalar = inAddress->mSelector == kAudioLevelControlPropertyScalarValue ? Clamp01(value) : DecibelsToScalar(value);
    } else {
        if (inDataSize < sizeof(UInt32)) {
            pthread_mutex_unlock(&gLock);
            return kAudioHardwareBadPropertySizeError;
        }
        device->muted = *(const UInt32 *)inData != 0;
    }
    CFStringRef uid = CFRetain(device->uid);
    Float32 volume = device->volumeScalar;
    bool muted = device->muted;
    pthread_mutex_unlock(&gLock);

    SaveVolume(uid, volume, muted);
    CFRelease(uid);
    if (gHost) {
        if (kind == KindVolume) {
            AudioObjectPropertyAddress changed[2] = {
                { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            gHost->PropertiesChanged(gHost, controlID, 2, changed);
        } else {
            AudioObjectPropertyAddress changed = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            gHost->PropertiesChanged(gHost, controlID, 1, &changed);
        }
    }
    return noErr;
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Device *device = DeviceWithID(inDeviceObjectID);
    if (!device) {
        pthread_mutex_unlock(&gLock);
        return kAudioHardwareBadObjectError;
    }
    if (device->ioClients == 0) {
        device->anchorHostTime = mach_absolute_time();
        device->timestampCount = 0;
    }
    device->ioClients++;
    pthread_mutex_unlock(&gLock);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Device *device = DeviceWithID(inDeviceObjectID);
    if (device && device->ioClients > 0) device->ioClients--;
    pthread_mutex_unlock(&gLock);
    return device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Device *device = DeviceWithID(inDeviceObjectID);
    if (!device) {
        pthread_mutex_unlock(&gLock);
        return kAudioHardwareBadObjectError;
    }
    // Advance one period at a time while the clock has passed the next one.
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kSideCastZeroTimeStampPeriod;
    UInt64 next = device->anchorHostTime + (UInt64)((Float64)(device->timestampCount + 1) * ticksPerPeriod);
    if (next <= now) device->timestampCount++;
    *outSampleTime = (Float64)device->timestampCount * kSideCastZeroTimeStampPeriod;
    *outHostTime = device->anchorHostTime + (UInt64)((Float64)device->timestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gLock);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDeviceObjectID; (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    bool writeMix = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = writeMix;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    // The mix is discarded: SideCast reads it with a process tap before it gets here.
    (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo; (void)ioMainBuffer; (void)ioSecondaryBuffer;
    return inDriver == gDriverRef ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef ? noErr : kAudioHardwareBadObjectError;
}
