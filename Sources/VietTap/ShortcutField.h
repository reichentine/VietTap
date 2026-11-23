//
//  ShortcutField.h
//  VietTap
//
//  A button that records the switch key. Click it, then press either a
//  modifier combination (for example Control+Shift, then release) or a
//  modifier plus a key (for example Option+Z). Escape cancels.
//  The value uses OpenKey's hotkey format (see VTHook.h).
//

#import <Cocoa/Cocoa.h>

@interface VTShortcutField : NSButton

@property (nonatomic) int hotKey;
@property (nonatomic, copy) void (^onChange)(int hotKey);

/// "⌃⇧", "⌥Z", ...
+ (NSString *)displayStringForHotKey:(int)hotKey;

@end
