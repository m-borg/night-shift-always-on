#import "CoreBrightnessBridge.h"
#import <dlfcn.h>

// Private CoreBrightness CBBlueLightClient interface loaded dynamically at runtime.
@interface CBBlueLightClientProxy : NSObject
- (BOOL)supported;
- (BOOL)getBlueLightStatus:(NSAOStatus *)status;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)setMode:(int)mode;
- (BOOL)setSchedule:(const NSAOSchedule *)schedule;
- (BOOL)getStrength:(float *)strength;
- (BOOL)setStrength:(float)strength commit:(BOOL)commit;
- (void)setStatusNotificationBlock:(nullable void (^)(void))block;
- (void)enableNotifications;
@end

static BOOL loadCoreBrightnessFramework(void) {
    static BOOL loaded = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY | RTLD_LOCAL
        );
        loaded = (handle != NULL);
    });
    return loaded;
}

@implementation NSAOBrightnessClient {
    id _client;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (loadCoreBrightnessFramework()) {
        Class clientClass = NSClassFromString(@"CBBlueLightClient");
        if (clientClass) {
            _client = [[clientClass alloc] init];
        }
    }

    return self;
}

- (void)dealloc {
    if (_client && [_client respondsToSelector:@selector(setStatusNotificationBlock:)]) {
        [(CBBlueLightClientProxy *)_client setStatusNotificationBlock:nil];
    }
}

- (BOOL)isSupported {
    if (!_client) {
        return NO;
    }
    if ([_client respondsToSelector:@selector(supported)]) {
        return [(CBBlueLightClientProxy *)_client supported];
    }
    NSAOStatus status;
    memset(&status, 0, sizeof(status));
    if ([self getStatus:&status]) {
        return status.available ? YES : NO;
    }
    return NO;
}

- (BOOL)getStatus:(NSAOStatus *)outStatus {
    if (!outStatus || !_client) {
        return NO;
    }
    memset(outStatus, 0, sizeof(NSAOStatus));
    return [(CBBlueLightClientProxy *)_client getBlueLightStatus:outStatus];
}

- (BOOL)setEnabled:(BOOL)enabled {
    if (!_client) {
        return NO;
    }
    return [(CBBlueLightClientProxy *)_client setEnabled:enabled];
}

- (BOOL)setMode:(int32_t)mode {
    if (!_client) {
        return NO;
    }
    return [(CBBlueLightClientProxy *)_client setMode:(int)mode];
}

- (BOOL)setSchedule:(NSAOSchedule)schedule {
    if (!_client) {
        return NO;
    }
    return [(CBBlueLightClientProxy *)_client setSchedule:&schedule];
}

- (BOOL)getStrength:(float *)outStrength {
    if (!outStrength || !_client) {
        return NO;
    }
    *outStrength = 0.0f;
    return [(CBBlueLightClientProxy *)_client getStrength:outStrength];
}

- (BOOL)setStrength:(float)strength commit:(BOOL)commit {
    if (!_client) {
        return NO;
    }
    float clamped = fminf(fmaxf(strength, 0.0f), 1.0f);
    return [(CBBlueLightClientProxy *)_client setStrength:clamped commit:commit];
}

- (void)setStatusChangedHandler:(nullable void (^)(void))handler {
    if (!_client) {
        return;
    }
    if (!handler) {
        [(CBBlueLightClientProxy *)_client setStatusNotificationBlock:nil];
        return;
    }

    void (^copiedHandler)(void) = [handler copy];
    [(CBBlueLightClientProxy *)_client setStatusNotificationBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            copiedHandler();
        });
    }];
    if ([_client respondsToSelector:@selector(enableNotifications)]) {
        [(CBBlueLightClientProxy *)_client enableNotifications];
    }
}

@end
