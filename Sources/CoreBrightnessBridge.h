#ifndef CoreBrightnessBridge_h
#define CoreBrightnessBridge_h

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    int32_t hour;
    int32_t minute;
} NSAOTime;

typedef struct {
    NSAOTime fromTime;
    NSAOTime toTime;
} NSAOSchedule;

typedef struct {
    bool active;
    bool enabled;
    bool sunSchedulePermitted;
    int32_t mode;
    NSAOSchedule schedule;
    uint64_t disableFlags;
    bool available;
} NSAOStatus;

@interface NSAOBrightnessClient : NSObject

@property (nonatomic, readonly, getter=isSupported) BOOL supported;

- (instancetype)init;
- (BOOL)getStatus:(NSAOStatus *)outStatus;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)setMode:(int32_t)mode;
- (BOOL)setSchedule:(NSAOSchedule)schedule;
- (BOOL)getStrength:(float *)outStrength;
- (BOOL)setStrength:(float)strength commit:(BOOL)commit;
- (void)setStatusChangedHandler:(nullable void (^)(void))handler;

@end

NS_ASSUME_NONNULL_END

#endif /* CoreBrightnessBridge_h */
