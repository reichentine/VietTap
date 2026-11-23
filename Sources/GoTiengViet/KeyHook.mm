//
//  KeyHook.mm
//  Gõ Tiếng Việt
//
//  The keyboard hook. Adapted from OpenKey's OpenKey.mm (Tuyen Mai, GPL-3.0).
//  The code that talks to the engine and sends characters is unchanged.
//  Changes for the lean app:
//   - No UI classes: the app is told about language changes via an observer
//     block that runs after the event tap callback returns.
//   - The front app is cached from NSWorkspace notifications, not queried
//     from NSWorkspace on every key.
//   - Settings that have no UI are fixed: Telex, Unicode, browser fixes,
//     no macros, no convert tool, no layout compatibility mode.
//   - The tap is re-enabled when macOS disables it (timeout / user input).
//   - The tap lives on the main run loop (no nested CFRunLoopRun).
//

#import <Cocoa/Cocoa.h>
#import <os/log.h>
#import "Engine.h"
#import "GTVHook.h"

#define OTHER_CONTROL_KEY (_flag & kCGEventFlagMaskCommand) || (_flag & kCGEventFlagMaskControl) || \
                            (_flag & kCGEventFlagMaskAlternate) || (_flag & kCGEventFlagMaskSecondaryFn) || \
                            (_flag & kCGEventFlagMaskNumericPad) || (_flag & kCGEventFlagMaskHelp)

#define DYNA_DATA(macro, pos) (macro ? pData->macroData[pos] : pData->charData[pos])
#define MAX_UNICODE_STRING  20
#define EMPTY_HOTKEY 0xFE0000FE

// ---------------------------------------------------------------------------
// Engine settings. OpenKey defined these in its AppDelegate.
// Values without a control in Settings are fixed here.
// ---------------------------------------------------------------------------
int vLanguage = 1;
int vInputType = 0;               // Telex (fixed)
int vFreeMark = 0;
int vCodeTable = 0;               // Unicode (fixed)
int vCheckSpelling = 1;           // Settings
int vUseModernOrthography = 0;
int vQuickTelex = 0;
int vSwitchKeyStatus = GTVHotKeyControlShift; // Settings
int vRestoreIfWrongSpelling = 0;  // off: a wrong word stays visible, as a sign to switch input
int vFixRecommendBrowser = 1;     // autocomplete fix, only in the apps of _autocompleteApps
int vUseMacro = 0;
int vUseMacroInEnglishMode = 0;
int vAutoCapsMacro = 0;
int vSendKeyStepByStep = 0;
int vUseSmartSwitchKey = 1;       // Settings
int vUpperCaseFirstChar = 0;
int vTempOffSpelling = 0;
int vAllowConsonantZFWJ = 0;
int vQuickStartConsonant = 0;
int vQuickEndConsonant = 0;
int vRememberCode = 0;            // code table is fixed, nothing to remember
int vTempOffOpenKey = 0;
int vPerformLayoutCompat = 0;
int vFixChromiumBrowser = 1;      // Chromium autocomplete fix (fixed on)

static CFMachPortRef _eventTap = NULL;
static CFRunLoopSourceRef _runLoopSource = NULL;
static CFMachPortRef _targetTap = NULL;
static CFRunLoopSourceRef _targetRunLoopSource = NULL;
static BOOL _paused = NO;
static BOOL _sourcePaused = NO;
static void (^_languageObserver)(void) = nil;
static NSString *_ownBundleID = nil;

// ---------------------------------------------------------------------------
// Autocomplete fix per app.
// Fields with inline autocomplete (browser address bars, Spotlight) select
// the suggested rest of the word, so the first synthetic Backspace would
// delete the suggestion instead of a letter. OpenKey's fix: type an
// invisible character first (or, in Chromium browsers, select one letter
// with Shift+Left). OpenKey applied it in every app; here only the apps that
// have such fields get it, so other apps get fewer synthetic keys.
// Extra apps: defaults write com.sonvu.gotiengviet AutocompleteFixApps -array <bundle id> ...
// ---------------------------------------------------------------------------
enum { GTVFixNone = 0, GTVFixInvisibleChar = 1, GTVFixSelectLeft = 2 };

// OpenKey's Chromium list (exact match): Shift+Left instead of the invisible character.
static NSArray *_selectLeftApps = @[@"com.google.Chrome", @"com.brave.Browser",
                                    @"com.microsoft.edgemac.Dev", @"com.microsoft.edgemac.Beta",
                                    @"com.microsoft.Edge.Dev", @"com.microsoft.Edge"];
static NSArray *_autocompleteApps = @[
    @"com.apple.Spotlight",
    @"com.apple.Safari", @"com.apple.SafariTechnologyPreview",
    @"org.mozilla.firefox", @"org.mozilla.firefoxdeveloperedition", @"org.mozilla.nightly",
    @"com.microsoft.edgemac", @"com.microsoft.edgemac.Canary",
    @"com.google.Chrome.canary", @"com.google.Chrome.beta", @"com.google.Chrome.dev",
    @"com.brave.Browser.beta", @"com.brave.Browser.nightly",
    @"org.chromium.Chromium", @"company.thebrowser.Browser", @"company.thebrowser.dia",
    @"com.vivaldi.Vivaldi", @"com.operasoftware.Opera", @"com.operasoftware.OperaGX",
    @"app.zen-browser.zen", @"com.kagi.kagimacOS", @"com.duckduckgo.macos.browser",
];
static NSArray *_extraAutocompleteApps = @[];

static int _targetFix = GTVFixNone;   // fix mode of the app that gets the keys
static pid_t _targetPid = 0;

static int fixModeForApp(NSString *bundleID) {
    if (bundleID == nil)
        return GTVFixNone;
    if ([_selectLeftApps containsObject:bundleID])
        return GTVFixSelectLeft;
    if ([_autocompleteApps containsObject:bundleID] || [_extraAutocompleteApps containsObject:bundleID])
        return GTVFixInvisibleChar;
    return GTVFixNone;
}

extern "C" {
    //app which must sent special empty character
    NSArray* _niceSpaceApp = @[@"com.sublimetext.3",
                               @"com.sublimetext.2",
                             ];

    //app which error with unicode Compound
    NSArray* _unicodeCompoundApp = @[@"com.apple.",
                                     @"com.google.Chrome", @"com.brave.Browser",
                                     @"com.microsoft.edgemac.Dev", @"com.microsoft.edgemac.Beta", @"com.microsoft.Edge.Dev", @"com.microsoft.Edge"];

    CGEventSourceRef myEventSource = NULL;
    vKeyHookState* pData;
    CGEventRef eventBackSpaceDown;
    CGEventRef eventBackSpaceUp;
    UniChar _newChar, _newCharHi;
    CGEventRef _newEventDown, _newEventUp;
    CGKeyCode _keycode;
    CGEventFlags _flag, _lastFlag = 0, _privateFlag;
    CGEventTapProxy _proxy;

    Uint16 _newCharString[MAX_UNICODE_STRING];
    Uint16 _newCharSize;
    bool _willContinuteSending = false;
    bool _willSendControlKey = false;

    vector<Uint16> _syncKey;

    Uint16 _uniChar[2];
    int _i, _j, _k;
    Uint32 _tempChar;
    bool _hasJustUsedHotKey = false;

    int _languageTemp = 0; //use for smart switch key
    vector<Byte> savedSmartSwitchKeyData; ////use for smart switch key

    // Bundle ID of the frontmost app other than this one. Updated by
    // GTVActiveAppChanged; read on every key.
    NSString* _frontMostApp = @"UnknownApp";

    void GTVEngineInit() {
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        _ownBundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *front = [[NSWorkspace sharedWorkspace] frontmostApplication].bundleIdentifier;
        if (front != nil && ![front isEqualToString:_ownBundleID])
            _frontMostApp = front;
        NSArray *extra = [prefs arrayForKey:@"AutocompleteFixApps"];
        if (extra != nil)
            _extraAutocompleteApps = extra;
        _targetFix = fixModeForApp(_frontMostApp);

        vLanguage = (int)[prefs integerForKey:GTVPrefLanguage] ? 1 : 0;
        vSwitchKeyStatus = (int)[prefs integerForKey:GTVPrefSwitchKey];
        if (vSwitchKeyStatus == 0)
            vSwitchKeyStatus = GTVHotKeyControlShift;
        vCheckSpelling = [prefs boolForKey:GTVPrefSpelling] ? 1 : 0;
        vUseSmartSwitchKey = [prefs boolForKey:GTVPrefSmartSwitch] ? 1 : 0;

        myEventSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
        pData = (vKeyHookState*)vKeyInit();

        eventBackSpaceDown = CGEventCreateKeyboardEvent (myEventSource, 51, true);
        eventBackSpaceUp = CGEventCreateKeyboardEvent (myEventSource, 51, false);

        // No macros in this app.
        initMacroMap(NULL, 0);

        //init and load smart switch key data
        NSData *data = [prefs objectForKey:GTVPrefSmartData];
        initSmartSwitchKey((Byte*)data.bytes, (int)data.length);

        vSetCheckSpelling();
    }

    void RequestNewSession() {
        //send event signal to Engine
        vKeyHandleEvent(vKeyEvent::Mouse, vKeyEventState::MouseDown, 0);

        if (IS_DOUBLE_CODE(vCodeTable)) { //VNI
            _syncKey.clear();
        }
    }

    void GTVRequestNewSession() {
        RequestNewSession();
    }

    BOOL containUnicodeCompoundApp(NSString* topApp) {
        if (topApp == nil) return false;
        for (_j = 0; _j < [_unicodeCompoundApp count]; _j++) {
            if ([topApp hasPrefix:[_unicodeCompoundApp objectAtIndex:_j]] || [[_unicodeCompoundApp objectAtIndex:_j] isEqualToString:topApp])
                return true;
        }
        return false;
    }

    void saveSmartSwitchKeyData() {
        getSmartSwitchKeySaveData(savedSmartSwitchKeyData);
        NSData* _data = [NSData dataWithBytes:savedSmartSwitchKeyData.data() length:savedSmartSwitchKeyData.size()];
        [[NSUserDefaults standardUserDefaults] setObject:_data forKey:GTVPrefSmartData];
    }

    static void notifyLanguageObserver() {
        if (_languageObserver)
            _languageObserver();
    }

    // Saves the language for the current app (smart switch) and tells the UI.
    static void languageDidChange() {
        [[NSUserDefaults standardUserDefaults] setInteger:vLanguage forKey:GTVPrefLanguage];
        if (vUseSmartSwitchKey) {
            setAppInputMethodStatus(string(_frontMostApp.UTF8String), vLanguage | (vCodeTable << 1));
            saveSmartSwitchKeyData();
        }
        notifyLanguageObserver();
    }

    void GTVActiveAppChanged(NSString *bundleID) {
        if (bundleID == nil || [bundleID isEqualToString:_ownBundleID])
            return; // keep the last real app while Settings is in front
        _frontMostApp = bundleID;
        // Correct from the first key in the new app; the target tap refines
        // it for panels that do not become the front app (Spotlight).
        _targetFix = fixModeForApp(bundleID);
        _targetPid = 0;
        if (!vUseSmartSwitchKey)
            return;
        _languageTemp = getAppInputMethodStatus(string(_frontMostApp.UTF8String), vLanguage | (vCodeTable << 1));
        if (_languageTemp == -1) { // first time this app is seen: it was stored with the current language
            saveSmartSwitchKeyData();
            return;
        }
        if ((_languageTemp & 0x01) != vLanguage) {
            vLanguage = _languageTemp & 0x01;
            [[NSUserDefaults standardUserDefaults] setInteger:vLanguage forKey:GTVPrefLanguage];
            startNewSession();
            notifyLanguageObserver();
        }
    }

    void InsertKeyLength(const Uint8& len) {
        _syncKey.push_back(len);
    }

    void SendPureCharacter(const Uint16& ch) {
        _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
        _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
        CGEventKeyboardSetUnicodeString(_newEventDown, 1, &ch);
        CGEventKeyboardSetUnicodeString(_newEventUp, 1, &ch);
        CGEventTapPostEvent(_proxy, _newEventDown);
        CGEventTapPostEvent(_proxy, _newEventUp);
        CFRelease(_newEventDown);
        CFRelease(_newEventUp);
        if (IS_DOUBLE_CODE(vCodeTable)) {
            InsertKeyLength(1);
        }
    }

    void SendKeyCode(Uint32 data) {
        _newChar = (Uint16)data;
        if (!(data & CHAR_CODE_MASK)) {
            if (IS_DOUBLE_CODE(vCodeTable)) //VNI
                InsertKeyLength(1);

            _newEventDown = CGEventCreateKeyboardEvent(myEventSource, _newChar, true);
            _newEventUp = CGEventCreateKeyboardEvent(myEventSource, _newChar, false);
            _privateFlag = CGEventGetFlags(_newEventDown);

            if (data & CAPS_MASK) {
                _privateFlag |= kCGEventFlagMaskShift;
            } else {
                _privateFlag &= ~kCGEventFlagMaskShift;
            }
            _privateFlag |= kCGEventFlagMaskNonCoalesced;

            CGEventSetFlags(_newEventDown, _privateFlag);
            CGEventSetFlags(_newEventUp, _privateFlag);
            CGEventTapPostEvent(_proxy, _newEventDown);
            CGEventTapPostEvent(_proxy, _newEventUp);
        } else {
            if (vCodeTable == 0) { //unicode 2 bytes code
                _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
                _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
                CGEventKeyboardSetUnicodeString(_newEventDown, 1, &_newChar);
                CGEventKeyboardSetUnicodeString(_newEventUp, 1, &_newChar);
                CGEventTapPostEvent(_proxy, _newEventDown);
                CGEventTapPostEvent(_proxy, _newEventUp);
            } else if (vCodeTable == 1 || vCodeTable == 2 || vCodeTable == 4) { //others such as VNI Windows, TCVN3: 1 byte code
                _newCharHi = HIBYTE(_newChar);
                _newChar = LOBYTE(_newChar);

                _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
                _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
                CGEventKeyboardSetUnicodeString(_newEventDown, 1, &_newChar);
                CGEventKeyboardSetUnicodeString(_newEventUp, 1, &_newChar);
                CGEventTapPostEvent(_proxy, _newEventDown);
                CGEventTapPostEvent(_proxy, _newEventUp);
                if (_newCharHi > 32) {
                    if (vCodeTable == 2) //VNI
                        InsertKeyLength(2);
                    CFRelease(_newEventDown);
                    CFRelease(_newEventUp);
                    _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
                    _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
                    CGEventKeyboardSetUnicodeString(_newEventDown, 1, &_newCharHi);
                    CGEventKeyboardSetUnicodeString(_newEventUp, 1, &_newCharHi);
                    CGEventTapPostEvent(_proxy, _newEventDown);
                    CGEventTapPostEvent(_proxy, _newEventUp);
                } else {
                    if (vCodeTable == 2) //VNI
                        InsertKeyLength(1);
                }
            } else if (vCodeTable == 3) { //Unicode Compound
                _newCharHi = (_newChar >> 13);
                _newChar &= 0x1FFF;
                _uniChar[0] = _newChar;
                _uniChar[1] = _newCharHi > 0 ? (_unicodeCompoundMark[_newCharHi - 1]) : 0;
                InsertKeyLength(_newCharHi > 0 ? 2 : 1);
                _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
                _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
                CGEventKeyboardSetUnicodeString(_newEventDown, (_newCharHi > 0 ? 2 : 1), _uniChar);
                CGEventKeyboardSetUnicodeString(_newEventUp, (_newCharHi > 0 ? 2 : 1), _uniChar);
                CGEventTapPostEvent(_proxy, _newEventDown);
                CGEventTapPostEvent(_proxy, _newEventUp);
            }
        }
        CFRelease(_newEventDown);
        CFRelease(_newEventUp);
    }

    void SendEmptyCharacter() {
        if (IS_DOUBLE_CODE(vCodeTable)) //VNI or Unicode Compound
            InsertKeyLength(1);

        _newChar = 0x202F; //empty char
        if ([_niceSpaceApp containsObject:_frontMostApp]) {
            _newChar = 0x200C; //Unicode character with empty space
        }

        _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
        _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
        CGEventKeyboardSetUnicodeString(_newEventDown, 1, &_newChar);
        CGEventKeyboardSetUnicodeString(_newEventUp, 1, &_newChar);
        CGEventTapPostEvent(_proxy, _newEventDown);
        CGEventTapPostEvent(_proxy, _newEventUp);
        CFRelease(_newEventDown);
        CFRelease(_newEventUp);
    }

    void SendBackspace() {
        CGEventTapPostEvent(_proxy, eventBackSpaceDown);
        CGEventTapPostEvent(_proxy, eventBackSpaceUp);

        if (IS_DOUBLE_CODE(vCodeTable)) { //VNI or Unicode Compound
            if (_syncKey.back() > 1) {
                if (!(vCodeTable == 3 && containUnicodeCompoundApp(_frontMostApp))) {
                    CGEventTapPostEvent(_proxy, eventBackSpaceDown);
                    CGEventTapPostEvent(_proxy, eventBackSpaceUp);
                }
            }
            _syncKey.pop_back();
        }
    }

    void SendShiftAndLeftArrow() {
        CGEventRef eventVkeyDown = CGEventCreateKeyboardEvent (myEventSource, KEY_LEFT, true);
        CGEventRef eventVkeyUp = CGEventCreateKeyboardEvent (myEventSource, KEY_LEFT, false);
        _privateFlag = CGEventGetFlags(eventVkeyDown);
        _privateFlag |= kCGEventFlagMaskShift;
        CGEventSetFlags(eventVkeyDown, _privateFlag);
        CGEventSetFlags(eventVkeyUp, _privateFlag);

        CGEventTapPostEvent(_proxy, eventVkeyDown);
        CGEventTapPostEvent(_proxy, eventVkeyUp);

        if (IS_DOUBLE_CODE(vCodeTable)) { //VNI or Unicode Compound
            if (_syncKey.back() > 1) {
                if (!(vCodeTable == 3 && containUnicodeCompoundApp(_frontMostApp))) {
                    CGEventTapPostEvent(_proxy, eventVkeyDown);
                    CGEventTapPostEvent(_proxy, eventVkeyUp);
                }
            }
            _syncKey.pop_back();
        }
        CFRelease(eventVkeyDown);
        CFRelease(eventVkeyUp);
    }

    void SendNewCharString(const bool& dataFromMacro=false, const Uint16& offset=0) {
        _j = 0;
        _newCharSize = dataFromMacro ? pData->macroData.size() : pData->newCharCount;
        _willContinuteSending = false;
        _willSendControlKey = false;

        if (_newCharSize > 0) {
            for (_k = dataFromMacro ? offset : pData->newCharCount - 1 - offset;
                 dataFromMacro ? _k < pData->macroData.size() : _k >= 0;
                 dataFromMacro ? _k++ : _k--) {

                if (_j >= 16) {
                    _willContinuteSending = true;
                    break;
                }

                _tempChar = DYNA_DATA(dataFromMacro, _k);
                if (_tempChar & PURE_CHARACTER_MASK) {
                    _newCharString[_j++] = _tempChar;
                    if (IS_DOUBLE_CODE(vCodeTable)) {
                        InsertKeyLength(1);
                    }
                } else if (!(_tempChar & CHAR_CODE_MASK)) {
                    if (IS_DOUBLE_CODE(vCodeTable)) //VNI
                        InsertKeyLength(1);
                    _newCharString[_j++] = keyCodeToCharacter(_tempChar);
                } else {
                    if (vCodeTable == 0) {  //unicode 2 bytes code
                        _newCharString[_j++] = _tempChar;
                    } else if (vCodeTable == 1 || vCodeTable == 2 || vCodeTable == 4) { //others such as VNI Windows, TCVN3: 1 byte code
                        _newChar = _tempChar;
                        _newCharHi = HIBYTE(_newChar);
                        _newChar = LOBYTE(_newChar);
                        _newCharString[_j++] = _newChar;

                        if (_newCharHi > 32) {
                            if (vCodeTable == 2) //VNI
                                InsertKeyLength(2);
                            _newCharString[_j++] = _newCharHi;
                            _newCharSize++;
                        } else {
                            if (vCodeTable == 2) //VNI
                                InsertKeyLength(1);
                        }
                    } else if (vCodeTable == 3) { //Unicode Compound
                        _newChar = _tempChar;
                        _newCharHi = (_newChar >> 13);
                        _newChar &= 0x1FFF;

                        InsertKeyLength(_newCharHi > 0 ? 2 : 1);
                        _newCharString[_j++] = _newChar;
                        if (_newCharHi > 0) {
                            _newCharSize++;
                            _newCharString[_j++] = _unicodeCompoundMark[_newCharHi - 1];
                        }

                    }
                }
            }//end for
        }

        if (!_willContinuteSending && (pData->code == vRestore || pData->code == vRestoreAndStartNewSession)) { //if is restore
            if (keyCodeToCharacter(_keycode) != 0) {
                _newCharSize++;
                _newCharString[_j++] = keyCodeToCharacter(_keycode | ((_flag & kCGEventFlagMaskAlphaShift) || (_flag & kCGEventFlagMaskShift) ? CAPS_MASK : 0));
            } else {
                _willSendControlKey = true;
            }
        }
        if (!_willContinuteSending && pData->code == vRestoreAndStartNewSession) {
            startNewSession();
        }

        _newEventDown = CGEventCreateKeyboardEvent(myEventSource, 0, true);
        _newEventUp = CGEventCreateKeyboardEvent(myEventSource, 0, false);
        CGEventKeyboardSetUnicodeString(_newEventDown, _willContinuteSending ? 16 : _newCharSize - offset, _newCharString);
        CGEventKeyboardSetUnicodeString(_newEventUp, _willContinuteSending ? 16 : _newCharSize - offset, _newCharString);
        CGEventTapPostEvent(_proxy, _newEventDown);
        CGEventTapPostEvent(_proxy, _newEventUp);
        CFRelease(_newEventDown);
        CFRelease(_newEventUp);

        if (_willContinuteSending) {
            SendNewCharString(dataFromMacro, dataFromMacro ? _k : 16);
        }

        //the case when hCode is vRestore or vRestoreAndStartNewSession, the word is invalid and last key is control key such as TAB, LEFT ARROW, RIGHT ARROW,...
        if (_willSendControlKey) {
            SendKeyCode(_keycode);
        }
    }

    bool checkHotKey(int hotKeyData, bool checkKeyCode=true) {
        if ((hotKeyData & (~0x8000)) == EMPTY_HOTKEY)
            return false;
        if (HAS_CONTROL(hotKeyData) ^ GET_BOOL(_lastFlag & kCGEventFlagMaskControl))
            return false;
        if (HAS_OPTION(hotKeyData) ^ GET_BOOL(_lastFlag & kCGEventFlagMaskAlternate))
            return false;
        if (HAS_COMMAND(hotKeyData) ^ GET_BOOL(_lastFlag & kCGEventFlagMaskCommand))
            return false;
        if (HAS_SHIFT(hotKeyData) ^ GET_BOOL(_lastFlag & kCGEventFlagMaskShift))
            return false;
        if (checkKeyCode) {
            if (GET_SWITCH_KEY(hotKeyData) != _keycode)
                return false;
        }
        return true;
    }

    static bool _languageUISyncPending = false;
    static void (^_hotKeySwitchObserver)(int) = nil;

    // The event tap callback runs on the main thread, and macOS holds every
    // later key event until it returns. So the hotkey path only flips the
    // engine state; the sound, saving and the UI run right after the
    // callback returns. Several switches before that collapse into one
    // update with the final language.
    static void scheduleLanguageDidChange() {
        if (_languageUISyncPending)
            return;
        _languageUISyncPending = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            _languageUISyncPending = false;
            if (_hotKeySwitchObserver)
                _hotKeySwitchObserver(vLanguage); // sound first: least delay
            languageDidChange();
        });
    }

    void switchLanguage() {
        vLanguage = (vLanguage == 0) ? 1 : 0;
        os_log(OS_LOG_DEFAULT, "GTV: switch key, language %d", vLanguage);
        startNewSession();
        scheduleLanguageDidChange();
    }

    void GTVSetHotKeySwitchObserver(void (^observer)(int language)) {
        _hotKeySwitchObserver = [observer copy];
    }

    int GTVGetLanguage() {
        return vLanguage;
    }

    void GTVToggleLanguage() {
        vLanguage = (vLanguage == 0) ? 1 : 0;
        startNewSession();
        languageDidChange();
    }

    void GTVSetLanguageObserver(void (^observer)(void)) {
        _languageObserver = [observer copy];
    }

    void GTVSetSwitchKey(int hotKey) {
        vSwitchKeyStatus = hotKey;
        _lastFlag = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:hotKey forKey:GTVPrefSwitchKey];
    }

    void GTVSetSpelling(BOOL on) {
        vCheckSpelling = on ? 1 : 0;
        vSetCheckSpelling();
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:GTVPrefSpelling];
    }

    void GTVSetSmartSwitch(BOOL on) {
        vUseSmartSwitchKey = on ? 1 : 0;
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:GTVPrefSmartSwitch];
    }

    void handleMacro() {
        //fix autocomplete
        if (vFixRecommendBrowser) {
            SendEmptyCharacter();
            pData->backspaceCount++;
        }

        //send backspace
        if (pData->backspaceCount > 0) {
            for (int i = 0; i < pData->backspaceCount; i++) {
                SendBackspace();
            }
        }
        //send real data
        if (!vSendKeyStepByStep) {
            SendNewCharString(true);
        } else {
            for (int i = 0; i < pData->macroData.size(); i++) {
                if (pData->macroData[i] & PURE_CHARACTER_MASK) {
                    SendPureCharacter(pData->macroData[i]);
                } else {
                    SendKeyCode(pData->macroData[i]);
                }
            }
        }
        SendKeyCode(_keycode | (_flag & kCGEventFlagMaskShift ? CAPS_MASK : 0));
    }

    /**
     * MAIN HOOK entry, very important function.
     * MAIN Callback.
     */
    CGEventRef OpenKeyCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
        // macOS turns the tap off when a callback is too slow or when secure
        // input starts; turn it on again.
        if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
            os_log(OS_LOG_DEFAULT, "GTV: macOS turned the hook off (%{public}s), turning it on",
                   type == kCGEventTapDisabledByTimeout ? "timeout" : "user input");
            if (_eventTap != NULL)
                CGEventTapEnable(_eventTap, true);
            return event;
        }

        if (_paused || _sourcePaused)
            return event;

        //dont handle my event
        if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) == CGEventSourceGetSourceStateID(myEventSource)) {
            return event;
        }

        _flag = CGEventGetFlags(event);
        _keycode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

        //switch language shortcut
        if (type == kCGEventKeyDown) {
            if (GET_SWITCH_KEY(vSwitchKeyStatus) != _keycode) {
                _lastFlag = 0;
            } else {
                if (checkHotKey(vSwitchKeyStatus, GET_SWITCH_KEY(vSwitchKeyStatus) != 0xFE)){
                    switchLanguage();
                    _lastFlag = 0;
                    _hasJustUsedHotKey = true;
                    return NULL;
                }
            }
            _hasJustUsedHotKey = _lastFlag != 0;
        } else if (type == kCGEventFlagsChanged) {
            if (_lastFlag == 0 || _lastFlag < _flag) {
                _lastFlag = _flag;
            } else if (_lastFlag > _flag)  {
                //check switch
                if (checkHotKey(vSwitchKeyStatus, GET_SWITCH_KEY(vSwitchKeyStatus) != 0xFE)) {
                    _lastFlag = 0;
                    switchLanguage();
                    _hasJustUsedHotKey = true;
                    return NULL;
                }
                _lastFlag = 0;
                _hasJustUsedHotKey = false;
            }
        }

        // Also check correct event hooked
        if ((type != kCGEventKeyDown) && (type != kCGEventKeyUp) &&
            (type != kCGEventLeftMouseDown) && (type != kCGEventRightMouseDown) &&
            (type != kCGEventLeftMouseDragged) && (type != kCGEventRightMouseDragged))
            return event;

        _proxy = proxy;

        //If is in english mode
        if (vLanguage == 0) {
            return event;
        }

        //handle mouse
        if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
            RequestNewSession();
            return event;
        }

        //handle keyboard
        if (type == kCGEventKeyDown) {
            //send event signal to Engine
            vKeyHandleEvent(vKeyEvent::Keyboard,
                            vKeyEventState::KeyDown,
                            _keycode,
                            _flag & kCGEventFlagMaskShift ? 1 : (_flag & kCGEventFlagMaskAlphaShift ? 2 : 0),
                            OTHER_CONTROL_KEY);
            if (pData->code == vDoNothing) { //do nothing
                if (IS_DOUBLE_CODE(vCodeTable)) { //VNI
                    if (pData->extCode == 1) { //break key
                        _syncKey.clear();
                    } else if (pData->extCode == 2) { //delete key
                        if (_syncKey.size() > 0) {
                            if (_syncKey.back() > 1 && (vCodeTable == 2 || !containUnicodeCompoundApp(_frontMostApp))) {
                                //send one more backspace
                                CGEventTapPostEvent(_proxy, eventBackSpaceDown);
                                CGEventTapPostEvent(_proxy, eventBackSpaceUp);
                            }
                            _syncKey.pop_back();
                        }

                    } else if (pData->extCode == 3) { //normal key
                        InsertKeyLength(1);
                    }
                }
                return event;
            } else if (pData->code == vWillProcess || pData->code == vRestore || pData->code == vRestoreAndStartNewSession) { //handle result signal

                //fix autocomplete (only in apps with inline autocomplete)
                if (vFixRecommendBrowser && _targetFix != GTVFixNone && pData->extCode != 4) {
                    if (vFixChromiumBrowser && _targetFix == GTVFixSelectLeft) {
                        if (pData->backspaceCount > 0) {
                            SendShiftAndLeftArrow();
                            if (pData->backspaceCount == 1)
                                pData->backspaceCount--;
                        }
                    } else {
                        SendEmptyCharacter();
                        pData->backspaceCount++;

                    }
                }

                //send backspace
                if (pData->backspaceCount > 0 && pData->backspaceCount < MAX_BUFF) {
                    for (_i = 0; _i < pData->backspaceCount; _i++) {
                        SendBackspace();
                    }
                }

                //send new character
                if (!vSendKeyStepByStep) {
                    SendNewCharString();
                } else {
                    if (pData->newCharCount > 0 && pData->newCharCount <= MAX_BUFF) {
                        for (int i = pData->newCharCount - 1; i >= 0; i--) {
                            SendKeyCode(pData->charData[i]);
                        }
                    }
                    if (pData->code == vRestore || pData->code == vRestoreAndStartNewSession) {
                        SendKeyCode(_keycode | ((_flag & kCGEventFlagMaskAlphaShift) || (_flag & kCGEventFlagMaskShift) ? CAPS_MASK : 0));
                    }
                    if (pData->code == vRestoreAndStartNewSession) {
                        startNewSession();
                    }
                }
            } else if (pData->code == vReplaceMaro) { //MACRO
                handleMacro();
            }

            return NULL;
        }

        return event;
    }

    // Second tap, placed after macOS has chosen the app that gets each key
    // (annotated session tap). It only reads that app, so that a panel that
    // never becomes the front app (Spotlight) gets the right autocomplete fix
    // from its next key on. It never changes, holds or drops an event.
    CGEventRef TargetCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
        if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
            if (_targetTap != NULL)
                CGEventTapEnable(_targetTap, true);
            return event;
        }
        pid_t pid = (pid_t)CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID);
        if (pid > 0 && pid != _targetPid) {
            _targetPid = pid;
            NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
            int mode = fixModeForApp(bundleID);
            if (mode != _targetFix)
                os_log(OS_LOG_DEFAULT, "GTV: keys go to %{public}@, autocomplete fix %d", bundleID, mode);
            _targetFix = mode;
        }
        return event;
    }

    static void startTargetTap() {
        _targetTap = CGEventTapCreate(kCGAnnotatedSessionEventTap,
                                      kCGTailAppendEventTap,
                                      kCGEventTapOptionDefault,
                                      CGEventMaskBit(kCGEventKeyDown),
                                      TargetCallback,
                                      NULL);
        if (_targetTap == NULL) {
            os_log(OS_LOG_DEFAULT, "GTV: target tap not available, using the front app only");
            return;
        }
        _targetRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _targetTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _targetRunLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_targetTap, true);
    }

    static void stopTargetTap() {
        if (_targetTap == NULL)
            return;
        CGEventTapEnable(_targetTap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _targetRunLoopSource, kCFRunLoopCommonModes);
        CFRelease(_targetRunLoopSource);
        _targetRunLoopSource = NULL;
        CFMachPortInvalidate(_targetTap);
        CFRelease(_targetTap);
        _targetTap = NULL;
    }

    BOOL GTVHookStart() {
        if (_eventTap != NULL)
            return YES;
        CGEventMask eventMask = ((1 << kCGEventKeyDown) |
                                 (1 << kCGEventKeyUp) |
                                 (1 << kCGEventFlagsChanged) |
                                 (1 << kCGEventLeftMouseDown) |
                                 (1 << kCGEventRightMouseDown) |
                                 (1 << kCGEventLeftMouseDragged) |
                                 (1 << kCGEventRightMouseDragged));
        _eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault,
                                     eventMask,
                                     OpenKeyCallback,
                                     NULL);
        if (_eventTap == NULL)
            return NO;
        _runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_eventTap, true);
        startTargetTap();
        startNewSession();
        return YES;
    }

    void GTVHookStop() {
        stopTargetTap();
        if (_eventTap == NULL)
            return;
        CGEventTapEnable(_eventTap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);
        CFRelease(_runLoopSource);
        _runLoopSource = NULL;
        CFMachPortInvalidate(_eventTap);
        CFRelease(_eventTap);
        _eventTap = NULL;
    }

    BOOL GTVHookIsRunning() {
        return _eventTap != NULL && CGEventTapIsEnabled(_eventTap);
    }
    
    // Turns the taps on again if macOS turned them off without telling the
    // callback. Called every few seconds by the app.
    void GTVHookWatchdog() {
        if (_eventTap != NULL && !CGEventTapIsEnabled(_eventTap)) {
            os_log(OS_LOG_DEFAULT, "GTV: watchdog found the hook off, turning it on");
            CGEventTapEnable(_eventTap, true);
        }
        if (_targetTap != NULL && !CGEventTapIsEnabled(_targetTap))
            CGEventTapEnable(_targetTap, true);
    }

    void GTVHookSetInputSourcePaused(BOOL paused) {
        if (paused == _sourcePaused)
            return;
        _sourcePaused = paused;
        _lastFlag = 0;
        startNewSession();
    }

    BOOL GTVHookIsInputSourcePaused() {
        return _sourcePaused;
    }

    void GTVHookSetPaused(BOOL paused) {
        _paused = paused;
        _lastFlag = 0;
        if (!paused)
            startNewSession();
    }
}
