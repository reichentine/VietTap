//
//  ShortcutField.m
//  Gõ Tiếng Việt
//

#import "ShortcutField.h"
#import "GTVHook.h"
#import <Carbon/Carbon.h>

static const NSEventModifierFlags kRecordedModifiers =
    NSEventModifierFlagControl | NSEventModifierFlagOption |
    NSEventModifierFlagShift | NSEventModifierFlagCommand;

@implementation GTVShortcutField {
    id _monitor;
    BOOL _recording;
    NSEventModifierFlags _peakModifiers;
}

- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.bezelStyle = NSBezelStylePush;
        self.target = self;
        self.action = @selector(toggleRecording:);
        self.toolTip = @"Click, then press the new shortcut. Press Escape to cancel.";
    }
    return self;
}

- (void)dealloc {
    [self stopRecording];
}

+ (NSString *)displayStringForHotKey:(int)hotKey {
    NSMutableString *s = [NSMutableString string];
    if (hotKey & 0x100) [s appendString:@"⌃"];
    if (hotKey & 0x200) [s appendString:@"⌥"];
    if (hotKey & 0x800) [s appendString:@"⇧"];
    if (hotKey & 0x400) [s appendString:@"⌘"];
    if ((hotKey & 0xFF) != 0xFE) {
        unichar c = (unichar)((hotKey >> 24) & 0xFF);
        if (c == ' ')
            [s appendString:@"Space"];
        else if (c > ' ')
            [s appendFormat:@"%C", c];
        else
            [s appendFormat:@"Key %d", hotKey & 0xFF];
    }
    return s.length ? s : @"None";
}

- (void)setHotKey:(int)hotKey {
    _hotKey = hotKey;
    if (!_recording)
        self.title = [GTVShortcutField displayStringForHotKey:hotKey];
}

- (void)toggleRecording:(id)sender {
    if (_recording)
        [self stopRecording];
    else
        [self startRecording];
}

- (void)startRecording {
    _recording = YES;
    _peakModifiers = 0;
    self.title = @"Type shortcut…";
    GTVHookSetPaused(YES); // keep the current shortcut from switching meanwhile
    __weak GTVShortcutField *weakSelf = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskFlagsChanged)
                                                     handler:^NSEvent *(NSEvent *event) {
        return [weakSelf handleRecordingEvent:event];
    }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidResignKey:)
                                                 name:NSWindowDidResignKeyNotification object:self.window];
}

- (void)stopRecording {
    if (!_recording)
        return;
    _recording = NO;
    if (_monitor) {
        [NSEvent removeMonitor:_monitor];
        _monitor = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    GTVHookSetPaused(NO);
    self.title = [GTVShortcutField displayStringForHotKey:_hotKey];
}

- (void)windowDidResignKey:(NSNotification *)note {
    [self stopRecording];
}

static int modifierBits(NSEventModifierFlags m) {
    int bits = 0;
    if (m & NSEventModifierFlagControl) bits |= 0x100;
    if (m & NSEventModifierFlagOption)  bits |= 0x200;
    if (m & NSEventModifierFlagCommand) bits |= 0x400;
    if (m & NSEventModifierFlagShift)   bits |= 0x800;
    return bits;
}

- (void)finishWithKeyCode:(int)keyCode character:(int)character modifiers:(NSEventModifierFlags)mods {
    int value = (int)(((unsigned int)character & 0xFF) << 24) | modifierBits(mods) | (keyCode & 0xFF);
    _hotKey = value;
    [self stopRecording];
    if (self.onChange)
        self.onChange(value);
}

- (NSEvent *)handleRecordingEvent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & kRecordedModifiers;

    if (event.type == NSEventTypeFlagsChanged) {
        if (mods) {
            _peakModifiers |= mods;
        } else {
            // All modifiers released without a key: a modifier-only shortcut.
            // Require two modifiers, so that a single Shift tap never switches.
            if (__builtin_popcountll(_peakModifiers) >= 2)
                [self finishWithKeyCode:0xFE character:0xFE modifiers:_peakModifiers];
            _peakModifiers = 0;
        }
        return nil;
    }

    // Key down.
    if (event.keyCode == kVK_Escape && mods == 0) {
        [self stopRecording];
        return nil;
    }
    NSString *chars = event.charactersIgnoringModifiers.uppercaseString;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (mods == 0 || c < ' ' || c > '~') {
        NSBeep(); // needs a modifier and a plain key
        return nil;
    }
    [self finishWithKeyCode:event.keyCode character:c modifiers:mods];
    return nil;
}

@end
