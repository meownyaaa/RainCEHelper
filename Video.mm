#import "Video.h"
#import "RTC.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// DCDVideoRenderer's own path, it also marks the view ready and reports the frame size to js
@interface CEVideoForwarder : NSObject
@property(nonatomic, weak) UIView *view;
@end

@implementation CEVideoForwarder
- (void)setSize:(CGSize)size {
}
- (void)renderFrame:(id)frame {
    UIView *view = self.view;
    if (!view || !frame) return;
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(view, @selector(renderFrame:withMirror:), frame, NO);
}
@end

static NSMutableDictionary<NSString *, CERTCVideoTrack *> *tracks;
static NSMapTable<UIView *, NSString *> *viewStreams;
static NSMapTable<UIView *, CEVideoForwarder *> *forwarders;

static void setup(void) {
    if (tracks) return;
    tracks = [NSMutableDictionary new];
    viewStreams = [NSMapTable weakToStrongObjectsMapTable];
    forwarders = [NSMapTable weakToStrongObjectsMapTable];
}

static void link(UIView *view, NSString *streamId) {
    setup();
    CEVideoForwarder *forwarder = [forwarders objectForKey:view];
    NSString *previous = [viewStreams objectForKey:view];
    if (forwarder && previous) [tracks[previous] removeRenderer:forwarder];
    if (!streamId.length) {
        [viewStreams removeObjectForKey:view];
        return;
    }
    [viewStreams setObject:streamId forKey:view];
    CERTCVideoTrack *track = tracks[streamId];
    if (!track) return;
    if (!forwarder) {
        forwarder = [CEVideoForwarder new];
        forwarder.view = view;
        [forwarders setObject:forwarder forKey:view];
    }
    [track addRenderer:forwarder];
}

static NSArray<UIView *> *viewsFor(NSString *streamId) {
    NSMutableArray *views = [NSMutableArray new];
    for (UIView *view in viewStreams.keyEnumerator)
        if ([[viewStreams objectForKey:view] isEqualToString:streamId]) [views addObject:view];
    return views;
}

void CEVideoAttach(NSString *streamId, id track) {
    setup();
    if (!streamId.length || !track) return;
    CEVideoDetach(streamId);
    tracks[streamId] = track;
    for (UIView *view in viewsFor(streamId)) link(view, streamId);
}

void CEVideoDetach(NSString *streamId) {
    setup();
    CERTCVideoTrack *track = tracks[streamId];
    if (!track) return;
    for (UIView *view in viewsFor(streamId)) {
        CEVideoForwarder *forwarder = [forwarders objectForKey:view];
        if (forwarder) [track removeRenderer:forwarder];
    }
    [tracks removeObjectForKey:streamId];
}

typedef void (*SetStreamId)(id, SEL, NSString *);
static SetStreamId originalSetStreamId;

static void setStreamId(id self, SEL _cmd, NSString *streamId) {
    originalSetStreamId(self, _cmd, streamId);
    link(self, [streamId isKindOfClass:NSString.class] ? streamId : nil);
}

void CEVideoInstallRendererHook(void) {
    Class renderer = NSClassFromString(@"DCDVideoRenderer");
    Method method = renderer ? class_getInstanceMethod(renderer, @selector(setStreamId:)) : NULL;
    if (!method) {
        NSLog(@"[ChangeEndpoint] DCDVideoRenderer setStreamId: not found, video disabled");
        return;
    }
    originalSetStreamId = (SetStreamId)method_setImplementation(method, (IMP)setStreamId);
}
