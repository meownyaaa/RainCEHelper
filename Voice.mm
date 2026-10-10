#import "Voice.h"
#import "RTC.h"

static NSMutableArray *events;

void CEVoiceEmit(NSString *type, NSString *value) {
    NSLog(@"[ChangeEndpoint] voice %@: %@", type, value);
    @synchronized(CEVoiceSession.class) {
        if (!events) events = [NSMutableArray new];
        if (events.count > 200) [events removeObjectAtIndex:0];
        [events addObject:@[ type, value ?: @"" ]];
    }
}

NSArray *CEVoiceDrainEvents(void) {
    @synchronized(CEVoiceSession.class) {
        NSArray *out = events ?: @[];
        events = [NSMutableArray new];
        return out;
    }
}

static NSString *iceState(NSInteger s) {
    NSArray *names = @[ @"NEW", @"CHECKING", @"CONNECTED", @"COMPLETED", @"FAILED", @"DISCONNECTED", @"CLOSED" ];
    return s >= 0 && s < (NSInteger)names.count ? names[s] : [NSString stringWithFormat:@"%ld", (long)s];
}

static NSString *connectionState(NSInteger s) {
    NSArray *names = @[ @"NEW", @"CONNECTING", @"CONNECTED", @"DISCONNECTED", @"FAILED", @"CLOSED" ];
    return s >= 0 && s < (NSInteger)names.count ? names[s] : [NSString stringWithFormat:@"%ld", (long)s];
}

@interface CEVoiceSession ()
@property(nonatomic, strong) CERTCPeerConnectionFactory *factory;
@property(nonatomic, strong) CERTCAudioSource *audioSource;
@property(nonatomic, strong) CERTCAudioTrack *audioTrack;
@property(nonatomic, strong) CERTCPeerConnection *pc;
@property(nonatomic, strong) dispatch_semaphore_t gathered;
@property(nonatomic, assign) double gain;
@property(nonatomic, assign) BOOL deaf;
@end

@implementation CEVoiceSession

+ (BOOL)available {
    return CERTC(@"PeerConnectionFactory") != nil;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _gain = 1.0;
    _gathered = dispatch_semaphore_create(0);

    _factory = [[CERTC(@"PeerConnectionFactory") alloc] init];
    CERTCMediaConstraints *none = [[CERTC(@"MediaConstraints") alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
    _audioSource = [_factory audioSourceWithConstraints:none];
    _audioTrack = [_factory audioTrackWithSource:_audioSource trackId:@"audio"];

    CERTCConfiguration *config = [[CERTC(@"Configuration") alloc] init];
    config.iceServers = @[];
    config.sdpSemantics = CERTCSdpSemanticsUnifiedPlan;
    config.bundlePolicy = CERTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = CERTCRtcpMuxPolicyRequire;
    _pc = [_factory peerConnectionWithConfiguration:config constraints:none delegate:self];
    if (!_pc) return nil;

    CERTCRtpTransceiverInit *sendRecv = [[CERTC(@"RtpTransceiverInit") alloc] init];
    sendRecv.direction = CERTCRtpTransceiverDirectionSendRecv;
    [_pc addTransceiverWithTrack:_audioTrack init:sendRecv];
    return self;
}

- (void)offer:(CEDone)done {
    CERTCMediaConstraints *none = [[CERTC(@"MediaConstraints") alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
    __weak CEVoiceSession *weakSelf = self;
    [self.pc offerForConstraints:none
               completionHandler:^(CERTCSessionDescription *offer, NSError *error) {
                   CEVoiceSession *s = weakSelf;
                   if (!s) return done(nil, @"session closed");
                   if (error || !offer) return done(nil, error.localizedDescription ?: @"no offer");
                   dispatch_semaphore_t gathered = s.gathered;
                   [s.pc setLocalDescription:offer
                           completionHandler:^(NSError *setError) {
                               if (setError) return done(nil, setError.localizedDescription);
                               // the server needs our candidates in the offer, there's no trickle
                               dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                   dispatch_semaphore_wait(gathered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
                                   NSString *sdp = weakSelf.pc.localDescription.sdp;
                                   sdp ? done(sdp, nil) : done(nil, @"session closed");
                               });
                           }];
               }];
}

- (void)addAudioReceiver:(CEDone)done {
    CERTCRtpTransceiverInit *recvOnly = [[CERTC(@"RtpTransceiverInit") alloc] init];
    recvOnly.direction = CERTCRtpTransceiverDirectionRecvOnly;
    [self.pc addTransceiverOfType:CERTCRtpMediaTypeAudio init:recvOnly];
    self.gathered = dispatch_semaphore_create(0);
    [self offer:done];
}

- (void)answer:(NSString *)sdp done:(CEDone)done {
    CERTCSessionDescription *answer = [[CERTC(@"SessionDescription") alloc] initWithType:CERTCSdpTypeAnswer sdp:sdp];
    [self.pc setRemoteDescription:answer
                completionHandler:^(NSError *error) {
                    done(nil, error.localizedDescription);
                }];
}

- (void)setMuted:(BOOL)muted {
    self.audioTrack.isEnabled = !muted;
}

- (void)applyPlayout {
    for (CERTCRtpReceiver *receiver in self.pc.receivers) {
        CERTCMediaStreamTrack *track = receiver.track;
        if (![track.kind isEqualToString:@"audio"]) continue;
        track.isEnabled = !self.deaf;
        // gain, 1.0 is unchanged
        ((CERTCAudioTrack *)track).source.volume = self.gain;
    }
}

- (void)setDeafened:(BOOL)deafened {
    self.deaf = deafened;
    [self applyPlayout];
}

- (void)setOutputVolume:(double)volume {
    self.gain = volume;
    [self applyPlayout];
}

- (void)close {
    [self.pc close];
    self.pc = nil;
    self.audioTrack = nil;
    self.audioSource = nil;
    self.factory = nil;
}

#pragma mark - DiscordRTCPeerConnectionDelegate

- (void)peerConnection:(id)pc didChangeSignalingState:(NSInteger)state {
}
- (void)peerConnection:(id)pc didAddStream:(id)stream {
}
- (void)peerConnection:(id)pc didRemoveStream:(id)stream {
}
- (void)peerConnectionShouldNegotiate:(id)pc {
}
- (void)peerConnection:(id)pc didChangeIceConnectionState:(NSInteger)state {
    CEVoiceEmit(@"ice", iceState(state));
}
- (void)peerConnection:(id)pc didChangeIceGatheringState:(NSInteger)state {
    if (state == CERTCIceGatheringStateComplete) dispatch_semaphore_signal(self.gathered);
}
- (void)peerConnection:(id)pc didGenerateIceCandidate:(id)candidate {
}
- (void)peerConnection:(id)pc didRemoveIceCandidates:(NSArray *)candidates {
}
- (void)peerConnection:(id)pc didOpenDataChannel:(id)dataChannel {
}
- (void)peerConnection:(id)pc didChangeConnectionState:(NSInteger)state {
    CEVoiceEmit(@"connection", connectionState(state));
}
- (void)peerConnection:(id)pc didAddReceiver:(CERTCRtpReceiver *)receiver streams:(NSArray *)streams {
    [self applyPlayout];
    CEVoiceEmit(@"track", receiver.track.kind ?: @"");
}

@end
