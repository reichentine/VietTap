//
//  GTVHook.h
//  Gõ Tiếng Việt — a lean menu bar front end for the OpenKey engine.
//
//  Interface between the app (AppDelegate) and the keyboard hook (KeyHook.mm).
//  Everything runs on the main thread: the event tap is attached to the main
//  run loop, and the app calls these functions only from the main thread.
//
//  Based on OpenKey by Tuyen Mai (GPL-3.0).
//

#import <Foundation/Foundation.h>

// Preference keys (NSUserDefaults, domain com.sonvu.gotiengviet).
#define GTVPrefLanguage      @"InputMethod"       // 0 English, 1 Vietnamese
#define GTVPrefSwitchKey     @"SwitchKeyStatus"   // OpenKey hotkey format
#define GTVPrefSpelling      @"Spelling"
#define GTVPrefSmartSwitch   @"UseSmartSwitchKey" // remember language per app
#define GTVPrefOpenAtLogin   @"RunOnStartup"
#define GTVPrefSmartData     @"smartSwitchKey"    // per-app data blob

// OpenKey hotkey format: bits 0-7 key code (0xFE = modifiers only),
// 0x100 Control, 0x200 Option, 0x400 Command, 0x800 Shift, 0x8000 beep,
// bits 24-31 the key's character (for display).
#define GTVHotKeyControlShift ((int)0xFE0009FE)

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the settings into the engine and creates its state. Call once.
void GTVEngineInit(void);

/// Creates the event tap on the main run loop. NO if Accessibility is missing.
BOOL GTVHookStart(void);
void GTVHookStop(void);
BOOL GTVHookIsRunning(void);

/// While paused, the hook passes every event through (used while the
/// Settings window records a new switch key).
void GTVHookSetPaused(BOOL paused);

int  GTVGetLanguage(void);
void GTVToggleLanguage(void);

/// Called after every language change (hotkey, menu, or smart switch),
/// after the event tap callback has returned.
void GTVSetLanguageObserver(void (^observer)(void));

/// Settings changed in the Settings window.
void GTVSetSwitchKey(int hotKey);
void GTVSetSpelling(BOOL on);
void GTVSetSmartSwitch(BOOL on);

/// NSWorkspace notifications.
void GTVActiveAppChanged(NSString *bundleID);
void GTVRequestNewSession(void);

#ifdef __cplusplus
}
#endif
