#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ReFlexCallTrace : NSObject
+ (instancetype)sharedTrace;
- (void)armProbe:(NSString *)probe fields:(NSSet<NSString *> *)fields lifetime:(NSTimeInterval)seconds;
- (void)cancel;
- (NSDictionary *)result;

// Call from an explicit debug probe in app-owned source, on the main thread.
- (void)recordProbe:(NSString *)probe metadata:(NSDictionary<NSString *, NSString *> *)metadata;
@end

NS_ASSUME_NONNULL_END
