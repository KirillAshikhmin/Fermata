// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

#define kHelperMachServiceName @"com.iccir.Fermata.Helper"

// Name of the launchd plist inside Contents/Library/LaunchDaemons, registered
// with +[SMAppService daemonServiceWithPlistName:].
#define kHelperDaemonPlistName @"com.iccir.Fermata.Helper.plist"

// Bumped to 2 in the Apple Silicon port: the helper now rejects XPC clients that
// fail its code signing requirement, so an already-installed v1 helper has to be
// replaced rather than reused.
#define kHelperVersion 2

@protocol HelperProtocol
@required
- (void) preventSleepWithReply:(void (^)(NSInteger error))reply;
- (void) allowSleepWithReply:(void (^)(NSInteger error))reply;
- (void) requestVersionWithReply:(void (^)(NSInteger version))reply;
@end
