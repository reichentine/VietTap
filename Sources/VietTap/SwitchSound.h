//
//  SwitchSound.h
//  VietTap
//
//  The switch key sound: macOS "Tink" when Vietnamese turns on, "Pop" when
//  English turns on. Both are system sounds, so the app has no sound files.
//

#import <Foundation/Foundation.h>

@interface VTSwitchSound : NSObject

/// Loads both sounds and warms up audio output, so that the first switch
/// does not wait for the audio device. Call once at launch.
+ (void)prepare;

/// language: 1 Vietnamese, 0 English. Returns immediately.
+ (void)playForLanguage:(int)language;

@end
