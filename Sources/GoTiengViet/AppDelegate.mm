//
//  AppDelegate.mm
//  Gõ Tiếng Việt
//
//  Menu bar icon, menu, Settings window, Accessibility onboarding and the
//  login item. All UI is built in code with standard AppKit controls, so it
//  follows light and dark mode, and the app builds without Xcode.
//

#import "AppDelegate.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import "GTVHook.h"
#import "ShortcutField.h"
#import "SwitchSound.h"

static NSString *const kAppName = @"Gõ Tiếng Việt";
static NSString *const kImportedOpenKey = @"ImportedOpenKeySettings";

// Menu bar icon: "V" in a filled rounded square (Vietnamese) or "E" in an
// outlined one (English). Template images: macOS colors them for the menu
// bar in light and dark mode.
static NSImage *GTVStatusImage(BOOL vietnamese) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(19, 15) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
        NSRect box = NSInsetRect(rect, 1.5, 1.0);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3.5 yRadius:3.5];
        NSFont *font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
        NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor};
        NSString *letter = vietnamese ? @"V" : @"E";
        NSSize size = [letter sizeWithAttributes:attrs];
        // Center the capital letter on its cap height.
        NSPoint origin = NSMakePoint(NSMidX(box) - size.width / 2.0,
                                     NSMidY(box) - font.capHeight / 2.0 + font.descender);
        if (vietnamese) {
            [NSColor.blackColor setFill];
            [path fill];
            CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
            [letter drawAtPoint:origin withAttributes:attrs];
            CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        } else {
            [NSColor.blackColor setStroke];
            path.lineWidth = 1.2;
            [path stroke];
            [letter drawAtPoint:origin withAttributes:attrs];
        }
        return YES;
    }];
    [image setTemplate:YES]; // "template" is a C++ keyword in .mm files
    return image;
}

@implementation GTVAppDelegate {
    NSStatusItem *_statusItem;
    NSMenuItem *_languageItem;
    NSMenuItem *_permissionItem;
    NSMenuItem *_permissionSeparator;
    NSWindow *_settingsWindow;
    GTVShortcutField *_shortcutField;
    NSButton *_soundBox;
    NSButton *_spellingBox;
    NSButton *_smartSwitchBox;
    NSButton *_openAtLoginBox;
    NSTimer *_permissionTimer;
    NSString *_pausingSourceName; // input method that pauses the hook, if any
    BOOL _pausingSourceIsVietnamese; // its language, for the gray V/E icon
}

#pragma mark - Launch

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self registerDefaults];
    [self importOpenKeySettingsIfNeeded];
    [self buildMainMenu];
    [self buildStatusItem];

    GTVEngineInit();
    __weak GTVAppDelegate *weakSelf = self;
    GTVSetLanguageObserver(^{ [weakSelf updateLanguageUI]; });

    [GTVSwitchSound prepare];
    GTVSetHotKeySwitchObserver(^(int language) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:GTVPrefSwitchSound])
            [GTVSwitchSound playForLanguage:language];
    });

    [self observeWorkspace];
    [self observeInputSource];
    [self applyOpenAtLoginPreference];

    if (AXIsProcessTrusted()) {
        [self startHook];
    } else {
        [self updateLanguageUI];
        [self askForAccessibility];
    }
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        GTVPrefLanguage: @1,
        GTVPrefSwitchKey: @(GTVHotKeyControlShift),
        GTVPrefSpelling: @YES,
        GTVPrefSmartSwitch: @YES,
        GTVPrefOpenAtLogin: @YES,
        GTVPrefSwitchSound: @YES,
    }];
}

// On the first launch, take over the settings and the per-app languages of
// OpenKey, if it was used on this Mac.
- (void)importOpenKeySettingsIfNeeded {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs boolForKey:kImportedOpenKey])
        return;
    [prefs setBool:YES forKey:kImportedOpenKey];
    NSUserDefaults *openKey = [[NSUserDefaults alloc] initWithSuiteName:@"com.tuyenmai.openkey"];
    for (NSString *key in @[GTVPrefLanguage, GTVPrefSwitchKey, GTVPrefSpelling,
                            GTVPrefSmartSwitch, GTVPrefSmartData]) {
        id value = [openKey objectForKey:key];
        if (value != nil)
            [prefs setObject:value forKey:key];
    }
}

- (void)startHook {
    if (!GTVHookStart()) {
        os_log(OS_LOG_DEFAULT, "GTV: event tap could not start, waiting for Accessibility");
        [self askForAccessibility];
        return;
    }
    os_log(OS_LOG_DEFAULT, "GTV: keyboard hook running");
    static NSTimer *watchdog;
    [watchdog invalidate];
    watchdog = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
        GTVHookWatchdog();
    }];
    watchdog.tolerance = 1.0;
    [self updateLanguageUI];
}

#pragma mark - Accessibility

// Shows the standard macOS prompt (it also adds the app to the Accessibility
// list), opens the Accessibility page, and starts the hook as soon as the
// permission is on.
- (void)askForAccessibility {
    os_log(OS_LOG_DEFAULT, "GTV: Accessibility permission missing, opening System Settings");
    [self openAccessibilitySettings:nil];
}

- (void)openAccessibilitySettings:(id)sender {
    // Adds the app to the list, and shows the system prompt.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    [self waitForAccessibility];
}

- (void)waitForAccessibility {
    if (_permissionTimer != nil)
        return;
    _permissionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        if (!AXIsProcessTrusted())
            return;
        [timer invalidate];
        self->_permissionTimer = nil;
        [self startHook];
    }];
}

#pragma mark - Menu bar

- (void)buildMainMenu {
    // No visible menu bar for this app; this only gives the Settings window
    // the standard Close (⌘W) and Quit (⌘Q) keys.
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", kAppName]
                       action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];
    NSApp.mainMenu = mainMenu;
}

- (void)buildStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = GTVStatusImage(YES);

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;

    _permissionItem = [menu addItemWithTitle:@"Allow Accessibility Access…"
                                      action:@selector(openAccessibilitySettings:) keyEquivalent:@""];
    _permissionItem.target = self;
    _permissionSeparator = [NSMenuItem separatorItem];
    [menu addItem:_permissionSeparator];

    _languageItem = [menu addItemWithTitle:@"Vietnamese" action:@selector(toggleLanguage:) keyEquivalent:@""];
    _languageItem.target = self;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", kAppName]
                    action:@selector(terminate:) keyEquivalent:@"q"];
    _statusItem.menu = menu;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self updateLanguageUI];
}

- (void)updateLanguageUI {
    BOOL running = GTVHookIsRunning();
    BOOL paused = GTVHookIsInputSourcePaused();
    BOOL vietnamese = GTVGetLanguage() == 1;
    // While paused, show the language of the selected input method, so that
    // typing Vietnamese with another input method does not show [E].
    _statusItem.button.image = GTVStatusImage(paused ? _pausingSourceIsVietnamese : (vietnamese && running));
    _statusItem.button.appearsDisabled = !running || paused;
    if (!running)
        _statusItem.button.toolTip = [NSString stringWithFormat:@"%@: needs Accessibility access", kAppName];
    else if (paused)
        _statusItem.button.toolTip = [NSString stringWithFormat:@"%@: paused while %@ is selected", kAppName, _pausingSourceName];
    else
        _statusItem.button.toolTip = [NSString stringWithFormat:@"%@: %@", kAppName, vietnamese ? @"Vietnamese" : @"English"];

    _permissionItem.hidden = running;
    _permissionSeparator.hidden = running;
    _languageItem.enabled = running && !paused;
    _languageItem.state = vietnamese ? NSControlStateValueOn : NSControlStateValueOff;
    if (@available(macOS 14.4, *)) {
        int hotKey = (int)[[NSUserDefaults standardUserDefaults] integerForKey:GTVPrefSwitchKey];
        _languageItem.subtitle = paused
            ? [NSString stringWithFormat:@"Paused: %@ is selected", _pausingSourceName]
            : [NSString stringWithFormat:@"Switch: %@", [GTVShortcutField displayStringForHotKey:hotKey]];
    }
}

#pragma mark - Input source

// Pause while a macOS input method is the selected input source, so that a
// key is never converted by both. A plain keyboard layout (ABC, U.S., ...)
// turns the hook on again.
- (void)observeInputSource {
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self selector:@selector(inputSourceChanged:)
               name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged
             object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self inputSourceChanged:nil];
}

- (void)inputSourceChanged:(NSNotification *)note {
    [self checkInputSource];
    if (note != nil) {
        // The notice can come a moment before the new input is active (for
        // example from the input menu), so check again shortly after.
        __weak GTVAppDelegate *weakSelf = self;
        for (NSNumber *delay in @[@0.2, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf checkInputSource]; });
        }
    }
}

- (void)checkInputSource {
    BOOL isLayout = YES;
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (source != NULL) {
        CFStringRef type = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceType);
        isLayout = type == NULL || CFEqual(type, kTISTypeKeyboardLayout);
        _pausingSourceName = [(__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyLocalizedName) copy];
        NSString *sourceID = (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
        NSArray *languages = (__bridge NSArray *)TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages);
        if ([sourceID hasPrefix:@"com.sonvu.inputmethod.GoTiengViet."])
            _pausingSourceIsVietnamese = [sourceID hasSuffix:@".vi"];
        else
            _pausingSourceIsVietnamese = [languages.firstObject isEqual:@"vi"];
        os_log_debug(OS_LOG_DEFAULT, "GTV: input source %{public}@, type %{public}@",
                     (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                     (__bridge NSString *)type);
        CFRelease(source);
    }
    if (isLayout == GTVHookIsInputSourcePaused())
        os_log(OS_LOG_DEFAULT, "GTV: %{public}s (input source: %{public}@)",
               isLayout ? "resumed" : "paused", _pausingSourceName);
    GTVHookSetInputSourcePaused(!isLayout);
    [self updateLanguageUI];
}

- (void)toggleLanguage:(id)sender {
    GTVToggleLanguage();
}

#pragma mark - Settings window

- (void)showSettings:(id)sender {
    if (_settingsWindow == nil)
        [self buildSettingsWindow];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    _shortcutField.hotKey = (int)[prefs integerForKey:GTVPrefSwitchKey];
    _soundBox.state = [prefs boolForKey:GTVPrefSwitchSound] ? NSControlStateValueOn : NSControlStateValueOff;
    _spellingBox.state = [prefs boolForKey:GTVPrefSpelling] ? NSControlStateValueOn : NSControlStateValueOff;
    _smartSwitchBox.state = [prefs boolForKey:GTVPrefSmartSwitch] ? NSControlStateValueOn : NSControlStateValueOff;
    _openAtLoginBox.state = [self isOpenAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [self activateApp];
    [_settingsWindow makeKeyAndOrderFront:nil];
}

- (void)buildSettingsWindow {
    NSTextField *switchLabel = [NSTextField labelWithString:@"Switch input:"];
    _shortcutField = [[GTVShortcutField alloc] init];
    [_shortcutField.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    __weak GTVAppDelegate *weakSelf = self;
    _shortcutField.onChange = ^(int hotKey) {
        GTVSetSwitchKey(hotKey);
        [weakSelf updateLanguageUI];
    };

    _soundBox = [NSButton checkboxWithTitle:@"Play a sound when switching" target:self action:@selector(soundChanged:)];
    _spellingBox = [NSButton checkboxWithTitle:@"Check spelling" target:self action:@selector(spellingChanged:)];
    _smartSwitchBox = [NSButton checkboxWithTitle:@"Remember the input for each app"
                                           target:self action:@selector(smartSwitchChanged:)];
    _openAtLoginBox = [NSButton checkboxWithTitle:@"Open at login" target:self action:@selector(openAtLoginChanged:)];

    NSTextField *note = [NSTextField labelWithString:@"Telex · Unicode"];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;

    NSView *empty = NSGridCell.emptyContentView;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[switchLabel, _shortcutField],
        @[empty, _soundBox],
        @[empty, _spellingBox],
        @[empty, _smartSwitchBox],
        @[empty, _openAtLoginBox],
        @[empty, note],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    [grid rowAtIndex:1].bottomPadding = 6; // switch key + its sound, then the rest
    [grid rowAtIndex:5].topPadding = 4;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [[NSView alloc] init];
    [content addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
    ]];

    _settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 180)
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    _settingsWindow.title = [NSString stringWithFormat:@"%@ Settings", kAppName];
    _settingsWindow.releasedWhenClosed = NO;
    _settingsWindow.contentView = content;
    [content layoutSubtreeIfNeeded];
    [_settingsWindow setContentSize:content.fittingSize];
    [_settingsWindow center];
}

- (void)soundChanged:(NSButton *)sender {
    BOOL on = sender.state == NSControlStateValueOn;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:GTVPrefSwitchSound];
    if (on)
        [GTVSwitchSound playForLanguage:GTVGetLanguage()]; // a sample
}

- (void)spellingChanged:(NSButton *)sender {
    GTVSetSpelling(sender.state == NSControlStateValueOn);
}

- (void)smartSwitchChanged:(NSButton *)sender {
    GTVSetSmartSwitch(sender.state == NSControlStateValueOn);
}

- (void)openAtLoginChanged:(NSButton *)sender {
    BOOL on = sender.state == NSControlStateValueOn;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:GTVPrefOpenAtLogin];
    [self setOpenAtLogin:on];
    sender.state = [self isOpenAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - Login item

- (BOOL)isOpenAtLoginEnabled {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

- (void)setOpenAtLogin:(BOOL)on {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (on && service.status != SMAppServiceStatusEnabled)
        [service registerAndReturnError:&error];
    else if (!on && service.status == SMAppServiceStatusEnabled)
        [service unregisterAndReturnError:&error];
    if (error)
        NSLog(@"%@: login item change failed: %@", kAppName, error);
}

- (void)applyOpenAtLoginPreference {
    // The "Open at login" setting decides. Register when it is on and the
    // item is not there yet ("not registered", or "not found" for a new app);
    // remove the item when it is off. If the user turned the item off in
    // System Settings, the status is "requires approval" and stays so.
    BOOL wanted = [[NSUserDefaults standardUserDefaults] boolForKey:GTVPrefOpenAtLogin];
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    if (wanted && status != SMAppServiceStatusEnabled && status != SMAppServiceStatusRequiresApproval)
        [self setOpenAtLogin:YES];
    else if (!wanted && status == SMAppServiceStatusEnabled)
        [self setOpenAtLogin:NO];
}

#pragma mark - Workspace

- (void)observeWorkspace {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    [center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        GTVActiveAppChanged(app.bundleIdentifier);
    }];
    [center addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        GTVRequestNewSession();
    }];
    __weak GTVAppDelegate *weakSelf = self;
    [center addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        // Create the tap again after sleep, as OpenKey did.
        if (AXIsProcessTrusted()) {
            GTVHookStop();
            [weakSelf startHook];
        }
    }];
}

#pragma mark - Helpers

- (void)activateApp {
    if (@available(macOS 14.0, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
}

@end
