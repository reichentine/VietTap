//
//  VTHook.h
//  VietTap — a lean menu bar front end for the OpenKey engine.
//
//  Interface between the app (AppDelegate) and the keyboard hook (KeyHook.mm).
//  Everything runs on the main thread: the event tap is attached to the main
//  run loop, and the app calls these functions only from the main thread.
//
//  Based on OpenKey by Tuyen Mai (GPL-3.0).
//

#import <Foundation/Foundation.h>

// Preference keys (NSUserDefaults, domain com.sonvu.viettap).
#define VTPrefLanguage      @"InputMethod"       // 0 English, 1 Vietnamese
#define VTPrefSwitchKey     @"SwitchKeyStatus"   // OpenKey hotkey format
#define VTPrefSpelling      @"Spelling"
#define VTPrefSmartSwitch   @"UseSmartSwitchKey" // remember language per app
#define VTPrefOpenAtLogin   @"RunOnStartup"
#define VTPrefSmartData     @"smartSwitchKey"    // per-app data blob
#define VTPrefSwitchSound   @"PlaySwitchSound"   // chime on the switch key

// OpenKey hotkey format: bits 0-7 key code (0xFE = modifiers only),
// 0x100 Control, 0x200 Option, 0x400 Command, 0x800 Shift, 0x8000 beep,
// bits 24-31 the key's character (for display).
#define VTHotKeyControlShift ((int)0xFE0009FE)

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the settings into the engine and creates its state. Call once.
void VTEngineInit(void);

/// Creates the event tap on the main run loop. NO if Accessibility is missing.
BOOL VTHookStart(void);
void VTHookStop(void);
BOOL VTHookIsRunning(void);

/// Turns the taps on again if macOS turned them off. Call every few seconds.
void VTHookWatchdog(void);

/// While paused, the hook passes every event through (used while the
/// Settings window records a new switch key).
void VTHookSetPaused(BOOL paused);

/// While a macOS input method (not a plain keyboard layout) is selected, for
/// example Apple's Vietnamese input or a Japanese input, the hook passes
/// every event through, so that no key is converted twice.
void VTHookSetInputSourcePaused(BOOL paused);
BOOL VTHookIsInputSourcePaused(void);

int  VTGetLanguage(void);
void VTToggleLanguage(void);

/// Called after every language change (hotkey, menu, or smart switch),
/// after the event tap callback has returned.
void VTSetLanguageObserver(void (^observer)(void));

/// Called only when the switch key changed the language (not the menu and
/// not the per-app memory), right after the event tap callback returns.
/// language: the new language.
void VTSetHotKeySwitchObserver(void (^observer)(int language));

/// Settings changed in the Settings window.
void VTSetSwitchKey(int hotKey);
void VTSetSpelling(BOOL on);
void VTSetSmartSwitch(BOOL on);

/// NSWorkspace notifications.
void VTActiveAppChanged(NSString *bundleID);
void VTRequestNewSession(void);

#ifdef __cplusplus
}
#endif
