// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HelperInstaller.h"
#import "HelperProtocol.h"

@import ServiceManagement;
@import Security;


// Where SMJobBless writes the launchd job. Its presence means a previous
// install used the legacy path.
static NSString * const sLegacyDaemonPlistPath = @"/Library/LaunchDaemons/" kHelperMachServiceName ".plist";


@implementation HelperInstaller

#pragma mark - SMJobBless (legacy fallback)

// SMAppService refuses to register a LaunchDaemon unless the containing app is
// notarized ("Apps that contain LaunchDaemons must be notarized" — SMAppService.h),
// which rules it out for locally signed development builds. SMJobBless has no
// such requirement, so it stays as the fallback.
+ (BOOL) _blessHelper:(NSError **)outError
{
    AuthorizationItem   item   = { kSMRightBlessPrivilegedHelper, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    AuthorizationFlags  flags  = kAuthorizationFlagDefaults           |
                                 kAuthorizationFlagInteractionAllowed |
                                 kAuthorizationFlagPreAuthorize       |
                                 kAuthorizationFlagExtendRights;

    AuthorizationRef authRef = NULL;

    OSStatus status = AuthorizationCreate(&rights, kAuthorizationEmptyEnvironment, flags, &authRef);

    if (status != errAuthorizationSuccess) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }

        return NO;
    }

    CFErrorRef cfError = NULL;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL didBless = SMJobBless(kSMDomainSystemLaunchd, (__bridge CFStringRef)kHelperMachServiceName, authRef, &cfError);
#pragma clang diagnostic pop

    AuthorizationFree(authRef, kAuthorizationFlagDefaults);

    NSError *error = CFBridgingRelease(cfError);

    if (!didBless) {
        if (outError) {
            *outError = error ?: [NSError errorWithDomain:NSOSStatusErrorDomain code:errAuthorizationInternal userInfo:nil];
        }

        return NO;
    }

    return YES;
}


#pragma mark - Public Methods

+ (HelperInstallResult) install:(NSError **)outError
{
    if (outError) *outError = nil;

    // An earlier SMJobBless install owns the same launchd label. Registering it
    // a second time through SMAppService would collide, so stay on the path
    // that is already working.
    if ([[NSFileManager defaultManager] fileExistsAtPath:sLegacyDaemonPlistPath]) {
        return [self _blessHelper:outError] ? HelperInstallResultInstalled : HelperInstallResultFailed;
    }

    SMAppService *service = [SMAppService daemonServiceWithPlistName:kHelperDaemonPlistName];

    SMAppServiceStatus status = [service status];

    if (status == SMAppServiceStatusEnabled) {
        return HelperInstallResultInstalled;

    } else if (status == SMAppServiceStatusRequiresApproval) {
        return HelperInstallResultRequiresApproval;
    }

    NSError *registerError = nil;

    if ([service registerAndReturnError:&registerError]) {
        return ([service status] == SMAppServiceStatusEnabled) ?
            HelperInstallResultInstalled :
            HelperInstallResultRequiresApproval;
    }

    if ([registerError code] == kSMErrorAlreadyRegistered) {
        return ([service status] == SMAppServiceStatusEnabled) ?
            HelperInstallResultInstalled :
            HelperInstallResultRequiresApproval;
    }

    // kSMErrorInvalidSignature / kSMErrorToolNotValid here usually means the app
    // is not notarized, or is running from somewhere launchd will not bootstrap
    // from. Neither blocks SMJobBless.
    NSLog(@"SMAppService registration failed (%@), falling back to SMJobBless.", registerError);

    return [self _blessHelper:outError] ? HelperInstallResultInstalled : HelperInstallResultFailed;
}


+ (NSString *) helperCodeSigningRequirement
{
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSDictionary *privilegedExecutables = [infoDictionary objectForKey:@"SMPrivilegedExecutables"];

    if (![privilegedExecutables isKindOfClass:[NSDictionary class]]) return nil;

    NSString *requirement = [privilegedExecutables objectForKey:kHelperMachServiceName];
    if (![requirement isKindOfClass:[NSString class]]) return nil;

    return [requirement length] ? requirement : nil;
}


+ (void) openSystemSettingsLoginItems
{
    [SMAppService openSystemSettingsLoginItems];
}


@end
