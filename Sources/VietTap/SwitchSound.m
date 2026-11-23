//
//  SwitchSound.m
//  VietTap
//

#import "SwitchSound.h"
#import <Cocoa/Cocoa.h>

static const float kVolume = 0.35f; // softer than a normal alert

static NSSound *_vietnameseSound = nil;
static NSSound *_englishSound = nil;

@implementation VTSwitchSound

+ (void)prepare {
    // Copies, so that the volume change does not touch the shared instances.
    _vietnameseSound = [[NSSound soundNamed:@"Tink"] copy];
    _englishSound = [[NSSound soundNamed:@"Pop"] copy];
    // Silent warm-up of the audio output.
    _vietnameseSound.volume = 0.0f;
    [_vietnameseSound play];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [_vietnameseSound stop];
        _vietnameseSound.volume = kVolume;
        _englishSound.volume = kVolume;
    });
}

+ (void)playForLanguage:(int)language {
    NSSound *sound = language == 1 ? _vietnameseSound : _englishSound;
    NSSound *other = language == 1 ? _englishSound : _vietnameseSound;
    [other stop];
    [sound stop]; // restart if it is still playing
    [sound play];
}

@end
