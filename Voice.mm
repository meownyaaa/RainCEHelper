#import "Voice.h"
#import "RTC.h"
#import "Frames.h"
#import "Video.h"

static NSMutableArray *events;

void CEVoiceEmit(NSString *sessionId, NSString *type, NSString *value) {
    NSLog(@"[ChangeEndpoint] voice %@ %@: %@", sessionId, type, value);
    @synchronized(CEVoiceSession.class) {
        if (!events) events = [NSMutableArray new];
        if (events.count > 200) [events removeObjectAtIndex:0];
        [events addObject:@[ sessionId ?: @"", type, value ?: @"" ]];
    }
}

// one factory and so one audio device for every session, a second one would fight over the mic
static CERTCPeerConnectionFactory *sharedFactory(void) {
    static CERTCPeerConnectionFactory *factory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        factory = [[CERTC(@"PeerConnectionFactory") alloc] init];
    });
    return factory;
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
@property(nonatomic, readwrite) NSString *sessionId;
@property(nonatomic, strong) CERTCAudioSource *audioSource;
@property(nonatomic, strong) CERTCAudioTrack *audioTrack;
@property(nonatomic, strong) CERTCPeerConnection *pc;
@property(nonatomic, strong) dispatch_semaphore_t gathered;
@property(nonatomic, assign) double gain;
@property(nonatomic, assign) BOOL deaf;
@property(nonatomic, strong) NSMutableSet<NSString *> *streamIds;
@property(nonatomic, strong) CERTCVideoSource *screenSource;
@property(nonatomic, strong) CERTCVideoTrack *screenTrack;
@end

@implementation CEVoiceSession

+ (BOOL)available {
    return CERTC(@"PeerConnectionFactory") != nil;
}

- (instancetype)initWithId:(NSString *)sessionId sendAudio:(BOOL)sendAudio receiveVideo:(BOOL)receiveVideo sendScreen:(BOOL)sendScreen {
    if (!(self = [super init])) return nil;
    _sessionId = sessionId;
    _streamIds = [NSMutableSet new];
    _gain = 1.0;
    _gathered = dispatch_semaphore_create(0);

    CERTCPeerConnectionFactory *factory = sharedFactory();
    CERTCMediaConstraints *none = [[CERTC(@"MediaConstraints") alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
    _audioSource = [factory audioSourceWithConstraints:none];
    _audioTrack = [factory audioTrackWithSource:_audioSource trackId:[@"audio-" stringByAppendingString:sessionId]];
    // stream viewing keeps the same m-line layout but never sends the mic
    _audioTrack.isEnabled = sendAudio;

    CERTCConfiguration *config = [[CERTC(@"Configuration") alloc] init];
    config.iceServers = @[];
    config.sdpSemantics = CERTCSdpSemanticsUnifiedPlan;
    config.bundlePolicy = CERTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = CERTCRtcpMuxPolicyRequire;
    _pc = [factory peerConnectionWithConfiguration:config constraints:none delegate:self];
    if (!_pc) return nil;

    CERTCRtpTransceiverInit *sendRecv = [[CERTC(@"RtpTransceiverInit") alloc] init];
    sendRecv.direction = CERTCRtpTransceiverDirectionSendRecv;
    [_pc addTransceiverWithTrack:_audioTrack init:sendRecv];
    // watching a stream needs a video m-line from the start, it also gives op 1 the real video payload types
    if (receiveVideo) {
        CERTCRtpTransceiverInit *recvOnly = [[CERTC(@"RtpTransceiverInit") alloc] init];
        recvOnly.direction = CERTCRtpTransceiverDirectionRecvOnly;
        [_pc addTransceiverOfType:CERTCRtpMediaTypeVideo init:recvOnly];
    }
    // our own go live, fed with the frames the broadcast extension forwards
    if (sendScreen) {
        _screenSource = [factory videoSourceForScreenCast:YES];
        _screenTrack = [factory videoTrackWithSource:_screenSource trackId:[@"screen-" stringByAppendingString:sessionId]];
        CERTCRtpEncodingParameters *encoding = [[CERTC(@"RtpEncodingParameters") alloc] init];
        encoding.maxBitrateBps = @2500000;
        encoding.maxFramerate = @30;
        CERTCRtpTransceiverInit *sendOnly = [[CERTC(@"RtpTransceiverInit") alloc] init];
        sendOnly.direction = CERTCRtpTransceiverDirectionSendOnly;
        sendOnly.streamIds = @[ [@"screen-" stringByAppendingString:sessionId] ];
        sendOnly.sendEncodings = @[ encoding ];
        [_pc addTransceiverWithTrack:_screenTrack init:sendOnly];
        CEFramesSetSink(_screenSource);
    }
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

// bundled sections reuse the first transport, so a renegotiation never gathers again and shouldn't wait for it
- (void)renegotiate:(CEDone)done {
    // starts at 0, libdispatch traps when a semaphore is freed below its initial value
    dispatch_semaphore_t gathered = dispatch_semaphore_create(0);
    dispatch_semaphore_signal(gathered);
    self.gathered = gathered;
    [self offer:done];
}

- (void)addAudioReceiver:(CEDone)done {
    CERTCRtpTransceiverInit *recvOnly = [[CERTC(@"RtpTransceiverInit") alloc] init];
    recvOnly.direction = CERTCRtpTransceiverDirectionRecvOnly;
    [self.pc addTransceiverOfType:CERTCRtpMediaTypeAudio init:recvOnly];
    [self renegotiate:done];
}

- (void)addVideoReceiver:(CEDone)done {
    CERTCRtpTransceiverInit *recvOnly = [[CERTC(@"RtpTransceiverInit") alloc] init];
    recvOnly.direction = CERTCRtpTransceiverDirectionRecvOnly;
    [self.pc addTransceiverOfType:CERTCRtpMediaTypeVideo init:recvOnly];
    [self renegotiate:done];
}

- (void)stats:(CEDone)done {
    [self.pc statisticsWithCompletionHandler:^(CERTCStatisticsReport *report) {
        NSMutableArray *out = [NSMutableArray new];
        NSSet *wanted = [NSSet setWithArray:@[ @"inbound-rtp", @"outbound-rtp", @"remote-inbound-rtp", @"media-source", @"codec", @"transport", @"candidate-pair" ]];
        for (CERTCStatistics *stat in report.statistics.allValues) {
            if (![wanted containsObject:stat.type]) continue;
            NSMutableDictionary *values = [stat.values mutableCopy];
            values[@"type"] = stat.type;
            [out addObject:values];
        }
        done(out, nil);
    }];
}

- (BOOL)attachVideoMid:(NSString *)mid streamId:(NSString *)streamId {
    for (CERTCRtpTransceiver *transceiver in self.pc.transceivers) {
        if (![transceiver.mid isEqualToString:mid]) continue;
        CERTCMediaStreamTrack *track = transceiver.receiver.track;
        if (![track.kind isEqualToString:@"video"]) return NO;
        [self.streamIds addObject:streamId];
        CEVideoAttach(streamId, track);
        return YES;
    }
    return NO;
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
    if (self.screenSource) CEFramesClearSink(self.screenSource);
    for (NSString *streamId in self.streamIds) CEVideoDetach(streamId);
    [self.streamIds removeAllObjects];
    [self.pc close];
    self.pc = nil;
    self.audioTrack = nil;
    self.audioSource = nil;
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
    CEVoiceEmit(self.sessionId, @"ice", iceState(state));
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
    CEVoiceEmit(self.sessionId, @"connection", connectionState(state));
}
- (void)peerConnection:(id)pc didAddReceiver:(CERTCRtpReceiver *)receiver streams:(NSArray *)streams {
    [self applyPlayout];
    CEVoiceEmit(self.sessionId, @"track", receiver.track.kind ?: @"");
}

@end
