#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "RangeLoader.h"
#import "Video.h"

void CEMediaProbe(NSString *raw);
void CEMediaPrefetch(NSString *raw, double size);
#import "Voice.h"

typedef void (^Resolve)(id result);
typedef void (^Reject)(NSString *code, NSString *message, NSError *error);
typedef void (*ReadAsDataURL)(id, SEL, NSDictionary *, Resolve, Reject);

static ReadAsDataURL originalReadAsDataURL;
static NSMutableDictionary<NSString *, CEVoiceSession *> *sessions;
static double outputVolume = 1.0;

static NSNumber *number(NSArray *args, NSUInteger i) {
    return args.count > i && [args[i] isKindOfClass:NSNumber.class] ? args[i] : nil;
}

static NSString *string(NSArray *args, NSUInteger i) {
    return args.count > i && [args[i] isKindOfClass:NSString.class] ? args[i] : nil;
}


static NSArray *methodList(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *out = [NSMutableArray new];
    for (unsigned int i = 0; i < count; i++) {
        const char *types = method_getTypeEncoding(methods[i]);
        [out addObject:[NSString stringWithFormat:@"%@ %s", NSStringFromSelector(method_getName(methods[i])), types ?: ""]];
    }
    free(methods);
    return out;
}

// runtime class info for reverse engineering Discord's native code from js
static NSDictionary *describeClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return @{@"missing" : name};
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSMutableArray *ivarList = [NSMutableArray new];
    for (unsigned int i = 0; i < count; i++)
        [ivarList addObject:[NSString stringWithFormat:@"%s %s", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]) ?: ""]];
    free(ivars);
    return @{
        @"superclass" : NSStringFromClass(class_getSuperclass(cls)) ?: @"",
        @"instanceMethods" : methodList(cls),
        @"classMethods" : methodList(object_getClass(cls)),
        @"ivars" : ivarList,
    };
}


static NSArray *classesMatching(NSString *pattern) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *out = [NSMutableArray new];
    for (unsigned int i = 0; i < count && out.count < 300; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name rangeOfString:pattern options:NSCaseInsensitiveSearch].location != NSNotFound) [out addObject:name];
    }
    free(classes);
    return out;
}

static void handle(NSString *method, NSArray *args, CEDone done) {
    if (!sessions) sessions = [NSMutableDictionary new];
    if ([method isEqualToString:@"ping"])
        return done(@{@"pong" : @YES, @"rtc" : @([CEVoiceSession available])}, nil);
    if ([method isEqualToString:@"events"]) return done(CEVoiceDrainEvents(), nil);
    if ([method isEqualToString:@"debug.describe"]) return done(describeClass(string(args, 0) ?: @""), nil);
    if ([method isEqualToString:@"debug.classes"]) return done(classesMatching(string(args, 0) ?: @""), nil);
    if ([method isEqualToString:@"debug.asset"]) return CEMediaProbe(string(args, 0) ?: @""), done(nil, nil);
    if ([method isEqualToString:@"media.sizes"]) return done(CEMediaSizesDrain(), nil);
    if ([method isEqualToString:@"media.prefetch"]) return CEMediaPrefetch(string(args, 0) ?: @"", [number(args, 1) doubleValue]), done(nil, nil);
    if ([method isEqualToString:@"voice.setOutputVolume"]) {
        outputVolume = [number(args, 0) doubleValue] / 100.0;
        for (CEVoiceSession *session in sessions.allValues) [session setOutputVolume:outputVolume];
        return done(nil, nil);
    }

    // every voice method takes the session id first
    NSString *sessionId = string(args, 0);
    if (!sessionId) return done(nil, @"Missing session id");
    if ([method isEqualToString:@"voice.offer"]) {
        [sessions[sessionId] close];
        CEVoiceSession *session = [[CEVoiceSession alloc] initWithId:sessionId
                                                           sendAudio:[number(args, 1) ?: @YES boolValue]
                                                        receiveVideo:[number(args, 2) boolValue]
                                                          sendScreen:[number(args, 3) boolValue]];
        if (!session) return done(nil, @"Couldn't create a PeerConnection");
        sessions[sessionId] = session;
        [session setOutputVolume:outputVolume];
        return [session offer:done];
    }
    if ([method isEqualToString:@"voice.close"]) {
        [sessions[sessionId] close];
        [sessions removeObjectForKey:sessionId];
        return done(nil, nil);
    }

    CEVoiceSession *session = sessions[sessionId];
    if (!session) return done(nil, @"No voice session");
    if ([method isEqualToString:@"voice.addAudioReceiver"]) return [session addAudioReceiver:done];
    if ([method isEqualToString:@"voice.addVideoReceiver"]) return [session addVideoReceiver:done];
    if ([method isEqualToString:@"voice.renegotiate"]) return [session renegotiate:done];
    if ([method isEqualToString:@"voice.stats"]) return [session stats:done];
    if ([method isEqualToString:@"video.attach"]) {
        NSString *mid = string(args, 1), *streamId = string(args, 2);
        if (!mid || !streamId) return done(nil, @"Missing mid or stream id");
        return done(@([session attachVideoMid:mid streamId:streamId]), nil);
    }
    if ([method isEqualToString:@"voice.answer"]) {
        NSString *sdp = string(args, 1);
        if (!sdp) return done(nil, @"Missing sdp");
        return [session answer:sdp done:done];
    }
    if ([method isEqualToString:@"voice.setMuted"]) return [session setMuted:[number(args, 1) boolValue]], done(nil, nil);
    if ([method isEqualToString:@"voice.setDeafened"]) return [session setDeafened:[number(args, 1) boolValue]], done(nil, nil);

    done(nil, [NSString stringWithFormat:@"Unknown method %@", method]);
}

// js calls FileReaderModule.readAsDataURL({ changeEndpoint: { method, args } }), everything else goes to react native
static void readAsDataURL(id self, SEL _cmd, NSDictionary *blob, Resolve resolve, Reject reject) {
    NSDictionary *call = [blob isKindOfClass:NSDictionary.class] ? blob[@"changeEndpoint"] : nil;
    if (![call isKindOfClass:NSDictionary.class]) return originalReadAsDataURL(self, _cmd, blob, resolve, reject);

    NSString *method = [call[@"method"] isKindOfClass:NSString.class] ? call[@"method"] : @"";
    NSArray *args = [call[@"args"] isKindOfClass:NSArray.class] ? call[@"args"] : @[];
    // the session isn't thread safe, keep every call on the main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            handle(method, args, ^(id result, NSString *error) {
                resolve(error ? @{@"error" : error} : @{@"result" : result ?: NSNull.null});
            });
        } @catch (NSException *e) {
            resolve(@{@"error" : e.reason ?: e.name});
        }
    });
}

__attribute__((constructor)) static void install(void) {
    Class module = NSClassFromString(@"RCTFileReaderModule");
    Method method = module ? class_getInstanceMethod(module, @selector(readAsDataURL:resolve:reject:)) : NULL;
    if (!method) {
        NSLog(@"[ChangeEndpoint] RCTFileReaderModule readAsDataURL not found, bridge disabled");
        return;
    }
    originalReadAsDataURL = (ReadAsDataURL)method_setImplementation(method, (IMP)readAsDataURL);
    CEVideoInstallRendererHook();
    NSLog(@"[ChangeEndpoint] native bridge installed");
}
