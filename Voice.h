#import <Foundation/Foundation.h>

typedef void (^CEDone)(id result, NSString *error);

@interface CEVoiceSession : NSObject
+ (BOOL)available;
- (instancetype)init;
- (void)offer:(CEDone)done;
- (void)addAudioReceiver:(CEDone)done;
- (void)answer:(NSString *)sdp done:(CEDone)done;
- (void)setMuted:(BOOL)muted;
- (void)setDeafened:(BOOL)deafened;
- (void)setOutputVolume:(double)volume;
- (void)close;
@end

// engine events for js, drained by polling
void CEVoiceEmit(NSString *type, NSString *value);
NSArray *CEVoiceDrainEvents(void);
