#import <Foundation/Foundation.h>

typedef void (^CEDone)(id result, NSString *error);

@interface CEVoiceSession : NSObject
@property(nonatomic, readonly) NSString *sessionId;
+ (BOOL)available;
- (instancetype)initWithId:(NSString *)sessionId sendAudio:(BOOL)sendAudio receiveVideo:(BOOL)receiveVideo;
- (void)offer:(CEDone)done;
- (void)addAudioReceiver:(CEDone)done;
- (void)addVideoReceiver:(CEDone)done;
- (void)renegotiate:(CEDone)done;
- (void)stats:(CEDone)done;
- (BOOL)attachVideoMid:(NSString *)mid streamId:(NSString *)streamId;
- (void)answer:(NSString *)sdp done:(CEDone)done;
- (void)setMuted:(BOOL)muted;
- (void)setDeafened:(BOOL)deafened;
- (void)setOutputVolume:(double)volume;
- (void)close;
@end

// engine events for js, drained by polling
void CEVoiceEmit(NSString *sessionId, NSString *type, NSString *value);
NSArray *CEVoiceDrainEvents(void);
