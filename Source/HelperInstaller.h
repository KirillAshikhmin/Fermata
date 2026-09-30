// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, HelperInstallResult) {
    // The helper is installed and its Mach service can be reached.
    HelperInstallResultInstalled,

    // SMAppService accepted the registration, but an admin still has to enable
    // Fermata in System Settings › General › Login Items before launchd will
    // bootstrap the daemon.
    HelperInstallResultRequiresApproval,

    HelperInstallResultFailed
};


@interface HelperInstaller : NSObject

// Installs the privileged helper, preferring SMAppService and falling back to
// SMJobBless. Must be called from the main thread: both paths can present UI
// (an authorization prompt for SMJobBless).
+ (HelperInstallResult) install:(NSError **)outError;

// Code signing requirement the helper has to satisfy, taken from this app's
// SMPrivilegedExecutables. Used to pin the XPC connection to the real helper.
+ (NSString *) helperCodeSigningRequirement;

+ (void) openSystemSettingsLoginItems;

@end
