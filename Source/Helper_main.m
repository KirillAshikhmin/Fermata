// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

#import "AppleSPI.h"
#import "HelperProtocol.h"


@interface Helper : NSObject <NSXPCListenerDelegate, HelperProtocol>
@end

@implementation Helper {
    NSXPCListener *_listener;
}


// The helper runs as root and vends a Mach service, which any process on the
// system can reach. Restrict it to code that satisfies the requirement embedded
// in our own SMAuthorizedClients — keeping a single source of truth for the
// requirement string, which Resources/Helper-Info.plist derives from the
// project's Team ID at build time.
- (NSString *) _clientCodeSigningRequirement
{
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSArray *authorizedClients = [infoDictionary objectForKey:@"SMAuthorizedClients"];

    if (![authorizedClients isKindOfClass:[NSArray class]]) return nil;

    NSString *requirement = [authorizedClients firstObject];
    if (![requirement isKindOfClass:[NSString class]]) return nil;

    return [requirement length] ? requirement : nil;
}


- (instancetype) init
{
    if ((self = [super init])) {
        NSString *requirement = [self _clientCodeSigningRequirement];

        if (!requirement) {
            NSLog(@"Fermata helper: no usable SMAuthorizedClients requirement in the embedded "
                   "Info.plist. Refusing to start rather than vending an unauthenticated root service.");
            return nil;
        }

        _listener = [[NSXPCListener alloc] initWithMachServiceName:kHelperMachServiceName];
        [_listener setDelegate:self];
        [_listener setConnectionCodeSigningRequirement:requirement];
    }

    return self;
}


- (void) run
{
    [_listener resume];
    [[NSRunLoop currentRunLoop] run];
}


- (BOOL) listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // -setConnectionCodeSigningRequirement: has already rejected anything that
    // does not satisfy the requirement, so by this point the peer is trusted.
    [newConnection setExportedInterface:[NSXPCInterface interfaceWithProtocol:@protocol(HelperProtocol)]];
    [newConnection setExportedObject:self];
    [newConnection resume];

    return YES;
}


- (void) preventSleepWithReply:(void (^)(NSInteger error))reply
{
    NSInteger status = IOPMSetSystemPowerSetting(kIOPMSleepDisabledKey, kCFBooleanTrue);
    if (reply) reply(status);
}


- (void) allowSleepWithReply:(void (^)(NSInteger error))reply
{
    NSInteger status = IOPMSetSystemPowerSetting(kIOPMSleepDisabledKey, kCFBooleanFalse);
    if (reply) reply(status);
}


- (void) requestVersionWithReply:(void (^)(NSInteger version))reply
{
    if (reply) reply(kHelperVersion);
}


@end


int main(int argc, char *argv[])
{
    @autoreleasepool {
        Helper *helper = [[Helper alloc] init];
        if (!helper) return EXIT_FAILURE;

        [helper run];
    }

    return EXIT_SUCCESS;
}
