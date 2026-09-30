// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "RestlessEngine.h"

#import "Entry.h"
#import "AppleSPI.h"
#import "HelperInstaller.h"
#import "HelperProtocol.h"

@import IOKit.pwr_mgt;
@import AppKit;


static NSString * const sHelperVersionKey = @"HelperVersion";

// Upper bound on how long -allowLidCloseSleepWithCallback: waits for the helper
// before letting the app quit anyway.
static NSTimeInterval const sTerminationTimeout = 2.0;


@interface RestlessEngine ()
@property (nonatomic, getter=isPreventingLidCloseSleep) BOOL preventingLidCloseSleep;
@end


@implementation RestlessEngine {
    NSXPCConnection *_connection;
    NSInteger _helperVersion;

    IOPMAssertionID _diskSleepAssertion;
    IOPMAssertionID _displaySleepAssertion;
    IOPMAssertionID _idleSleepAssertion;
}


- (void) dealloc
{
    [_connection invalidate];

    if (_diskSleepAssertion) {
        IOPMAssertionRelease(_diskSleepAssertion);
        _diskSleepAssertion = kIOPMNullAssertionID;
    }

    if (_displaySleepAssertion) {
        IOPMAssertionRelease(_displaySleepAssertion);
        _displaySleepAssertion = kIOPMNullAssertionID;
    }

    if (_idleSleepAssertion) {
        IOPMAssertionRelease(_idleSleepAssertion);
        _idleSleepAssertion = kIOPMNullAssertionID;
    }
}


#pragma mark - Helper Connection

// One connection is reused for the lifetime of the app. The original code built
// a fresh NSXPCConnection per command and never invalidated it, which leaked a
// connection on every timer tick.
- (NSXPCConnection *) _helperConnection
{
    if (_connection) return _connection;

    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName: kHelperMachServiceName
                                                                           options: NSXPCConnectionPrivileged];

    [connection setRemoteObjectInterface:[NSXPCInterface interfaceWithProtocol:@protocol(HelperProtocol)]];

    // Pin the connection to the helper we shipped. Without this the app would
    // talk to whatever process happens to own the Mach service name.
    NSString *requirement = [HelperInstaller helperCodeSigningRequirement];

    if (requirement) {
        [connection setCodeSigningRequirement:requirement];
    } else {
        NSLog(@"No SMPrivilegedExecutables requirement in Info.plist; helper connection is unpinned.");
    }

    __weak RestlessEngine *weakSelf = self;

    void (^teardown)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _discardConnection:connection];
        });
    };

    [connection setInvalidationHandler:teardown];
    [connection setInterruptionHandler:teardown];

    [connection resume];

    _connection = connection;

    return _connection;
}


- (void) _discardConnection:(NSXPCConnection *)connection
{
    if (_connection == connection) {
        _connection = nil;
    }
}


// `reply` is guaranteed to run exactly once, on the main thread. A non-nil error
// means the message never reached the helper, in which case `value` is
// meaningless — callers must not mistake it for an answer.
- (void) _sendCommand:(NSString *)command reply:(void (^)(NSInteger value, NSError *error))reply
{
    __block BOOL didReply = NO;

    __weak RestlessEngine *weakSelf = self;

    void (^replyOnce)(NSInteger, NSError *) = ^(NSInteger value, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (didReply) return;
            didReply = YES;

            [weakSelf _checkStatus];

            if (reply) reply(value, error);
        });
    };

    void (^helperReply)(NSInteger) = ^(NSInteger value) {
        replyOnce(value, nil);
    };

    id proxy = [[self _helperConnection] remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"Couldn't reach the Fermata helper: %@", error);
        replyOnce(0, error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSXPCConnectionInvalid userInfo:nil]);
    }];

    if ([command isEqualToString:@"prevent"]) {
        [proxy preventSleepWithReply:helperReply];

    } else if ([command isEqualToString:@"allow"]) {
        [proxy allowSleepWithReply:helperReply];

    } else if ([command isEqualToString:@"version"]) {
        [proxy requestVersionWithReply:helperReply];
    }
}


#pragma mark - Private Methods

- (void) _allowLidCloseSleep
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_allowLidCloseSleep) object:nil];
    [self _sendCommand:@"allow" reply:nil];
}


- (void) _checkStatus
{
    NSDictionary *dictionary = CFBridgingRelease(IOPMCopySystemPowerSettings());

    BOOL isPreventingLidCloseSleep = [[dictionary objectForKey:(__bridge id)kIOPMSleepDisabledKey] boolValue];
    [self setPreventingLidCloseSleep:isPreventingLidCloseSleep];
}


- (void) _didReceiveHelperVersion:(NSInteger)version
{
    _helperVersion = version;
    [[NSUserDefaults standardUserDefaults] setInteger:version forKey:sHelperVersionKey];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_checkHelperVersionResult) object:nil];
    [self _checkHelperVersionResult];
}


- (void) _checkHelperVersionResult
{
    if (_helperVersion == kHelperVersion) return;

    if (![self _installHelper]) {
        _helperVersion = 0;
    }
}


- (BOOL) _installHelper
{
    NSError *error = nil;
    HelperInstallResult result = [HelperInstaller install:&error];

    if (result == HelperInstallResultRequiresApproval) {
        if (_helperNeedsApprovalHandler) _helperNeedsApprovalHandler();
        return NO;
    }

    if (result == HelperInstallResultFailed) {
        NSLog(@"Couldn't install the Fermata helper: %@", error);
        return NO;
    }

    // A newly installed helper owns a fresh Mach service; drop the old
    // connection so the next command reconnects to it.
    [_connection invalidate];
    _connection = nil;

    return YES;
}


- (void) _updateAssertion:(IOPMAssertionID *)assertionPtr type:(CFStringRef)type enabled:(BOOL)enabled
{
    if (enabled && (*assertionPtr == kIOPMNullAssertionID)) {
        IOReturn err = IOPMAssertionCreateWithName(type, kIOPMAssertionLevelOn, CFSTR("Fermata is active"), assertionPtr);

        if (err != kIOReturnSuccess) {
            NSLog(@"IOPMAssertionCreateWithName(%@) failed: 0x%08x", (__bridge id)type, err);
            *assertionPtr = kIOPMNullAssertionID;
        }

    } else if (!enabled && (*assertionPtr != kIOPMNullAssertionID)) {
        IOPMAssertionRelease(*assertionPtr);
        *assertionPtr = kIOPMNullAssertionID;
    }
}


- (void) _updateAdditionalAssertions
{
    BOOL shouldPreventDiskSleep    = _preventingLidCloseSleep && _alsoPreventDiskSleep;
    BOOL shouldPreventDisplaySleep = _preventingLidCloseSleep && _alsoPreventDisplaySleep;

    [self _updateAssertion:&_diskSleepAssertion    type:kIOPMAssertPreventDiskIdle             enabled:shouldPreventDiskSleep];
    [self _updateAssertion:&_displaySleepAssertion type:kIOPMAssertPreventUserIdleDisplaySleep enabled:shouldPreventDisplaySleep];
    [self _updateAssertion:&_idleSleepAssertion    type:kIOPMAssertPreventUserIdleSystemSleep  enabled:_preventingLidCloseSleep];
}


#pragma mark - Public Methods

- (void) checkHelper
{
    NSInteger lastKnownHelperVersion = [[NSUserDefaults standardUserDefaults] integerForKey:sHelperVersionKey];

    if (lastKnownHelperVersion != kHelperVersion) {
        if (![self _installHelper]) return;
    }

    __weak RestlessEngine *weakSelf = self;

    [self _sendCommand:@"version" reply:^(NSInteger version, NSError *error) {
        // On failure `version` carries no information. Leaving the recorded
        // version untouched lets -_checkHelperVersionResult retry the install.
        if (error) return;

        [weakSelf _didReceiveHelperVersion:version];
    }];

    [self performSelector:@selector(_checkHelperVersionResult) withObject:nil afterDelay:5.0];
}


- (NSArray<NSNumber *> *) pidsPreventingIdleSleep
{
    NSMutableArray *result = [NSMutableArray array];

    CFDictionaryRef cfAssertionsMap = NULL;
    IOReturn err = IOPMCopyAssertionsByProcess(&cfAssertionsMap);

    if (err == kIOReturnSuccess) {
        NSDictionary *assertionsMap = (__bridge id)cfAssertionsMap;

        for (NSNumber *pidNumber in assertionsMap) {
            NSArray *assertions = [assertionsMap objectForKey:pidNumber];

            for (NSDictionary *dictionary in assertions) {
                NSString *assertionType = [dictionary objectForKey:(__bridge id)kIOPMAssertionTypeKey];

                if ([assertionType isEqualToString:(__bridge id)kIOPMAssertPreventUserIdleSystemSleep] ||
                    [assertionType isEqualToString:(__bridge id)kIOPMAssertionTypeNoIdleSleep] ||
                    [assertionType isEqualToString:(__bridge id)kIOPMAssertionTypePreventSystemSleep]
                ) {
                    [result addObject:pidNumber];
                    break;
                }
            }
        }
    }

    if (cfAssertionsMap) CFRelease(cfAssertionsMap);

    return result;
}


- (void) allowLidCloseSleepWithCallback:(void (^)(void))callback
{
    __block BOOL didFinish = NO;

    void (^finishOnce)(void) = ^{
        if (didFinish) return;
        didFinish = YES;

        if (callback) callback();
    };

    // Nothing to undo if the helper was never reachable this session.
    if (!_helperVersion) {
        finishOnce();
        return;
    }

    // _sendCommand: replies even when XPC fails, but the helper itself could
    // still stall. Don't let that wedge application termination.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sTerminationTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!didFinish) NSLog(@"Timed out waiting for the helper to re-enable Lid Close Sleep.");
        finishOnce();
    });

    [self _sendCommand:@"allow" reply:^(NSInteger result, NSError *error) {
        finishOnce();
    }];
}


- (void) preventLidCloseSleep
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_allowLidCloseSleep) object:nil];
    [self _sendCommand:@"prevent" reply:nil];
}


- (void) allowLidCloseSleepAfter:(NSTimeInterval)delay
{
    [self performSelector:@selector(_allowLidCloseSleep) withObject:nil afterDelay:delay];
}


#pragma mark - Accessors

- (void) setPreventingLidCloseSleep:(BOOL)preventingLidCloseSleep
{
    if (_preventingLidCloseSleep != preventingLidCloseSleep) {
        _preventingLidCloseSleep = preventingLidCloseSleep;
        [self _updateAdditionalAssertions];
    }
}


- (void) setAlsoPreventDiskSleep:(BOOL)alsoPreventDiskSleep
{
    if (_alsoPreventDiskSleep != alsoPreventDiskSleep) {
        _alsoPreventDiskSleep = alsoPreventDiskSleep;
        [self _updateAdditionalAssertions];
    }
}


- (void) setAlsoPreventDisplaySleep:(BOOL)alsoPreventDisplaySleep
{
    if (_alsoPreventDisplaySleep != alsoPreventDisplaySleep) {
        _alsoPreventDisplaySleep = alsoPreventDisplaySleep;
        [self _updateAdditionalAssertions];
    }
}


@end
