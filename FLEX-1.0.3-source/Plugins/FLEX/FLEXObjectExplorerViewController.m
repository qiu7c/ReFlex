//
//  FLEXObjectExplorerViewController.m
//  Flipboard
//
//  Created by Ryan Olson on 2014-05-03.
//  Copyright (c) 2020 FLEX Team. All rights reserved.
//

#import "FLEXObjectExplorerViewController.h"
#import "FLEXUtility.h"
#import "FLEXRuntimeUtility.h"
#import "UIBarButtonItem+FLEX.h"
#import "FLEXMultilineTableViewCell.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXFieldEditorViewController.h"
#import "FLEXMethodCallingViewController.h"
#import "FLEXObjectListViewController.h"
#import "FLEXTabsViewController.h"
#import "FLEXBookmarkManager.h"
#import "FLEXTableView.h"
#import "FLEXResources.h"
#import "FLEXTableViewCell.h"
#import "FLEXScopeCarousel.h"
#import "FLEXMetadataSection.h"
#import "FLEXSingleRowSection.h"
#import "FLEXShortcutsSection.h"
#import "FLEXPropertyAttributes.h"
#import "NSUserDefaults+FLEX.h"
#import "x/ClassDump/UCClassHeaderDetailViewController.h"
#import "FLEXManager.h"
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL FLEXListCallbackCaptureActive = NO;
static __weak UICollectionView *FLEXListCallbackCollectionView;
static __weak id FLEXListCallbackSectionController;
static NSMutableArray<NSString *> *FLEXListCallbackEvents;

static NSString *FLEXListCallbackAlias(SEL selector) {
    return [NSString stringWithFormat:@"flex_original_%@", NSStringFromSelector(selector)];
}

static NSString *FLEXNormalizedReuseIdentifier(UICollectionViewCell *cell) {
    if (!cell) return @"(none)";
    NSString *reuse = cell.reuseIdentifier ?: @"(none)";
    NSString *className = NSStringFromClass(cell.class);
    NSString *duplicated = [className stringByAppendingString:className];
    return [reuse isEqualToString:duplicated] ? className : reuse;
}

static void FLEXRecordListCallback(NSString *selectorName, UICollectionView *collectionView, NSIndexPath *indexPath, UICollectionViewCell *cell) {
    if (!FLEXListCallbackCaptureActive || collectionView != FLEXListCallbackCollectionView) return;
    if (!FLEXListCallbackEvents) FLEXListCallbackEvents = [NSMutableArray array];
    NSString *cellName = cell ? NSStringFromClass(cell.class) : @"(none)";
    NSString *reuse = FLEXNormalizedReuseIdentifier(cell);
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | indexPath=%@ | cell=%@ | reuseIdentifier=%@ | address=%@",
                      NSDate.date, selectorName, indexPath ?: @"(none)", cellName, reuse,
                      cell ? [FLEXUtility addressOfObject:cell] : @"(none)"];
    if (FLEXListCallbackEvents.count < 200) [FLEXListCallbackEvents addObject:line];
}

static id FLEXCollectionCellForItem(id self, SEL _cmd, UICollectionView *collectionView, NSIndexPath *indexPath) {
    SEL alias = NSSelectorFromString(FLEXListCallbackAlias(_cmd));
    id cell = ((id (*)(id, SEL, UICollectionView *, NSIndexPath *))objc_msgSend)(self, alias, collectionView, indexPath);
    FLEXRecordListCallback(NSStringFromSelector(_cmd), collectionView, indexPath, [cell isKindOfClass:UICollectionViewCell.class] ? cell : nil);
    return cell;
}

static void FLEXCollectionWillDisplay(id self, SEL _cmd, UICollectionView *collectionView, UICollectionViewCell *cell, NSIndexPath *indexPath) {
    SEL alias = NSSelectorFromString(FLEXListCallbackAlias(_cmd));
    ((void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))objc_msgSend)(self, alias, collectionView, cell, indexPath);
    FLEXRecordListCallback(NSStringFromSelector(_cmd), collectionView, indexPath, cell);
}

static void FLEXCollectionDidSelect(id self, SEL _cmd, UICollectionView *collectionView, NSIndexPath *indexPath) {
    SEL alias = NSSelectorFromString(FLEXListCallbackAlias(_cmd));
    ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))objc_msgSend)(self, alias, collectionView, indexPath);
    UICollectionViewCell *visibleCell = nil;
    for (UICollectionViewCell *candidate in collectionView.visibleCells) {
        if ([[collectionView indexPathForCell:candidate] isEqual:indexPath]) {
            visibleCell = candidate;
            break;
        }
    }
    FLEXRecordListCallback(NSStringFromSelector(_cmd), collectionView, indexPath, visibleCell);
}

static void FLEXSectionDidSelectItemAtIndex(id self, SEL _cmd, NSInteger index) {
    SEL alias = NSSelectorFromString(FLEXListCallbackAlias(_cmd));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(self, alias, index);
    if (FLEXListCallbackCaptureActive && self == FLEXListCallbackSectionController) {
        [FLEXListCallbackEvents addObject:[NSString stringWithFormat:@"%@ | %@ | sectionController=%@ %@ | itemIndex=%ld",
                                           NSDate.date, NSStringFromSelector(_cmd), NSStringFromClass([self class]), [FLEXUtility addressOfObject:self], (long)index]];
    }
}

static void FLEXSectionDidSelectItemAtIndexPath(id self, SEL _cmd, id item, NSInteger index) {
    SEL alias = NSSelectorFromString(FLEXListCallbackAlias(_cmd));
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(self, alias, item, index);
    if (FLEXListCallbackCaptureActive && self == FLEXListCallbackSectionController) {
        [FLEXListCallbackEvents addObject:[NSString stringWithFormat:@"%@ | %@ | sectionController=%@ %@ | itemClass=%@ | itemIndex=%ld",
                                           NSDate.date, NSStringFromSelector(_cmd), NSStringFromClass([self class]), [FLEXUtility addressOfObject:self], item ? NSStringFromClass([item class]) : @"(none)", (long)index]];
    }
}

static void FLEXInstallListCallbackHook(Class cls, SEL selector, IMP wrapper) {
    if (!cls || !class_respondsToSelector(cls, selector)) return;
    NSString *aliasName = FLEXListCallbackAlias(selector);
    SEL alias = NSSelectorFromString(aliasName);
    if (class_getInstanceMethod(cls, alias)) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    class_addMethod(cls, alias, original, types);
    class_replaceMethod(cls, selector, wrapper, types);
}

#pragma mark - 私有属性
@interface FLEXObjectExplorerViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, readonly) FLEXSingleRowSection *descriptionSection;
@property (nonatomic, readonly) NSArray<FLEXTableViewSection *> *customSections;
@property (nonatomic) NSIndexSet *customSectionVisibleIndexes;

@property (nonatomic, readonly) NSArray<NSString *> *observedNotifications;

@end

@implementation FLEXObjectExplorerViewController

#pragma mark - 初始化

+ (instancetype)exploringObject:(id)target {
    return [self exploringObject:target customSection:[FLEXShortcutsSection forObject:target]];
}

+ (instancetype)exploringObject:(id)target customSection:(FLEXTableViewSection *)section {
    return [self exploringObject:target customSections:@[section]];
}

+ (instancetype)exploringObject:(id)target customSections:(NSArray *)customSections {
    return [[self alloc]
        initWithObject:target
        explorer:[FLEXObjectExplorer forObject:target]
        customSections:customSections
    ];
}

- (id)initWithObject:(id)target
            explorer:(__kindof FLEXObjectExplorer *)explorer
       customSections:(NSArray<FLEXTableViewSection *> *)customSections {
    NSParameterAssert(target);
    
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _object = target;
        _explorer = explorer;
        _customSections = customSections;
    }

    return self;
}

- (NSArray<NSString *> *)observedNotifications {
    return @[
        kFLEXDefaultsHidePropertyIvarsKey,
        kFLEXDefaultsHidePropertyMethodsKey,
        kFLEXDefaultsHidePrivateMethodsKey,
        kFLEXDefaultsShowMethodOverridesKey,
        kFLEXDefaultsHideVariablePreviewsKey,
    ];
}

#pragma mark - 视图控制器生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.showsShareToolbarItem = YES;
    self.wantsSectionIndexTitles = YES;

    // 在这里使用[object class]而不是object_getClass
    // 以避免被观察对象的KVO前缀
    self.title = [FLEXRuntimeUtility safeClassNameForObject:self.object];

    // 搜索
    self.showsSearchBar = YES;
    self.searchBarDebounceInterval = kFLEXDebounceInstant;
    self.showsCarousel = YES;

    // 轮播范围栏
    [self.explorer reloadClassHierarchy];
    self.carousel.items = [self.explorer.classHierarchyClasses flex_mapped:^id(Class cls, NSUInteger idx) {
        return NSStringFromClass(cls);
    }];
    
    // 用于额外选项的...按钮
    [self addToolbarItems:@[[UIBarButtonItem
        flex_itemWithImage:FLEXResources.moreIcon target:self action:@selector(moreButtonPressed:)
    ]]];

    // 在层次结构中的类之间滑动的手势
    UISwipeGestureRecognizer *leftSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSwipeGesture:)
    ];
    UISwipeGestureRecognizer *rightSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSwipeGesture:)
    ];
    leftSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    rightSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    leftSwipe.delegate = self;
    rightSwipe.delegate = self;
    [self.tableView addGestureRecognizer:leftSwipe];
    [self.tableView addGestureRecognizer:rightSwipe];
    
    // 观察可能在其他屏幕上更改的首选项
    //
    // "如果您的应用程序针对iOS 9.0及更高版本或macOS 10.11及更高版本，
    // 则无需在其dealloc方法中注销观察者。"
    for (NSString *pref in self.observedNotifications) {
        [NSNotificationCenter.defaultCenter
            addObserver:self
            selector:@selector(fullyReloadData)
            name:pref
            object:nil
        ];
    }
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView {
    [self.navigationController setToolbarHidden:NO animated:YES];
    return YES;
}


#pragma mark - 重写

/// 重写以在搜索时隐藏描述部分
- (NSArray<FLEXTableViewSection *> *)nonemptySections {
    if (self.shouldShowDescription) {
        return super.nonemptySections;
    }
    
    return [super.nonemptySections flex_filtered:^BOOL(FLEXTableViewSection *section, NSUInteger idx) {
        return section != self.descriptionSection;
    }];
}

- (NSArray<FLEXTableViewSection *> *)makeSections {
    FLEXObjectExplorer *explorer = self.explorer;
    
    // 描述部分仅适用于实例
    if (self.explorer.objectIsInstance) {
        _descriptionSection = [FLEXSingleRowSection
            title:@"描述" reuse:kFLEXMultilineCell cell:^(FLEXTableViewCell *cell) {
                cell.titleLabel.font = UIFont.flex_defaultTableCellFont;
                cell.titleLabel.text = explorer.objectDescription;
            }
        ];
        self.descriptionSection.filterMatcher = ^BOOL(NSString *filterText) {
            return [explorer.objectDescription localizedCaseInsensitiveContainsString:filterText];
        };
    }

    // 对象图部分
    FLEXSingleRowSection *referencesSection = [FLEXSingleRowSection
        title:@"对象图" reuse:kFLEXDefaultCell cell:^(FLEXTableViewCell *cell) {
            cell.titleLabel.text = @"查看引用此对象的对象";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    ];
    referencesSection.selectionAction = ^(UIViewController *host) {
        UIViewController *references = [FLEXObjectListViewController
            objectsWithReferencesToObject:explorer.object
            retained:NO
        ];
        [host.navigationController pushViewController:references animated:YES];
    };

    NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindProperties],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassProperties],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindIvars],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindMethods],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassMethods],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassHierarchy],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindProtocols],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindOther],
        referencesSection
    ]];

    if (self.customSections) {
        [sections insertObjects:self.customSections atIndexes:[NSIndexSet
            indexSetWithIndexesInRange:NSMakeRange(0, self.customSections.count)
        ]];
    }
    if (self.descriptionSection) {
        [sections insertObject:self.descriptionSection atIndex:0];
    }

    return sections.copy;
}

/// 在我们的情况下，这只是重新加载表视图，
/// 或者如果我们在类层次结构中更改了位置，则重新加载部分数据。
/// 不刷新 \c self.explorer
- (void)reloadData {
    // 检查类作用域是否已更改，相应更新
    if (self.explorer.classScope != self.selectedScope) {
        self.explorer.classScope = self.selectedScope;
        [self reloadSections];
    }
    
    [super reloadData];
}

- (void)shareButtonPressed:(UIBarButtonItem *)sender {
    [FLEXAlert makeSheet:^(FLEXAlert *make) {
        make.button(@"添加到书签").handler(^(NSArray<NSString *> *strings) {
            [FLEXBookmarkManager addBookmark:self.object];
        });
        make.button(@"复制描述").handler(^(NSArray<NSString *> *strings) {
            UIPasteboard.generalPasteboard.string = self.explorer.objectDescription;
        });
        make.button(@"复制地址").handler(^(NSArray<NSString *> *strings) {
            UIPasteboard.generalPasteboard.string = [FLEXUtility addressOfObject:self.object];
        });
        make.button(@"分享插件数据").handler(^(NSArray<NSString *> *strings) {
            [self shareRuntimeReportFromSender:sender];
        });
        make.button(@"采集列表行为（8秒）").handler(^(NSArray<NSString *> *strings) {
            [self startListCallbackCaptureFromSender:sender];
        });
        make.button(@"取消").cancelStyle();
    } showFrom:self source:sender];
}

- (void)shareRuntimeReportFromSender:(UIBarButtonItem *)sender {
    // 读取属性值可能触发 getter，因此放到后台并逐项捕获异常，避免单个字段影响整份报告。
    FLEXObjectExplorer *explorer = self.explorer;
    id object = self.object;
    NSString *objectDescription = [explorer.objectDescription copy] ?: @"";
    NSString *contextReport = [self runtimeContextReportForObject:object];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *report = [NSMutableString string];
        NSString *className = [FLEXRuntimeUtility safeClassNameForObject:object] ?: @"(unknown)";
        NSString *address = [FLEXUtility addressOfObject:object] ?: @"(unknown)";

        [report appendFormat:@"FLEX Runtime Report\nGenerated: %@\n\n", NSDate.date];
        [report appendFormat:@"Class: %@\nObject: %@\nAddress: %@\nIs class object: %@\n\n",
         className, NSStringFromClass(object_getClass(object)), address,
         explorer.objectIsInstance ? @"NO" : @"YES"];
        [report appendFormat:@"Description:\n%@\n\n", objectDescription];
        [report appendString:contextReport ?: @"Context:\n(none)\n\n"];

        [report appendString:@"Class Hierarchy:\n"];
        for (Class cls in explorer.classHierarchyClasses) {
            [report appendFormat:@"  %@\n", NSStringFromClass(cls)];
        }
        [report appendString:@"\n"];

        [report appendFormat:@"Image: %@\nImage Path: %@\nInstance Size: %@\n\n",
         explorer.imageName.name ?: @"(unknown)",
         explorer.imageName.name ?: @"(unknown)",
         explorer.instanceSize.name ?: @"(unknown)"];

        // 只导出当前类，避免把 NSObject/UIKit 的继承层级重复展开。
        [self appendMetadata:@[explorer.properties] title:@"Properties" target:object toReport:report includeValues:NO];
        [self appendMetadata:@[explorer.classProperties] title:@"Class Properties" target:object toReport:report includeValues:NO];
        [self appendMetadata:@[explorer.ivars] title:@"Instance Variables" target:object toReport:report includeValues:NO];
        [self appendMetadata:@[explorer.methods] title:@"Instance Methods" target:object toReport:report includeValues:NO];
        [self appendMetadata:@[explorer.classMethods] title:@"Class Methods" target:object toReport:report includeValues:NO];
        [self appendMetadata:@[explorer.conformedProtocols] title:@"Protocols" target:object toReport:report includeValues:NO];

        NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = documents.firstObject ?: NSTemporaryDirectory();
        NSString *safeName = [className stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *fileName = [NSString stringWithFormat:@"FLEX-%@-%lld.txt", safeName, (long long)NSDate.date.timeIntervalSince1970];
        NSString *path = [documentsPath stringByAppendingPathComponent:fileName];
        NSError *writeError = nil;
        BOOL written = [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!written) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"分享失败"
                                                                                 message:writeError.localizedDescription ?: @"报告写入失败"
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }

            UIActivityViewController *activity = [[UIActivityViewController alloc]
                initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            if (activity.popoverPresentationController) {
                activity.popoverPresentationController.barButtonItem = sender;
            }
            [self presentViewController:activity animated:YES completion:nil];
        });
    });
}

- (UICollectionView *)nearestCollectionViewForObject:(id)object {
    if (![object isKindOfClass:UIView.class]) return nil;
    UIView *current = (UIView *)object;
    for (NSUInteger depth = 0; current && depth < 20; depth++, current = current.superview) {
        if ([current isKindOfClass:UICollectionView.class]) return (UICollectionView *)current;
    }
    return nil;
}

- (void)startListCallbackCaptureFromSender:(UIBarButtonItem *)sender {
    UICollectionView *collectionView = [self nearestCollectionViewForObject:self.object];
    if (!collectionView || !collectionView.dataSource) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"没有找到列表"
                                                                         message:@"当前对象附近没有可采集的 UICollectionView。"
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    FLEXListCallbackCollectionView = collectionView;
    FLEXListCallbackSectionController = nil;
    FLEXListCallbackEvents = [NSMutableArray array];
    FLEXListCallbackCaptureActive = YES;
    NSArray *selectors = @[
        NSStringFromSelector(@selector(collectionView:cellForItemAtIndexPath:)),
        NSStringFromSelector(@selector(collectionView:willDisplayCell:forItemAtIndexPath:)),
        NSStringFromSelector(@selector(collectionView:didSelectItemAtIndexPath:))
    ];
    for (id participant in @[collectionView.dataSource, (id)(collectionView.delegate ?: (id)[NSNull null])]) {
        if (participant == [NSNull null]) continue;
        Class cls = [participant class];
        for (NSString *name in selectors) {
            SEL selector = NSSelectorFromString(name);
            IMP wrapper = NULL;
            if (selector == @selector(collectionView:cellForItemAtIndexPath:)) wrapper = (IMP)FLEXCollectionCellForItem;
            else if (selector == @selector(collectionView:willDisplayCell:forItemAtIndexPath:)) wrapper = (IMP)FLEXCollectionWillDisplay;
            else if (selector == @selector(collectionView:didSelectItemAtIndexPath:)) wrapper = (IMP)FLEXCollectionDidSelect;
            FLEXInstallListCallbackHook(cls, selector, wrapper);
        }
    }
    // IGListKit 将 UICollectionView 的选择转发给 section controller。
    // 记录当前可见目标 Cell 对应的 section controller，定位真正的点击实现。
    UICollectionViewCell *targetCell = nil;
    if ([self.object isKindOfClass:UIView.class]) {
        for (UICollectionViewCell *candidate in collectionView.visibleCells) {
            if ([(UIView *)self.object isDescendantOfView:candidate]) {
                targetCell = candidate;
                break;
            }
        }
    }
    NSIndexPath *targetIndexPath = targetCell ? [collectionView indexPathForCell:targetCell] : collectionView.indexPathsForVisibleItems.firstObject;
    id adapter = collectionView.dataSource;
    if (targetIndexPath && [adapter respondsToSelector:@selector(sectionControllerForSection:)]) {
        @try {
            FLEXListCallbackSectionController = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, @selector(sectionControllerForSection:), targetIndexPath.section);
        } @catch (__unused NSException *exception) {
            FLEXListCallbackSectionController = nil;
        }
    }
    if (FLEXListCallbackSectionController) {
        Class sectionClass = [FLEXListCallbackSectionController class];
        FLEXInstallListCallbackHook(sectionClass, @selector(didSelectItemAtIndex:), (IMP)FLEXSectionDidSelectItemAtIndex);
        FLEXInstallListCallbackHook(sectionClass, @selector(didSelectItem:atIndex:), (IMP)FLEXSectionDidSelectItemAtIndexPath);
    }
    // 采集期间必须让触摸回到宿主 App，不能用模态提示框覆盖目标列表。
    [[FLEXManager sharedManager] hideExplorer];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self finishListCallbackCaptureFromSender:sender collectionView:collectionView];
    });
}

- (void)finishListCallbackCaptureFromSender:(UIBarButtonItem *)sender collectionView:(UICollectionView *)collectionView {
    FLEXListCallbackCaptureActive = NO;
    FLEXListCallbackSectionController = nil;
    NSArray<NSString *> *events = [FLEXListCallbackEvents copy] ?: @[];
    NSMutableString *report = [NSMutableString stringWithFormat:@"FLEX List Callback Capture\nGenerated: %@\nDuration: 8 seconds\nCollectionView: %@ %@\nDataSource: %@ %@\nDelegate: %@ %@\n\nEvents (%lu):\n",
                               NSDate.date, NSStringFromClass(collectionView.class), [FLEXUtility addressOfObject:collectionView],
                               NSStringFromClass(collectionView.dataSource.class), [FLEXUtility addressOfObject:collectionView.dataSource],
                               NSStringFromClass(collectionView.delegate.class), [FLEXUtility addressOfObject:collectionView.delegate], (unsigned long)events.count];
    for (NSString *event in events) [report appendFormat:@"  %@\n", event];
    if (!events.count) [report appendString:@"  (no callbacks observed; interact with the list during capture)\n"];
    NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = documents.firstObject ?: NSTemporaryDirectory();
    NSString *path = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"FLEX-list-callbacks-%lld.txt", (long long)NSDate.date.timeIntervalSince1970]];
    NSError *error = nil;
    BOOL written = [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!written) {
        [[FLEXManager sharedManager] showExplorer];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"采集失败" message:error.localizedDescription ?: @"文件写入失败" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [[FLEXManager sharedManager] showExplorer];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (activity.popoverPresentationController) activity.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:activity animated:YES completion:nil];
}

- (NSString *)runtimeContextReportForObject:(id)object {
    NSMutableString *report = [NSMutableString stringWithString:@"Runtime Context:\n"];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIResponder *responder = ([object isKindOfClass:UIResponder.class] ? object : nil);
    UIViewController *viewController = nil;
    UITableView *tableView = nil;
    UICollectionView *collectionView = nil;
    UICollectionViewCell *collectionCell = nil;
    UITableViewCell *tableCell = nil;

    [report appendString:@"Responder chain:\n"];
    NSUInteger responderIndex = 0;
        while (responder && responderIndex++ < 16) {
        NSValue *identity = [NSValue valueWithNonretainedObject:responder];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];
        [report appendFormat:@"  %@ %@\n", NSStringFromClass(responder.class), [FLEXUtility addressOfObject:responder]];
        if (!viewController && [responder isKindOfClass:UIViewController.class]) viewController = (UIViewController *)responder;
        responder = responder.nextResponder;
    }

    if ([object isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)object;
        [report appendString:@"Superview chain:\n"];
        UIView *current = view;
        NSUInteger depth = 0;
        while (current && depth++ < 16) {
            [report appendFormat:@"  %@ %@ frame=%@ tag=%ld id=%@\n",
             NSStringFromClass(current.class), [FLEXUtility addressOfObject:current], NSStringFromCGRect(current.frame),
             (long)current.tag, current.accessibilityIdentifier ?: @"(none)"];
            if (!tableView && [current isKindOfClass:UITableView.class]) tableView = (UITableView *)current;
            if (!collectionView && [current isKindOfClass:UICollectionView.class]) collectionView = (UICollectionView *)current;
            if (!collectionCell && [current isKindOfClass:UICollectionViewCell.class]) collectionCell = (UICollectionViewCell *)current;
            if (!tableCell && [current isKindOfClass:UITableViewCell.class]) tableCell = (UITableViewCell *)current;
            current = current.superview;
        }
    }

    if (collectionCell && collectionView) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:collectionCell];
        [report appendFormat:@"Target UICollectionViewCell: %@\n  reuseIdentifier: %@\n  indexPath: %@\n",
         NSStringFromClass(collectionCell.class), FLEXNormalizedReuseIdentifier(collectionCell), indexPath ?: @"(not visible)"];
        [self appendVisibleCollectionCells:collectionView targetCell:collectionCell toReport:report];
        [self appendIGListContextForCollectionView:collectionView indexPath:indexPath toReport:report];
    }
    if (tableCell && tableView) {
        NSIndexPath *indexPath = [tableView indexPathForCell:tableCell];
        [report appendFormat:@"Target UITableViewCell: %@\n  reuseIdentifier: %@\n  indexPath: %@\n",
         NSStringFromClass(tableCell.class), tableCell.reuseIdentifier ?: @"(none)", indexPath ?: @"(not visible)"];
    }
    [self appendControlActionsForObject:object toReport:report];

    if (viewController) {
        [report appendFormat:@"Parent ViewController: %@ %@\n", NSStringFromClass(viewController.class), [FLEXUtility addressOfObject:viewController]];
        [report appendFormat:@"ViewController title: %@\n", viewController.title ?: @"(none)"];
        [self appendRuntimeMethodsForClass:viewController.class title:@"ViewController methods" toReport:report];
    }
    if (tableView) {
        [report appendFormat:@"UITableView: %@ %@\n", NSStringFromClass(tableView.class), [FLEXUtility addressOfObject:tableView]];
        [report appendFormat:@"  dataSource: %@ %@\n  delegate: %@ %@\n",
         NSStringFromClass(tableView.dataSource.class), [FLEXUtility addressOfObject:tableView.dataSource],
         NSStringFromClass(tableView.delegate.class), [FLEXUtility addressOfObject:tableView.delegate]];
        [self appendRuntimeMethodsForClass:tableView.dataSource.class title:@"UITableView dataSource methods" toReport:report];
        [self appendRuntimeMethodsForClass:tableView.delegate.class title:@"UITableView delegate methods" toReport:report];
    }
    if (collectionView) {
        [report appendFormat:@"UICollectionView: %@ %@\n", NSStringFromClass(collectionView.class), [FLEXUtility addressOfObject:collectionView]];
        [report appendFormat:@"  dataSource: %@ %@\n  delegate: %@ %@\n",
         NSStringFromClass(collectionView.dataSource.class), [FLEXUtility addressOfObject:collectionView.dataSource],
         NSStringFromClass(collectionView.delegate.class), [FLEXUtility addressOfObject:collectionView.delegate]];
        [self appendRuntimeMethodsForClass:collectionView.dataSource.class title:@"UICollectionView dataSource methods" toReport:report];
        [self appendRuntimeMethodsForClass:collectionView.delegate.class title:@"UICollectionView delegate methods" toReport:report];
        if (!collectionCell) [self appendVisibleCollectionCells:collectionView targetCell:nil toReport:report];
    }
    [report appendString:@"\nBehavior summary:\n  This object is a view inside the nearest list Cell. Static target/action and gesture metadata are listed above. Exact selection effects require a real callback capture.\n\n"];
    return report;
}

- (void)appendVisibleCollectionCells:(UICollectionView *)collectionView targetCell:(UICollectionViewCell *)targetCell toReport:(NSMutableString *)report {
    NSArray<UICollectionViewCell *> *cells = [collectionView.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        NSIndexPath *ia = [collectionView indexPathForCell:a];
        NSIndexPath *ib = [collectionView indexPathForCell:b];
        return [ia.description compare:ib.description options:NSNumericSearch];
    }];
    [report appendFormat:@"Visible UICollectionViewCells (%lu):\n", (unsigned long)cells.count];
    NSUInteger limit = MIN(cells.count, 40);
    for (NSUInteger idx = 0; idx < limit; idx++) {
        UICollectionViewCell *cell = cells[idx];
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        [report appendFormat:@"  %@ %@ indexPath=%@ reuseIdentifier=%@%@\n",
         NSStringFromClass(cell.class), [FLEXUtility addressOfObject:cell], indexPath ?: @"(none)",
         FLEXNormalizedReuseIdentifier(cell), cell == targetCell ? @" [TARGET]" : @""];
    }
    if (cells.count > limit) [report appendFormat:@"  ... (%lu more visible cells omitted)\n", (unsigned long)(cells.count - limit)];
    [report appendString:@"\n"];
}

- (void)appendIGListContextForCollectionView:(UICollectionView *)collectionView indexPath:(NSIndexPath *)indexPath toReport:(NSMutableString *)report {
    id dataSource = collectionView.dataSource;
    if (!dataSource || ![NSStringFromClass([dataSource class]) containsString:@"IGListAdapter"] || !indexPath) return;
    [report appendFormat:@"IGList context:\n  adapter: %@ %@\n", NSStringFromClass([dataSource class]), [FLEXUtility addressOfObject:dataSource]];
    @try {
        if ([dataSource respondsToSelector:@selector(sectionControllerForSection:)]) {
            id sectionController = ((id (*)(id, SEL, NSInteger))objc_msgSend)(dataSource, @selector(sectionControllerForSection:), indexPath.section);
            [report appendFormat:@"  sectionController: %@ %@\n", sectionController ? NSStringFromClass([sectionController class]) : @"(none)", sectionController ? [FLEXUtility addressOfObject:sectionController] : @"(none)"];
        }
        if ([dataSource respondsToSelector:@selector(objectAtSection:)]) {
            id model = ((id (*)(id, SEL, NSInteger))objc_msgSend)(dataSource, @selector(objectAtSection:), indexPath.section);
            [report appendFormat:@"  model: %@ %@\n  modelDescription: %@\n", model ? NSStringFromClass([model class]) : @"(none)", model ? [FLEXUtility addressOfObject:model] : @"(none)", model ? [FLEXRuntimeUtility safeDescriptionForObject:model] : @"(none)"];
        }
    } @catch (__unused NSException *exception) {
        [report appendString:@"  section/model lookup: raised an exception\n"];
    }
    [report appendString:@"\n"];
}

- (void)appendControlActionsForObject:(id)object toReport:(NSMutableString *)report {
    if ([object isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)object;
        [report appendFormat:@"Control actions (%@):\n", NSStringFromClass(control.class)];
        NSArray<NSDictionary *> *events = @[
            @{ @"name": @"TouchUpInside", @"value": @(UIControlEventTouchUpInside) },
            @{ @"name": @"TouchUpOutside", @"value": @(UIControlEventTouchUpOutside) },
            @{ @"name": @"ValueChanged", @"value": @(UIControlEventValueChanged) },
            @{ @"name": @"EditingDidBegin", @"value": @(UIControlEventEditingDidBegin) },
            @{ @"name": @"EditingChanged", @"value": @(UIControlEventEditingChanged) },
            @{ @"name": @"EditingDidEnd", @"value": @(UIControlEventEditingDidEnd) },
            @{ @"name": @"PrimaryAction", @"value": @(UIControlEventPrimaryActionTriggered) }
        ];
        for (NSDictionary *event in events) {
            UIControlEvents eventValue = [event[@"value"] unsignedIntegerValue];
            for (id target in control.allTargets) {
                if (target == [NSNull null]) continue;
                NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:eventValue];
                for (NSString *action in actions) {
                    Class targetClass = [target class];
                    Class owner = [self classDeclaringSelector:NSSelectorFromString(action) forClass:targetClass];
                    Method method = class_getInstanceMethod(targetClass, NSSelectorFromString(action));
                    [report appendFormat:@"  %@ -> %@.%@ | owner=%@ | type=%@ | IMP=%p\n",
                     event[@"name"], NSStringFromClass(targetClass), action, owner ? NSStringFromClass(owner) : @"(unknown)",
                     method ? [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""] : @"", method ? method_getImplementation(method) : NULL];
                }
            }
        }
    }
    if ([object isKindOfClass:UIView.class]) {
        NSArray<UIGestureRecognizer *> *gestures = ((UIView *)object).gestureRecognizers;
        if (gestures.count) {
            [report appendString:@"Gesture recognizers:\n"];
            for (UIGestureRecognizer *gesture in gestures) {
                [report appendFormat:@"  %@ state=%ld enabled=%@\n", NSStringFromClass(gesture.class), (long)gesture.state, gesture.enabled ? @"YES" : @"NO"];
            }
        }
    }
    [report appendString:@"Interaction behavior: static target/action is listed above; dynamic effects require recording one real tap.\n\n"];
}

- (Class)classDeclaringSelector:(SEL)selector forClass:(Class)cls {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL found = NO;
        for (unsigned int idx = 0; idx < count; idx++) {
            if (method_getName(methods[idx]) == selector) { found = YES; break; }
        }
        if (methods) free(methods);
        if (found) return current;
    }
    return Nil;
}

- (void)appendRuntimeMethodsForClass:(Class)cls title:(NSString *)title toReport:(NSMutableString *)report {
    if (!cls) return;
    [report appendFormat:@"%@ (%@):\n", title, NSStringFromClass(cls)];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL listCallbackClass = [title containsString:@"dataSource"] || [title containsString:@"delegate"];
    NSUInteger emitted = 0;
    NSUInteger limit = listCallbackClass ? 120 : 180;
    for (NSUInteger idx = 0; idx < count && emitted < limit; idx++) {
        Method method = methods[idx];
        SEL selector = method_getName(method);
        NSString *selectorName = NSStringFromSelector(selector);
        if ([selectorName hasPrefix:@"flex_original_"]) continue;
        if (listCallbackClass &&
            !([selectorName containsString:@"collectionView"] ||
              [selectorName containsString:@"tableView"] ||
              [selectorName containsString:@"numberOfSections"] ||
              [selectorName containsString:@"numberOfItems"] ||
              [selectorName containsString:@"cellForItem"] ||
              [selectorName containsString:@"cellForRow"] ||
              [selectorName containsString:@"willDisplay"] ||
              [selectorName containsString:@"didSelect"] ||
              [selectorName containsString:@"objectAtSection"] ||
              [selectorName containsString:@"sectionController"])) continue;
        [report appendFormat:@"  %@ | %@ | IMP=%p\n", selectorName,
         [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""], method_getImplementation(method)];
        emitted++;
    }
    if (count > emitted) [report appendFormat:@"  ... (%u more runtime methods omitted)\n", count - (unsigned int)emitted];
    if (methods) free(methods);
}

- (void)appendMetadata:(NSArray<NSArray *> *)metadataByClass
                 title:(NSString *)title
                target:(id)target
             toReport:(NSMutableString *)report
         includeValues:(BOOL)includeValues {
    (void)target;
    (void)includeValues;
    [report appendFormat:@"%@:\n", title];
    NSUInteger count = 0;
    for (NSArray *metadata in metadataByClass) {
        for (id<FLEXRuntimeMetadata> item in metadata) {
            count++;
            NSString *line = @"";
            @try {
                line = [item description] ?: item.name ?: @"(unnamed)";
            } @catch (__unused NSException *exception) {
                line = item.name ?: @"(unnamed)";
            }
            [report appendFormat:@"  %@\n", line];
            // 不调用 previewWithTarget/currentValueWithTarget：它们会执行目标对象的 getter，
            // 可能触发业务代码、主线程断言或不可捕获的 EXC_BREAKPOINT。报告保留静态声明，
            // 当前对象的安全描述已在报告头部记录。
            if ([item isKindOfClass:FLEXMethod.class]) {
                FLEXMethod *method = (FLEXMethod *)item;
                [report appendFormat:@"    Type Encoding: %@\n    Implementation: %p\n    Image Path: %@\n",
                 method.typeEncoding ?: @"", method.implementation, method.imagePath ?: @"(unknown)"];
            } else if ([item isKindOfClass:FLEXProperty.class]) {
                FLEXProperty *property = (FLEXProperty *)item;
                [report appendFormat:@"    Declaration: %@\n    Type Encoding: %@\n    Ivar: %@\n",
                 property.fullDescription ?: @"", property.attributes.typeEncoding ?: @"", property.likelyIvarName ?: @"(none)"];
            } else if ([item isKindOfClass:FLEXIvar.class]) {
                FLEXIvar *ivar = (FLEXIvar *)item;
                [report appendFormat:@"    Type Encoding: %@\n    Offset: %ld\n    Size: %lu\n    Image Path: %@\n",
                 ivar.typeEncoding ?: @"", (long)ivar.offset, (unsigned long)ivar.size, ivar.imagePath ?: @"(unknown)"];
            } else if ([item isKindOfClass:FLEXProtocol.class]) {
                FLEXProtocol *protocol = (FLEXProtocol *)item;
                [report appendFormat:@"    Required Methods: %lu\n    Optional Methods: %lu\n",
                 (unsigned long)protocol.requiredMethods.count,
                 (unsigned long)protocol.optionalMethods.count];
            }
        }
    }
    if (count == 0) [report appendString:@"  (none)\n"];
    [report appendString:@"\n"];
}


#pragma mark - 私有方法

/// 与 \c -reloadData 不同，这会刷新所有内容，包括探索器。
- (void)fullyReloadData {
    [self.explorer reloadMetadata];
    [self reloadSections];
    [self reloadData];
}

- (void)handleSwipeGesture:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        switch (gesture.direction) {
            case UISwipeGestureRecognizerDirectionRight:
                if (self.selectedScope > 0) {
                    self.selectedScope -= 1;
                }
                break;
            case UISwipeGestureRecognizerDirectionLeft:
                if (self.selectedScope != self.explorer.classHierarchy.count - 1) {
                    self.selectedScope += 1;
                }
                break;

            default:
                break;
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g1 shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)g2 {
    // 优先考虑重要的平移手势而不是我们的滑动手势
    if ([g2 isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (g2 == self.navigationController.interactivePopGestureRecognizer) {
            return NO;
        }
        
        if (g2 == self.tableView.panGestureRecognizer) {
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UISwipeGestureRecognizer *)gesture {
    // 不允许从轮播中滑动
    CGPoint location = [gesture locationInView:self.tableView];
    if ([self.carousel hitTest:location withEvent:nil]) {
        return NO;
    }
    
    return YES;
}
    
- (void)moreButtonPressed:(UIBarButtonItem *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // 将首选项键映射到它们影响的内容描述
    NSDictionary<NSString *, NSString *> *explorerToggles = @{
        kFLEXDefaultsHidePropertyIvarsKey:    @"属性-支持实例变量",
        kFLEXDefaultsHidePropertyMethodsKey:  @"属性-支持方法",
        kFLEXDefaultsHidePrivateMethodsKey:   @"可能的私人方法",
        kFLEXDefaultsShowMethodOverridesKey:  @"方法覆盖",
        kFLEXDefaultsHideVariablePreviewsKey: @"变量预览"
    };
    
    // 将操作本身的键映射到操作描述的映射
    // 的操作（"隐藏X"）映射到当前状态。
    //
    // 所以默认隐藏的键有NO映射到"显示"
    NSDictionary<NSString *, NSDictionary *> *nextStateDescriptions = @{
        kFLEXDefaultsHidePropertyIvarsKey:    @{ @NO: @"隐藏 ", @YES: @"显示 " },
        kFLEXDefaultsHidePropertyMethodsKey:  @{ @NO: @"隐藏 ", @YES: @"显示 " },
        kFLEXDefaultsHidePrivateMethodsKey:   @{ @NO: @"隐藏 ", @YES: @"显示 " },
        kFLEXDefaultsShowMethodOverridesKey:  @{ @NO: @"隐藏 ", @YES: @"显示 " },
        kFLEXDefaultsHideVariablePreviewsKey: @{ @NO: @"隐藏 ", @YES: @"显示 " },
    };
    
    [FLEXAlert makeSheet:^(FLEXAlert *make) {
        make.title(@"选项");
        
        for (NSString *option in explorerToggles.allKeys) {
            BOOL current = [defaults boolForKey:option];
            NSString *title = [nextStateDescriptions[option][@(current)]
                stringByAppendingString:explorerToggles[option]
            ];
            make.button(title).handler(^(NSArray<NSString *> *strings) {
                [NSUserDefaults.standardUserDefaults flex_toggleBoolForKey:option];
                [self fullyReloadData];
            });
        }
        
        make.button(@"取消").cancelStyle();
    } showFrom:self source:sender];
}

#pragma mark - 描述

- (BOOL)shouldShowDescription {
    // 如果我们有过滤文本则隐藏；在搜索时
    // 看到描述很少有用，因为它已经在屏幕顶部
    if (self.filterText.length) {
        return NO;
    }

    return YES;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 对于描述部分，我们希望那个漂亮的纤细/贴合的行。
    // 其他行使用自动大小。
    FLEXTableViewSection *section = self.filterDelegate.sections[indexPath.section];
    
    if (section == self.descriptionSection) {
        NSAttributedString *attributedText = [[NSAttributedString alloc]
            initWithString:self.explorer.objectDescription
            attributes:@{ NSFontAttributeName : UIFont.flex_defaultTableCellFont }
        ];
        
        return [FLEXMultilineTableViewCell
            preferredHeightWithAttributedText:attributedText
            maxWidth:tableView.frame.size.width - tableView.separatorInset.right
            style:tableView.style
            showsAccessory:NO
        ];
    }

    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.filterDelegate.sections[indexPath.section] == self.descriptionSection;
}

- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    // 只有描述部分有"操作"
    if (self.filterDelegate.sections[indexPath.section] == self.descriptionSection) {
        return action == @selector(copy:);
    }

    return NO;
}

- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    if (action == @selector(copy:)) {
        UIPasteboard.generalPasteboard.string = self.explorer.objectDescription;
    }
}

@end
