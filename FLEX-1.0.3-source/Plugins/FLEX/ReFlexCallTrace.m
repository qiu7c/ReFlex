#import "ReFlexCallTrace.h"

@implementation ReFlexCallTrace {
    NSString *_probe;
    NSSet<NSString *> *_fields;
    NSTimeInterval _deadline;
    NSDictionary *_capture;
    BOOL _cancelled;
}

+ (instancetype)sharedTrace {
    static ReFlexCallTrace *trace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ trace = [self new]; });
    return trace;
}

- (void)armProbe:(NSString *)probe fields:(NSSet<NSString *> *)fields lifetime:(NSTimeInterval)seconds {
    _cancelled = NO;
    _probe = [probe copy];
    _fields = [fields copy];
    _deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    _capture = nil;
}

- (void)cancel {
    _cancelled = YES;
    _probe = nil;
    _fields = nil;
    _capture = nil;
}

- (NSDictionary *)result {
    if (_capture) {
        return @{@"status": @"captured", @"probe": _probe, @"metadata": _capture};
    }
    if (!_probe) {
        return @{@"status": _cancelled ? @"cancelled" : @"idle"};
    }
    NSString *status = NSProcessInfo.processInfo.systemUptime < _deadline ? @"waiting" : @"expired";
    return @{@"status": status, @"probe": _probe};
}

- (void)recordProbe:(NSString *)probe metadata:(NSDictionary<NSString *, NSString *> *)metadata {
    if (_capture || ![_probe isEqualToString:probe] || NSProcessInfo.processInfo.systemUptime >= _deadline) {
        return;
    }
    NSMutableDictionary *capture = [NSMutableDictionary dictionary];
    for (NSString *field in _fields) {
        capture[field] = metadata[field];
    }
    _capture = [capture copy];
}

@end
