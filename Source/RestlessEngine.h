// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>


@interface RestlessEngine : NSObject

- (NSArray<NSNumber *> *) pidsPreventingIdleSleep;

- (void) checkHelper;

- (void) preventLidCloseSleep;
- (void) allowLidCloseSleepAfter:(NSTimeInterval)delay;

// For application termination. The callback always runs, even when the helper
// is missing or unreachable, so that -applicationShouldTerminate: can reply.
- (void) allowLidCloseSleepWithCallback:(void (^)(void))callback;

// Called on the main thread when the helper was registered but an admin still
// has to enable it in System Settings › General › Login Items.
@property (nonatomic, copy) void (^helperNeedsApprovalHandler)(void);

@property (nonatomic, readonly, getter=isPreventingLidCloseSleep) BOOL preventingLidCloseSleep;

@property (nonatomic) BOOL alsoPreventDiskSleep;
@property (nonatomic) BOOL alsoPreventDisplaySleep;

@end
