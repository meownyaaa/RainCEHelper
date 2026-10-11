// the parts of WebRTC's ObjC SDK used here. Discord links it into its binary with a Discord prefix and stripped
// symbols, so classes are looked up by name at runtime and only declared, never linked
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CERTCSdpType) { CERTCSdpTypeOffer = 0, CERTCSdpTypePrAnswer = 1, CERTCSdpTypeAnswer = 2 };
typedef NS_ENUM(NSInteger, CERTCSdpSemantics) { CERTCSdpSemanticsPlanB = 0, CERTCSdpSemanticsUnifiedPlan = 1 };
typedef NS_ENUM(NSInteger, CERTCBundlePolicy) { CERTCBundlePolicyBalanced = 0, CERTCBundlePolicyMaxCompat = 1, CERTCBundlePolicyMaxBundle = 2 };
typedef NS_ENUM(NSInteger, CERTCRtcpMuxPolicy) { CERTCRtcpMuxPolicyNegotiate = 0, CERTCRtcpMuxPolicyRequire = 1 };
typedef NS_ENUM(NSInteger, CERTCRtpMediaType) { CERTCRtpMediaTypeAudio = 0, CERTCRtpMediaTypeVideo = 1 };
typedef NS_ENUM(NSInteger, CERTCRtpTransceiverDirection) {
    CERTCRtpTransceiverDirectionSendRecv = 0,
    CERTCRtpTransceiverDirectionSendOnly = 1,
    CERTCRtpTransceiverDirectionRecvOnly = 2,
    CERTCRtpTransceiverDirectionInactive = 3,
};
typedef NS_ENUM(NSInteger, CERTCIceGatheringState) { CERTCIceGatheringStateNew = 0, CERTCIceGatheringStateGathering = 1, CERTCIceGatheringStateComplete = 2 };

@interface CERTCSessionDescription : NSObject
@property(nonatomic, readonly) CERTCSdpType type;
@property(nonatomic, readonly) NSString *sdp;
- (instancetype)initWithType:(CERTCSdpType)type sdp:(NSString *)sdp;
@end

@interface CERTCMediaConstraints : NSObject
- (instancetype)initWithMandatoryConstraints:(NSDictionary<NSString *, NSString *> *)mandatory
                         optionalConstraints:(NSDictionary<NSString *, NSString *> *)optional;
@end

@interface CERTCConfiguration : NSObject
@property(nonatomic, copy) NSArray *iceServers;
@property(nonatomic, assign) CERTCSdpSemantics sdpSemantics;
@property(nonatomic, assign) CERTCBundlePolicy bundlePolicy;
@property(nonatomic, assign) CERTCRtcpMuxPolicy rtcpMuxPolicy;
@end

@interface CERTCMediaSource : NSObject
@end

@interface CERTCAudioSource : CERTCMediaSource
@property(nonatomic, assign) double volume;
@end

@interface CERTCMediaStreamTrack : NSObject
@property(nonatomic, readonly) NSString *kind;
@property(nonatomic, assign) BOOL isEnabled;
@end

@interface CERTCAudioTrack : CERTCMediaStreamTrack
@property(nonatomic, readonly) CERTCAudioSource *source;
@end

@interface CERTCVideoTrack : CERTCMediaStreamTrack
- (void)addRenderer:(id)renderer;
- (void)removeRenderer:(id)renderer;
@end

@interface CERTCRtpReceiver : NSObject
@property(nonatomic, readonly) CERTCMediaStreamTrack *track;
@end

@interface CERTCRtpTransceiverInit : NSObject
@property(nonatomic, assign) CERTCRtpTransceiverDirection direction;
@end

@interface CERTCRtpTransceiver : NSObject
@property(nonatomic, readonly) CERTCRtpReceiver *receiver;
@property(nonatomic, readonly) NSString *mid;
@end

@interface CERTCStatistics : NSObject
@property(nonatomic, readonly) NSString *type;
@property(nonatomic, readonly) NSDictionary<NSString *, NSObject *> *values;
@end

@interface CERTCStatisticsReport : NSObject
@property(nonatomic, readonly) NSDictionary<NSString *, CERTCStatistics *> *statistics;
@end

@interface CERTCPeerConnection : NSObject
@property(nonatomic, readonly) CERTCSessionDescription *localDescription;
- (void)statisticsWithCompletionHandler:(void (^)(CERTCStatisticsReport *report))completionHandler;
@property(nonatomic, readonly) NSArray<CERTCRtpReceiver *> *receivers;
@property(nonatomic, readonly) NSArray<CERTCRtpTransceiver *> *transceivers;
- (CERTCRtpTransceiver *)addTransceiverWithTrack:(CERTCMediaStreamTrack *)track init:(CERTCRtpTransceiverInit *)init;
- (CERTCRtpTransceiver *)addTransceiverOfType:(CERTCRtpMediaType)mediaType init:(CERTCRtpTransceiverInit *)init;
- (void)offerForConstraints:(CERTCMediaConstraints *)constraints
          completionHandler:(void (^)(CERTCSessionDescription *sdp, NSError *error))completionHandler;
- (void)setLocalDescription:(CERTCSessionDescription *)sdp completionHandler:(void (^)(NSError *error))completionHandler;
- (void)setRemoteDescription:(CERTCSessionDescription *)sdp completionHandler:(void (^)(NSError *error))completionHandler;
- (void)close;
@end

@interface CERTCPeerConnectionFactory : NSObject
- (CERTCAudioSource *)audioSourceWithConstraints:(CERTCMediaConstraints *)constraints;
- (CERTCAudioTrack *)audioTrackWithSource:(CERTCAudioSource *)source trackId:(NSString *)trackId;
- (CERTCPeerConnection *)peerConnectionWithConfiguration:(CERTCConfiguration *)configuration
                                             constraints:(CERTCMediaConstraints *)constraints
                                                delegate:(id)delegate;
@end

// Discord's names for the classes declared above
static inline Class CERTC(NSString *name) { return NSClassFromString([@"DiscordRTC" stringByAppendingString:name]); }
