// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#ifndef APPLE_SPI_H
#define APPLE_SPI_H

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

// Verified present on both x86_64 and arm64 (the symbols live in IOKit.framework,
// which is architecture-neutral), but this is still private SPI: unsupported and
// liable to change in any macOS release.

CF_EXTERN_C_BEGIN

// From IOPMLibPrivate.h in IOKitUser
#define kIOPMSleepDisabledKey CFSTR("SleepDisabled")

// From IOPMLibPrivate.h in IOKitUser
CFDictionaryRef _Nullable IOPMCopySystemPowerSettings(void);

// From IOPMLibPrivate.h in IOKitUser
IOReturn IOPMSetSystemPowerSetting(CFStringRef _Nonnull key, CFTypeRef _Nonnull value);

CF_EXTERN_C_END

#endif /* APPLE_SPI_H */
