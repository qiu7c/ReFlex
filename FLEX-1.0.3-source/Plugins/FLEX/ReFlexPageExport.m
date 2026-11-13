#import "ReFlexPageExport.h"
#import "FLEXActivityViewController.h"
#import "FLEXUtility.h"
#import "FLEXManager+Private.h"
#import "FLEXExplorerViewController.h"
#import <arpa/inet.h>
#import <objc/runtime.h>

static NSDictionary *ReFlexViewNode(UIView *view) {
    NSMutableArray *children = [NSMutableArray arrayWithCapacity:view.subviews.count];
    for (UIView *child in view.subviews) {
        [children addObject:ReFlexViewNode(child)];
    }
    return @{
        @"class": NSStringFromClass(view.class),
        @"frame": NSStringFromCGRect(view.frame),
        @"hidden": @(view.hidden),
        @"children": children,
    };
}

static NSArray<NSString *> *ReFlexMethodNames(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        [names addObject:NSStringFromSelector(method_getName(methods[index]))];
    }
    free(methods);
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

static NSData *ReFlexPageJSON(BOOL includeRuntime, NSError **error) {
    UIViewController *page = FLEXUtility.appKeyWindow.rootViewController;
    while (page) {
        UIViewController *next = page.presentedViewController;
        if (next.isBeingDismissed) {
            next = nil;
        }
        if (!next && [page isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)page).topViewController;
        }
        if (!next && [page isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)page).selectedViewController;
        }
        if (!next || next.isBeingDismissed) {
            break;
        }
        page = next;
    }

    UIView *root = page.viewIfLoaded;
    if (!root) {
        *error = [NSError errorWithDomain:@"ReFlex" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"当前窗口没有已加载的页面。"
        }];
        return nil;
    }
    Class controllerClass = object_getClass(page);
    NSMutableDictionary *snapshot = [@{
        @"schemaVersion": @1,
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"controllerClass": NSStringFromClass(controllerClass),
        @"rootView": ReFlexViewNode(root),
    } mutableCopy];
    if (includeRuntime) {
        UIView *selection = FLEXManager.sharedManager.explorerViewController.selectedView;
        if (selection && (selection == root || [selection isDescendantOfView:root])) {
            NSMutableArray *path = [NSMutableArray array];
            for (UIView *view = selection; view != root; view = view.superview) {
                [path insertObject:@([view.superview.subviews indexOfObjectIdenticalTo:view]) atIndex:0];
            }
            NSMutableDictionary *details = [@{
                @"class": NSStringFromClass(selection.class),
                @"path": path,
                @"windowFrame": NSStringFromCGRect([selection convertRect:selection.bounds toView:nil]),
            } mutableCopy];
            if ([selection isKindOfClass:UIButton.class]) {
                details[@"title"] = ((UIButton *)selection).currentTitle;
            }
            if ([selection isKindOfClass:UIControl.class]) {
                UIControl *control = (UIControl *)selection;
                NSMutableArray *actions = [NSMutableArray array];
                for (id target in control.allTargets) {
                    NSArray *selectors = [control actionsForTarget:target == NSNull.null ? nil : target
                                                  forControlEvent:UIControlEventTouchUpInside];
                    if (selectors.count) {
                        [actions addObject:@{
                            @"targetClass": target == NSNull.null ? @"Responder chain" : NSStringFromClass(object_getClass(target)),
                            @"selectors": selectors,
                        }];
                    }
                }
                details[@"touchUpInsideActions"] = actions;
            }
            snapshot[@"selectedView"] = details;
        }
        snapshot[@"runtime"] = @{
            @"instanceMethods": ReFlexMethodNames(controllerClass),
            @"classMethods": ReFlexMethodNames(object_getClass(controllerClass)),
        };
    }
    return [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:error];
}

static void ReFlexShowMessage(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

FLEXGlobalsEntry *ReFlexPageExportEntry(void) {
    return [FLEXGlobalsEntry entryWithNameFuture:^{ return @"导出当前页面"; }
        action:^(__kindof UITableViewController *host) {
            NSError *error = nil;
            NSData *json = ReFlexPageJSON(NO, &error);
            if (json) {
                NSURL *directory = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                    isDirectory:YES];
                NSFileManager *files = NSFileManager.defaultManager;
                if ([files createDirectoryAtURL:directory withIntermediateDirectories:NO
                                     attributes:nil error:&error]) {
                    NSURL *file = [directory URLByAppendingPathComponent:@"reflex-page.json"];
                    if ([json writeToURL:file options:NSDataWritingAtomic error:&error]) {
                        UIActivityViewController *share = [FLEXActivityViewController
                            sharing:@[file] source:host.view];
                        share.completionWithItemsHandler = ^(UIActivityType activity, BOOL completed,
                            NSArray *items, NSError *activityError) {
                            [files removeItemAtURL:directory error:nil];
                        };
                        [host presentViewController:share animated:YES completion:nil];
                        return;
                    }
                    [files removeItemAtURL:directory error:nil];
                }
            }
            ReFlexShowMessage(host, @"导出失败", error.localizedDescription);
        }];
}

@interface ReFlexLANSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation ReFlexLANSessionDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}

@end

static NSURLSession *ReFlexLANSession;
static NSTimer *ReFlexLANTimer;

@interface ReFlexLANTick : NSObject
@property (nonatomic, copy) void (^poll)(void);
- (void)tick:(NSTimer *)timer;
@end

@implementation ReFlexLANTick
- (void)tick:(NSTimer *)timer {
    self.poll();
}
@end

FLEXGlobalsEntry *ReFlexLANSendEntry(void) {
    return [FLEXGlobalsEntry entryWithNameFuture:^{ return @"局域网 MCP"; }
        action:^(__kindof UITableViewController *host) {
            if (ReFlexLANSession) {
                UIAlertController *status = [UIAlertController alertControllerWithTitle:@"MCP 会话已开启"
                    message:nil preferredStyle:UIAlertControllerStyleAlert];
                [status addAction:[UIAlertAction actionWithTitle:@"关闭会话" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                        [ReFlexLANTimer invalidate];
                        ReFlexLANTimer = nil;
                        [ReFlexLANSession invalidateAndCancel];
                        ReFlexLANSession = nil;
                    }]];
                [status addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:nil]];
                [host presentViewController:status animated:YES completion:nil];
                return;
            }
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            UIAlertController *pairing = [UIAlertController alertControllerWithTitle:@"局域网 MCP"
                message:@"填写电脑的局域网 IPv4 地址、端口和配对码。"
                preferredStyle:UIAlertControllerStyleAlert];
            [pairing addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.placeholder = @"电脑 IPv4，例如 192.168.1.10";
                field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                field.text = [defaults stringForKey:@"ReFlexLANAddress"];
            }];
            [pairing addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.placeholder = @"端口";
                field.keyboardType = UIKeyboardTypeNumberPad;
                field.text = [defaults stringForKey:@"ReFlexLANPort"] ?: @"8765";
            }];
            [pairing addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.placeholder = @"32 位十六进制配对码";
                field.secureTextEntry = YES;
                field.autocorrectionType = UITextAutocorrectionTypeNo;
                field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                field.text = [defaults stringForKey:@"ReFlexLANToken"];
            }];
            [pairing addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak UIAlertController *weakPairing = pairing;
            [pairing addAction:[UIAlertAction actionWithTitle:@"开启会话" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    NSArray<UITextField *> *fields = weakPairing.textFields;
                    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
                    NSString *address = [fields[0].text stringByTrimmingCharactersInSet:space];
                    NSString *port = [fields[1].text stringByTrimmingCharactersInSet:space];
                    NSString *token = [fields[2].text stringByTrimmingCharactersInSet:space];
                    struct in_addr ip = {0};
                    BOOL validIP = inet_pton(AF_INET, address.UTF8String, &ip) == 1;
                    uint32_t value = ntohl(ip.s_addr);
                    BOOL privateIP = (value >> 24) == 10 || (value >> 20) == 0xAC1 || (value >> 16) == 0xC0A8;
                    BOOL validPort = port.length <= 5 && port.integerValue > 0 && port.integerValue <= 65535 &&
                        [port rangeOfString:@"^[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound;
                    BOOL validToken = token.length == 32 &&
                        [token rangeOfString:@"^[0-9a-f]+$" options:NSRegularExpressionSearch].location != NSNotFound;
                    if (!validIP || !privateIP || !validPort || !validToken) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ReFlexShowMessage(host, @"地址或配对码无效", @"请检查私有 IPv4 地址、端口和配对码。");
                        });
                        return;
                    }

                    [defaults setObject:address forKey:@"ReFlexLANAddress"];
                    [defaults setObject:port forKey:@"ReFlexLANPort"];
                    [defaults setObject:token forKey:@"ReFlexLANToken"];
                    NSURL *base = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld",
                        address, (long)port.integerValue]];
                    NSString *authorization = [@"Bearer " stringByAppendingString:token];
                    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
                    configuration.HTTPAdditionalHeaders = @{@"Authorization": authorization};
                    configuration.timeoutIntervalForRequest = 4;
                    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
                    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                        delegate:[ReFlexLANSessionDelegate new] delegateQueue:NSOperationQueue.mainQueue];
                    ReFlexLANSession = session;
                    __block BOOL inFlight = NO;
                    ReFlexLANTick *tick = [ReFlexLANTick new];
                    tick.poll = ^{
                        if (inFlight || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
                            return;
                        }
                        inFlight = YES;
                        NSURL *pollURL = [base URLByAppendingPathComponent:@"request"];
                        [[session dataTaskWithURL:pollURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
                            if (ReFlexLANSession != session ||
                                UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
                                [(NSHTTPURLResponse *)response statusCode] != 200 || data.length != 32) {
                                inFlight = NO;
                                return;
                            }
                            NSString *requestID = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
                            if (!requestID || [requestID rangeOfString:@"^[0-9a-f]{32}$"
                                options:NSRegularExpressionSearch].location == NSNotFound) {
                                inFlight = NO;
                                return;
                            }
                            NSError *error = nil;
                            NSData *json = ReFlexPageJSON(YES, &error);
                            if (!json) {
                                inFlight = NO;
                                return;
                            }
                            NSURL *url = [[base URLByAppendingPathComponent:@"snapshot"] URLByAppendingPathComponent:requestID];
                            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
                            request.HTTPMethod = @"POST";
                            request.HTTPBody = json;
                            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                            [[session dataTaskWithRequest:request completionHandler:^(NSData *body, NSURLResponse *reply, NSError *failure) {
                                inFlight = NO;
                            }] resume];
                        }] resume];
                    };
                    ReFlexLANTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:tick
                        selector:@selector(tick:) userInfo:nil repeats:YES];
                }]];
            [host presentViewController:pairing animated:YES completion:nil];
        }];
}
