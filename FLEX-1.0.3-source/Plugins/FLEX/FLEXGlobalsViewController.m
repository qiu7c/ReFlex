//
//  FLEXGlobalsViewController.m
//  Flipboard
//
//  Created by Ryan Olson on 2014-05-03.
//  Copyright (c) 2020 FLEX Team. All rights reserved.
//

#import "FLEXGlobalsViewController.h"
#import "FLEXUtility.h"
#import "FLEXRuntimeUtility.h"
#import "FLEXObjcRuntimeViewController.h"
#import "FLEXKeychainViewController.h"
#import "FLEXAPNSViewController.h"
#import "FLEXObjectExplorerViewController.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXLiveObjectsController.h"
#import "FLEXFileBrowserController.h"
#import "FLEXCookiesViewController.h"
#import "FLEXGlobalsEntry.h"
#import "ReFlexPageExport.h"
#import "FLEXSystemLogViewController.h"
#import "FLEXNetworkMITMViewController.h"
#import "FLEXAddressExplorerCoordinator.h"
#import "FLEXGlobalsSection.h"
#import "UIBarButtonItem+FLEX.h"

@interface FLEXGlobalsViewController ()
// 表视图中仅显示的部分；空部分从此数组中清除。
@property (nonatomic) NSArray<FLEXGlobalsSection *> *sections;
/// 表视图中的所有部分，无论部分是否为空。
@property (nonatomic, readonly) NSArray<FLEXGlobalsSection *> *allSections;
@property (nonatomic, readonly) BOOL manuallyDeselectOnAppear;
@end

@implementation FLEXGlobalsViewController
@dynamic sections, allSections;

#pragma mark - 初始化

+ (NSString *)globalsTitleForSection:(FLEXGlobalsSectionKind)section {
    switch (section) {
        case FLEXGlobalsSectionProcessAndEvents:
            return @"页面与调试";
        case FLEXGlobalsSectionAppShortcuts:
            return @"应用快捷方式";
        case FLEXGlobalsSectionMisc:
            return @"杂项";

        default:
            @throw NSInternalInconsistencyException;
    }
}

+ (FLEXGlobalsEntry *)globalsEntryForRow:(FLEXGlobalsRow)row {
    switch (row) {
        case FLEXGlobalsRowAppKeychainItems:
            return [FLEXKeychainViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowPushNotifications:
            return [FLEXAPNSViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowAddressInspector:
            return [FLEXAddressExplorerCoordinator flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowBrowseRuntime:
            return [FLEXObjcRuntimeViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowLiveObjects:
            return [FLEXLiveObjectsController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowCookies:
            return [FLEXCookiesViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowBrowseBundle:
        case FLEXGlobalsRowBrowseContainer:
            return [FLEXFileBrowserController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowSystemLog:
            return [FLEXSystemLogViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowNetworkHistory:
            return [FLEXNetworkMITMViewController flex_concreteGlobalsEntry:row];
        case FLEXGlobalsRowKeyWindow:
        case FLEXGlobalsRowRootViewController:
        case FLEXGlobalsRowProcessInfo:
        case FLEXGlobalsRowAppDelegate:
        case FLEXGlobalsRowUserDefaults:
        case FLEXGlobalsRowMainBundle:
        case FLEXGlobalsRowApplication:
        case FLEXGlobalsRowMainScreen:
        case FLEXGlobalsRowCurrentDevice:
        case FLEXGlobalsRowPasteboard:
        case FLEXGlobalsRowURLSession:
        case FLEXGlobalsRowURLCache:
        case FLEXGlobalsRowNotificationCenter:
        case FLEXGlobalsRowMenuController:
        case FLEXGlobalsRowFileManager:
        case FLEXGlobalsRowTimeZone:
        case FLEXGlobalsRowLocale:
        case FLEXGlobalsRowCalendar:
        case FLEXGlobalsRowMainRunLoop:
        case FLEXGlobalsRowMainThread:
        case FLEXGlobalsRowOperationQueue:
            return [FLEXObjectExplorerFactory flex_concreteGlobalsEntry:row];
            
        case FLEXGlobalsRowCount:
        default:
            @throw [NSException
                exceptionWithName:NSInternalInconsistencyException
                reason:@"在switch中缺少globals情况" 
                userInfo:nil
            ];
    }
}

+ (NSArray<FLEXGlobalsSection *> *)defaultGlobalSections {
    static NSMutableArray<FLEXGlobalsSection *> *sections = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary<NSNumber *, NSArray<FLEXGlobalsEntry *> *> *rowsBySection = @{
            @(FLEXGlobalsSectionProcessAndEvents) : @[
                ReFlexPageExportEntry(),
                ReFlexLANSendEntry(),
                [self globalsEntryForRow:FLEXGlobalsRowSystemLog],
                [self globalsEntryForRow:FLEXGlobalsRowBrowseRuntime],
            ],
            @(FLEXGlobalsSectionAppShortcuts) : @[
                [self globalsEntryForRow:FLEXGlobalsRowKeyWindow],
                [self globalsEntryForRow:FLEXGlobalsRowRootViewController],
                [self globalsEntryForRow:FLEXGlobalsRowBrowseContainer],
            ],
            @(FLEXGlobalsSectionMisc) : @[]
        };

        sections = [NSMutableArray array];
        for (FLEXGlobalsSectionKind i = FLEXGlobalsSectionProcessAndEvents; i < FLEXGlobalsSectionCount; ++i) {
            NSString *title = [self globalsTitleForSection:i];
            [sections addObject:[FLEXGlobalsSection title:title rows:rowsBySection[@(i)]]];
        }
    });
    
    return sections;
}


#pragma mark - 重写

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"ReFlex";
    self.showsSearchBar = YES;
    self.searchBarDebounceInterval = kFLEXDebounceInstant;
    self.navigationItem.backBarButtonItem = [UIBarButtonItem flex_backItemWithTitle:@"返回"];
    
    _manuallyDeselectOnAppear = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 10;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self disableToolbar];
    
    if (self.manuallyDeselectOnAppear) {
        [self.tableView deselectRowAtIndexPath:self.tableView.indexPathForSelectedRow animated:YES];
    }
}

- (NSArray<FLEXGlobalsSection *> *)makeSections {
    NSMutableArray<FLEXGlobalsSection *> *sections = [NSMutableArray array];

    [sections addObjectsFromArray:[self.class defaultGlobalSections]];

    return sections;
}

- (FLEXGlobalsEntry *)globalsEntryAtIndex:(NSInteger)index {
    FLEXGlobalsRow row = [self globalRowAtIndex:index];
    
    // 直接调用类方法，避免重复代码和错误的方法名
    return [[self class] globalsEntryForRow:row];
}

- (FLEXGlobalsRow)globalRowAtIndex:(NSInteger)index {
    // 这里根据项目实际逻辑进行实现，简单示例:
    return (FLEXGlobalsRow)index;
}

@end
