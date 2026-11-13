#import "FLEXManager+ThreeFingerTap.h"
#import "FLEXManager.h"
#import "UIGestureRecognizer+Blocks.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Keep independent recognizers: either three or four fingers can summon FLEX.
static UILongPressGestureRecognizer *flex_threeFingerLongPressGesture = nil;
static UILongPressGestureRecognizer *flex_fourFingerLongPressGesture = nil;
@interface FLEXActivationGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation FLEXActivationGestureDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The two FLEX shortcuts stay mutually exclusive, so one hold toggles once.
    // Coexist with host/third-party recognizers instead of requiring their failure.
    return other != flex_threeFingerLongPressGesture && other != flex_fourFingerLongPressGesture;
}
@end
static FLEXActivationGestureDelegate *flex_activationGestureDelegate = nil;

@implementation FLEXManager (ThreeFingerTap)

+ (void)load {
    // 确保在主线程执行，并且在应用启动和UI设置完毕后
    if ([NSThread isMainThread]) {
        [self flex_setupGesture];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self flex_setupGesture];
        });
    }
}

+ (void)flex_setupGesture {
    UIWindow *targetWindow = [self flex_findTargetWindow];

    if (!targetWindow) {
        // 如果没有找到窗口，稍后重试。这可能在 +load 执行过早时发生。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self flex_setupGesture];
        });
        return;
    }

    if (!flex_activationGestureDelegate) {
        flex_activationGestureDelegate = [FLEXActivationGestureDelegate new];
    }
    for (NSNumber *touchCount in @[@3, @4]) {
        UILongPressGestureRecognizer *recognizer = touchCount.unsignedIntegerValue == 3
            ? flex_threeFingerLongPressGesture : flex_fourFingerLongPressGesture;
        if (!recognizer) {
            recognizer = [UILongPressGestureRecognizer flex_action:^(UIGestureRecognizer *gesture) {
                if (gesture.state == UIGestureRecognizerStateBegan) {
                    [[FLEXManager sharedManager] toggleExplorer];
                }
            }];
            recognizer.numberOfTouchesRequired = touchCount.unsignedIntegerValue;
            recognizer.minimumPressDuration = 0.5;
            recognizer.cancelsTouchesInView = NO;
            recognizer.delaysTouchesBegan = NO;
            recognizer.delaysTouchesEnded = NO;
            recognizer.delegate = flex_activationGestureDelegate;
            if (touchCount.unsignedIntegerValue == 3) {
                flex_threeFingerLongPressGesture = recognizer;
            } else {
                flex_fourFingerLongPressGesture = recognizer;
            }
        }
        if (recognizer.view != targetWindow) {
            [recognizer.view removeGestureRecognizer:recognizer];
            [targetWindow addGestureRecognizer:recognizer];
        }
    }
}

+ (UIWindow *)flex_findTargetWindow {
    UIWindow *applicationWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    // 优先选择一个非FLEXWindow的key window
                    if (window.isKeyWindow && ![NSStringFromClass(window.class) isEqualToString:@"FLEXWindow"]) {
                        applicationWindow = window;
                        break;
                    }
                }
                if (applicationWindow) break;

                // 备选：活动场景中的任何key window
                if (!applicationWindow) {
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            applicationWindow = window;
                            break;
                        }
                    }
                }
                if (applicationWindow) break;
                
                // 备选：活动场景中的第一个非FLEXWindow
                 if (!applicationWindow) {
                    for (UIWindow *window in windowScene.windows) {
                        if (![NSStringFromClass(window.class) isEqualToString:@"FLEXWindow"]) {
                            applicationWindow = window;
                            break;
                        }
                    }
                }
                if (applicationWindow) break;
            }
        }
    }

    // iOS < 13 或通过场景未找到合适窗口时的备选方案
    if (!applicationWindow) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *window in windows) {
            if (window.isKeyWindow && ![NSStringFromClass(window.class) isEqualToString:@"FLEXWindow"]) {
                applicationWindow = window;
                break;
            }
        }
        // 如果上面的尝试失败了，就获取当前的keyWindow（有可能是FLEXWindow）
        if (!applicationWindow) {
            applicationWindow = [UIApplication sharedApplication].keyWindow;
        }
        
        // 如果获取到的keyWindow是FLEXWindow，尝试寻找其他非FLEXWindow且可见的窗口
        if (applicationWindow && [NSStringFromClass(applicationWindow.class) isEqualToString:@"FLEXWindow"]) {
            UIWindow* fallbackWindow = nil;
            for (UIWindow *window in windows) {
                if (![NSStringFromClass(window.class) isEqualToString:@"FLEXWindow"] && !window.isHidden) {
                    fallbackWindow = window; // 找到一个可用的非FLEX窗口
                    if (window.isKeyWindow) { // 如果这个窗口恰好也是key window，优先使用
                        applicationWindow = window;
                        break;
                    }
                }
            }
            if (![NSStringFromClass(applicationWindow.class) isEqualToString:@"FLEXWindow"] || !fallbackWindow) {
                 // 如果applicationWindow仍然是FLEXWindow，或者没有找到fallbackWindow，则保持原样
            } else {
                applicationWindow = fallbackWindow; // 使用找到的非FLEX窗口
            }
        }
        #pragma clang diagnostic pop
    }
    
    return applicationWindow;
}

@end