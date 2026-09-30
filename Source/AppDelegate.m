// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "AppDelegate.h"
#import "RestlessEngine.h"
#import "HelperInstaller.h"
#import "PreferencesController.h"
#import "Entry.h"


@import ServiceManagement;

static NSString * const LaunchAtLoginPreferenceKey        = @"LaunchAtLogin";
static NSString * const RestlessApplicationsPreferenceKey = @"RestlessApplications";
static NSString * const ManualPreventionKey               = @"ManualPrevention";
static NSString * const ManualPreventionStartTimeKey      = @"ManualPreventionStartTime";
static NSString * const ManualDurationKey                 = @"ManualDuration";
static NSString * const UpdateFrequencyKey                = @"UpdateFrequency";
static NSString * const ReenableDelayKey                  = @"ReenableDelay";
static NSString * const AlsoPreventDiskSleepKey           = @"AlsoPreventDiskSleep";
static NSString * const AlsoPreventDisplaySleepKey        = @"AlsoPreventDisplaySleep";


@interface AppDelegate ()

@property (weak) IBOutlet NSMenu *statusItemMenu;
@property (weak) IBOutlet NSMenuItem *lidCloseMenuItem;

@end


@implementation AppDelegate {
    NSStatusItem   *_statusItem;
    NSImage *_onImage;
    NSImage *_offImage;

    RestlessEngine *_engine;
    PreferencesController *_preferencesController;
    NSTimer *_timer;

    BOOL _applicationIsTerminating;
    BOOL _didShowHelperApprovalAlert;

    BOOL _manualPreventionActive;
    NSTimeInterval _manualPreventionStartTime;
    NSTimer *_manualPreventionTimer;

    NSArrayController *_entryArrayController;
}


- (void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSDictionary *defaults = @{
        LaunchAtLoginPreferenceKey: @NO,
        ManualPreventionKey: @NO,
        RestlessApplicationsPreferenceKey: @[ @{
            @"name": @"Embrace",
            @"bundle-identifier": @"com.iccir.Embrace",
            @"action": @( EntryTypePreventLidCloseSleepWhenIdleSleepPrevented )
        } ],

        UpdateFrequencyKey: @10,
        ReenableDelayKey:   @10,
        ManualDurationKey:  @10,

        AlsoPreventDiskSleepKey:    @NO,
        AlsoPreventDisplaySleepKey: @NO
    };

    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];

    __weak AppDelegate *weakSelf = self;

    _engine = [[RestlessEngine alloc] init];
    [_engine addObserver:self forKeyPath:@"preventingLidCloseSleep" options:0 context:NULL];
    [_engine setHelperNeedsApprovalHandler:^{
        [weakSelf _showHelperApprovalAlert];
    }];

    [_engine checkHelper];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:30.0];

    _onImage  = [NSImage imageNamed:@"StatusItemIconOn"];
    _offImage = [NSImage imageNamed:@"StatusItemIconOff"];

    // -[NSStatusItem setImage:] and -setHighlightMode: were deprecated in 10.14;
    // the button is the supported way to present a status item.
    [[_statusItem button] setImage:_offImage];
    [_statusItem setMenu:[self statusItemMenu]];

    [self _updateTimer];

    [self _loadState];

    [self _updateEngineManually:YES];
    [self _updateLaunchHelper];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleUserDefaultsDidChangeNotification:) name:NSUserDefaultsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleEntryDidUpdateNotification:)        name:EntryDidUpdateNotification          object:nil];

    [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                        selector: @selector(_handleFermataUpdateNotification:)
                                                            name: @"com.iccir.Fermata.Update"
                                                          object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];

    [[NSWorkspace sharedWorkspace] addObserver:self forKeyPath:@"runningApplications" options:0 context:NULL];
}


- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)sender
{
    _applicationIsTerminating = YES;

    [_engine allowLidCloseSleepWithCallback:^{
        [[NSApplication sharedApplication] replyToApplicationShouldTerminate:YES];
    }];

    return NSTerminateLater;
}


- (void) applicationWillTerminate:(NSNotification *)note
{
    [_engine removeObserver:self forKeyPath:@"preventingLidCloseSleep"];
    [_entryArrayController removeObserver:self forKeyPath:@"arrangedObjects"];
    [[NSWorkspace sharedWorkspace] removeObserver:self forKeyPath:@"runningApplications"];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}


- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(preventLidCloseSleep:)) {
        [menuItem setState:(_manualPreventionActive ? NSControlStateValueOn : NSControlStateValueOff)];

        if ([[NSUserDefaults standardUserDefaults] integerForKey:ManualDurationKey] > 0) {
            [menuItem setTitle:@"Postpone Lid Close Sleep"];
        } else {
            [menuItem setTitle:@"Prevent Lid Close Sleep"];
        }
    }

    return YES;
}


- (void) _updateTimer
{
    NSTimeInterval updateFrequency = [[NSUserDefaults standardUserDefaults] doubleForKey:UpdateFrequencyKey];

    if ([_timer timeInterval] != updateFrequency) {
        [_timer invalidate];

        __weak id weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:updateFrequency repeats:YES block:^(NSTimer *timer) {
            [weakSelf _updateEngineManually:NO];
        }];

        [_timer setTolerance:(updateFrequency < 2.0) ? 0.1 : 1.0];
    }
}



#pragma mark - Private Methods

- (void) _loadState
{
    NSUserDefaults *defaults     = [NSUserDefaults standardUserDefaults];
    NSArray        *dictionaries = [defaults objectForKey:RestlessApplicationsPreferenceKey];
    NSMutableArray *entryArray   = [NSMutableArray array];

    for (NSDictionary *dictionary in dictionaries) {
        [entryArray addObject:[[Entry alloc] initWithDictionary:dictionary]];
    }

    _entryArrayController = [[NSArrayController alloc] initWithContent:entryArray];
    [_entryArrayController addObserver:self forKeyPath:@"arrangedObjects" options:0 context:NULL];

    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
    [_entryArrayController setSortDescriptors:@[ sortDescriptor ]];

    // Must come last: it ends in -_saveState, which writes the entry list back
    // out. Running it before the controller existed persisted an empty array.
    [self _restoreManualPrevention];
}


- (void) _restoreManualPrevention
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (![defaults boolForKey:ManualPreventionKey]) {
        [self _setManualPreventionActive:NO];
        return;
    }

    NSTimeInterval now       = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval startTime = [defaults doubleForKey:ManualPreventionStartTimeKey];

    // A start time from a future clock reading, or none at all (state saved by
    // an older build), can't be trusted as an origin for the countdown.
    if ((startTime <= 0) || (startTime > now)) startTime = now;

    NSInteger durationInMinutes = [defaults integerForKey:ManualDurationKey];

    // Don't silently restart a countdown that ran out while Fermata was closed.
    if ((durationInMinutes > 0) && (now > (startTime + (durationInMinutes * 60.0)))) {
        [self _setManualPreventionActive:NO];
        return;
    }

    [self _setManualPreventionActive:YES startTime:startTime];
}


- (void) _saveState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // -_saveState can run before -_loadState finishes building the controller;
    // writing the empty list at that point would discard the user's apps.
    if (_entryArrayController) {
        NSMutableArray *dictionaries = [NSMutableArray array];

        for (Entry *entry in [_entryArrayController arrangedObjects]) {
            [dictionaries addObject:[entry dictionaryRepresentation]];
        }

        [defaults setObject:dictionaries forKey:RestlessApplicationsPreferenceKey];
    }

    [defaults setBool:_manualPreventionActive forKey:ManualPreventionKey];
    [defaults setDouble:_manualPreventionStartTime forKey:ManualPreventionStartTimeKey];
}


- (void) _updateLaunchHelper
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    BOOL launchAtLogin = [defaults boolForKey:LaunchAtLoginPreferenceKey];

    SMAppService      *service = [SMAppService mainAppService];
    SMAppServiceStatus status  = [service status];

    // The user can revoke a login item from System Settings. Mirror that back
    // into the preference rather than re-registering behind their back.
    if (launchAtLogin && (status == SMAppServiceStatusRequiresApproval)) {
        [defaults setBool:NO forKey:LaunchAtLoginPreferenceKey];
        return;
    }

    if (launchAtLogin == (status == SMAppServiceStatusEnabled)) return;

    NSError *error = nil;

    BOOL didUpdate = launchAtLogin ?
        [service registerAndReturnError:&error] :
        [service unregisterAndReturnError:&error];

    if (didUpdate) return;

    // Already in the requested state — nothing went wrong.
    if ( launchAtLogin && ([error code] == kSMErrorAlreadyRegistered)) return;
    if (!launchAtLogin && ([error code] == kSMErrorJobNotFound))       return;

    NSLog(@"Couldn't %@ Fermata as a login item: %@", launchAtLogin ? @"register" : @"unregister", error);

    if (launchAtLogin) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Couldn't add Fermata to the Login Items list.", nil)];
        [alert setInformativeText:[error localizedDescription] ?: @""];
        [alert runModal];

        [defaults setBool:NO forKey:LaunchAtLoginPreferenceKey];
    }
}


- (void) _showHelperApprovalAlert
{
    if (_didShowHelperApprovalAlert) return;
    _didShowHelperApprovalAlert = YES;

    NSAlert *alert = [[NSAlert alloc] init];

    [alert setMessageText:NSLocalizedString(@"Fermata needs permission to run its helper.", nil)];
    [alert setInformativeText:NSLocalizedString(@"Until Fermata is enabled in System Settings › General › Login Items, it can't prevent Lid Close Sleep.", nil)];

    [alert addButtonWithTitle:NSLocalizedString(@"Open System Settings", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Later", nil)];

    [NSApp activateIgnoringOtherApps:YES];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [HelperInstaller openSystemSettingsLoginItems];
    }
}


- (void) _handleUserDefaultsDidChangeNotification:(NSNotification *)note
{
    [self _updateLaunchHelper];
    [self _updateTimer];
}


- (void) _handleEntryDidUpdateNotification:(NSNotification *)note
{
    [self _updateEngineManually:NO];
    [self _saveState];
}


- (void) _handleFermataUpdateNotification:(NSNotification *)note
{
    [self _updateEngineManually:NO];
}


- (void) _setManualPreventionActive:(BOOL)manualPreventionActive
{
    [self _setManualPreventionActive: manualPreventionActive
                           startTime: (manualPreventionActive ? [NSDate timeIntervalSinceReferenceDate] : 0)];
}


- (void) _setManualPreventionActive:(BOOL)manualPreventionActive startTime:(NSTimeInterval)startTime
{
    if (_manualPreventionActive != manualPreventionActive) {
        _manualPreventionActive = manualPreventionActive;
        _manualPreventionStartTime = startTime;
    }

    if (_manualPreventionActive && !_manualPreventionTimer) {
        __weak id weakSelf = self;

        _manualPreventionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            [weakSelf _updateStatusItem];
        }];

    } else if (!_manualPreventionActive && _manualPreventionTimer) {
        [_manualPreventionTimer invalidate];
        _manualPreventionTimer = nil;
    }

    [self _updateEngineManually:YES];
    [self _saveState];
}


- (NSImage *) _statusItemImageWithPercentage:(CGFloat)percentage
{
    NSImage *onImage = _onImage;

    CGRect onImageRect = CGRectZero;
    onImageRect.size = [onImage size];

    CGRect masterRect = onImageRect;
    masterRect.size.height += 4;
    onImageRect.origin.y += 2;

    NSImage *image = [NSImage imageWithSize:masterRect.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [onImage drawInRect:onImageRect];

        CGRect barRect = CGRectInset(masterRect, 2, 0);
        barRect.size.height = 2;
        [[NSBezierPath bezierPathWithRoundedRect:barRect xRadius:1 yRadius:1] addClip];

        [[NSColor colorWithWhite:0.0 alpha:0.25] set];
        [[NSBezierPath bezierPathWithRect:barRect] fill];

        CGRect activeBarRect = barRect;
        activeBarRect.size.width *= percentage;
        [[NSColor blackColor] set];
        [[NSBezierPath bezierPathWithRect:activeBarRect] fill];

        return YES;
    }];

    [image setTemplate:YES];

    return image;
}


- (void) _updateStatusItem
{
    NSImage *image = nil;

    if ([_engine isPreventingLidCloseSleep]) {
        NSInteger durationInMinutes = [[NSUserDefaults standardUserDefaults] integerForKey:ManualDurationKey];

        if (_manualPreventionActive && durationInMinutes) {
            NSTimeInterval duration  = durationInMinutes * 60;
            NSTimeInterval remaining = (_manualPreventionStartTime + duration) - [NSDate timeIntervalSinceReferenceDate];

            CGFloat percent = remaining / duration;
            if (percent > 1) percent = 1;
            if (percent < 0) percent = 0;

            image = [self _statusItemImageWithPercentage:percent];

        } else {
            image = _onImage;
        }

    } else {
        image = _offImage;
    }

    [[_statusItem button] setImage:image];
}


- (void) _updateEngineManually:(BOOL)isManual
{
    BOOL shouldPrevent = NO;
    NSMutableDictionary *bundleIDToEntryMap = nil;

    if (_applicationIsTerminating) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSTimeInterval reenableDelay = [defaults doubleForKey:ReenableDelayKey];
    if (isManual) reenableDelay = 0;

    // Step 1 - Check manual trigger
    //
    if (_manualPreventionActive) {
        shouldPrevent = YES;

        NSInteger durationInMinutes = [defaults integerForKey:ManualDurationKey];

        if (durationInMinutes) {
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

            if (now > (_manualPreventionStartTime + (durationInMinutes * 60.0))) {
                [self _setManualPreventionActive:NO];
                shouldPrevent = NO;
                reenableDelay = 0;
            }
        }
    }

    // Step 2a - Check RestlessActionPreventLidCloseSleepWhenRunning
    // Step 2b - Also build bundleIDToEntryMap
    //
    if (!shouldPrevent) {
        bundleIDToEntryMap = [NSMutableDictionary dictionary];

        for (Entry *entry in [_entryArrayController arrangedObjects]) {
            NSString  *bundleIdentifier = [entry bundleIdentifier];
            EntryType  type             = [entry type];

            if (!bundleIdentifier) continue;

            [bundleIDToEntryMap setObject:entry forKey:bundleIdentifier];

            if (type == EntryTypePreventLidCloseSleepWhenRunning) {
                if ([[NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier] count]) {
                    shouldPrevent = YES;
                    break;
                }
            }
        }
    }

    // Step 3 - Check RestlessActionPreventLidCloseSleepWhenIdleSleepPrevented
    //
    if (!shouldPrevent) {
        for (NSNumber *pidNumber in [_engine pidsPreventingIdleSleep]) {
            pid_t pid = (pid_t)[pidNumber integerValue];

            NSString *bundleIdentifier = [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] bundleIdentifier];
            if (!bundleIdentifier) continue;

            Entry *entry = [bundleIDToEntryMap objectForKey:bundleIdentifier];

            if ([entry type] == EntryTypePreventLidCloseSleepWhenIdleSleepPrevented) {
                shouldPrevent = YES;
                break;
            }
        }
    }

    [_engine setAlsoPreventDiskSleep:[defaults boolForKey:AlsoPreventDiskSleepKey]];
    [_engine setAlsoPreventDisplaySleep:[defaults boolForKey:AlsoPreventDisplaySleepKey]];

    if (shouldPrevent) {
        [_engine preventLidCloseSleep];

    } else {
        [_engine allowLidCloseSleepAfter:reenableDelay];
    }
}


#pragma mark - KVO

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([object isEqual:_engine]) {
        [self _updateStatusItem];

    } else {
        [self _updateEngineManually:NO];
        [self _saveState];
    }
}


#pragma mark - IBActions

- (IBAction) preventLidCloseSleep:(id)sender
{
    if (!_manualPreventionActive) {
        [self _setManualPreventionActive:YES];
    } else {
        [self _setManualPreventionActive:NO];
    }
}


- (IBAction) showPreferences:(id)sender
{
    if (!_preferencesController) {
        _preferencesController = [[PreferencesController alloc] init];
        [_preferencesController setEntryArrayController:_entryArrayController];
    }

    [_preferencesController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
}


@end
