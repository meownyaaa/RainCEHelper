#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "Voice.h"

typedef void (^Resolve)(id result);
typedef void (^Reject)(NSString *code, NSString *message, NSError *error);
typedef void (*ReadAsDataURL)(id, SEL, NSDictionary *, Resolve, Reject);

static ReadAsDataURL originalReadAsDataURL;
static CEVoiceSession *session;
static double outputVolume = 1.0;

static NSNumber *number(NSArray *args, NSUInteger i) {
    return args.count > i && [args[i] isKindOfClass:NSNumber.class] ? args[i] : nil;
}

static void handle(NSString *method, NSArray *args, CEDone done) {
    if ([method isEqualToString:@"ping"])
        return done(@{@"pong" : @YES, @"rtc" : @([CEVoiceSession available])}, nil);
    if ([method isEqualToString:@"events"]) return done(CEVoiceDrainEvents(), nil);

    if ([method isEqualToString:@"voice.offer"]) {
        [session close];
        session = [CEVoiceSession new];
        if (!session) return done(nil, @"Couldn't create a PeerConnection");
        [session setOutputVolume:outputVolume];
        return [session offer:done];
    }
    if ([method isEqualToString:@"voice.setOutputVolume"]) {
        outputVolume = [number(args, 0) doubleValue] / 100.0;
        [session setOutputVolume:outputVolume];
        return done(nil, nil);
    }
    if ([method isEqualToString:@"voice.close"]) {
        [session close];
        session = nil;
        return done(nil, nil);
    }

    if (!session) return done(nil, @"No voice session");
    if ([method isEqualToString:@"voice.addAudioReceiver"]) return [session addAudioReceiver:done];
    if ([method isEqualToString:@"voice.answer"]) {
        NSString *sdp = args.count && [args[0] isKindOfClass:NSString.class] ? args[0] : nil;
        if (!sdp) return done(nil, @"Missing sdp");
        return [session answer:sdp done:done];
    }
    if ([method isEqualToString:@"voice.setMuted"]) return [session setMuted:[number(args, 0) boolValue]], done(nil, nil);
    if ([method isEqualToString:@"voice.setDeafened"]) return [session setDeafened:[number(args, 0) boolValue]], done(nil, nil);

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
    NSLog(@"[ChangeEndpoint] native bridge installed");
}
