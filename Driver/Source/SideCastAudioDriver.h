//
//  SideCastAudioDriver.h
//  SideCast
//
//  Constants shared by the SideCast audio driver and the app. The app talks to the driver only
//  through Core Audio properties on the plug-in object.
//

#ifndef SideCastAudioDriver_h
#define SideCastAudioDriver_h

#include <CoreAudio/AudioServerPlugIn.h>

/// Bumped whenever the driver changes, so the app can offer an update. Set by the
/// SIDECAST_DRIVER_VERSION build setting, which also goes into the driver's Info.plist.
#ifndef kSideCastDriverVersion
#define kSideCastDriverVersion 1
#endif

#define kSideCastDriverBundleID "com.imarkr.SideCast.AudioDriver"
/// Every device UID starts with this, followed by the receiver's device ID.
#define kSideCastDeviceUIDPrefix "com.imarkr.SideCast.receiver."

/// Plug-in custom property (CFPropertyList, settable): the devices to publish, an array of
/// dictionaries with "uid" and "name" strings. The app sets it every few seconds; devices go
/// away when it stops (e.g. SideCast quit or crashed).
#define kSideCastPropertyDevices 'scdv'
/// Plug-in custom property (CFString, read-only): the driver version as a decimal string.
#define kSideCastPropertyVersion 'scvr'

/// Devices are removed when the app hasn't refreshed the list for this long (seconds).
#ifndef kSideCastHeartbeatTimeout
#define kSideCastHeartbeatTimeout 10.0
#endif

#define kSideCastMaxDevices 16
#define kSideCastSampleRate 48000.0
#define kSideCastChannels 2
#define kSideCastZeroTimeStampPeriod 16384

/// Volume control range; the app turns the decibel value into a linear gain.
#define kSideCastMinDecibels (-96.0f)
#define kSideCastMaxDecibels 0.0f

/// The plug-in's factory, named in Info.plist.
void *SideCastAudioDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

#endif
