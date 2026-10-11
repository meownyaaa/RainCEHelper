#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#import "RangeLoader.h"
#import "Voice.h"

// spacebar signs cdn links for the requester's user agent, which is the agent Discord sets on its own requests.
// it's read off those requests, UIKit can't be touched this early to build it
static NSString *signedAgent;

static NSString *currentAgent(void) {
    @synchronized(NSURLSession.class) {
        return signedAgent;
    }
}

static void rememberAgent(NSString *agent) {
    @synchronized(NSURLSession.class) {
        signedAgent = agent;
    }
}

static BOOL isSigned(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSSet *names = [NSSet setWithArray:[components.queryItems valueForKey:@"name"]];
    return [names containsObject:@"hm"] && [names containsObject:@"ex"] && [names containsObject:@"is"];
}

typedef id (*InitWithURL)(id, SEL, NSURL *, NSDictionary *);
static InitWithURL originalInitWithURL;

// the player can't stream from spacebar's cdn (wrong agent, no Range support), so signed links go through our loader
static id initWithURL(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    BOOL take = url && !url.isFileURL && isSigned(url);
    CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"asset %@ %@", take ? @"ranged" : @"left", [url.absoluteString substringToIndex:MIN(url.absoluteString.length, (NSUInteger)120)]]);
    if (!take) return originalInitWithURL(self, _cmd, url, options);
    id asset = originalInitWithURL(self, _cmd, CERangeLoaderPrepare(url), options);
    if (asset) CERangeLoaderAttach(asset, ^{
        return currentAgent();
    });
    return asset;
}

typedef id (*TaskWithRequest)(id, SEL, NSURLRequest *);
typedef id (*TaskWithRequestHandler)(id, SEL, NSURLRequest *, id);
static TaskWithRequest originalTaskWithRequest;
static TaskWithRequestHandler originalTaskWithRequestHandler;
static NSUInteger loggedRequests;

// Discord's video loader (the ll-https scheme) fetches the real link itself, so the agent has to go on that request
static NSString *attachmentIdOf(NSURL *url) {
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger at = [parts indexOfObject:@"attachments"];
    return at != NSNotFound && parts.count > at + 2 ? parts[at + 2] : nil;
}

// Discord asks the cdn for a thumbnail of the video, a frame saved from the download answers it instead
static NSURLRequest *withThumbnail(NSURLRequest *request) {
    NSURL *url = request.URL;
    NSString *extension = url.pathExtension.lowercaseString;
    if (![@[ @"mp4", @"mov", @"m4v", @"webm" ] containsObject:extension]) return nil;
    // Discord tacks "?format=webp" onto a url that already has a query, so it isn't a separate parameter
    if (![url.absoluteString containsString:@"format="]) return nil;
    NSString *attachmentId = attachmentIdOf(url);
    NSString *path = attachmentId ? CEThumbnailPath(attachmentId) : nil;
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSMutableURLRequest *local = [request mutableCopy];
    local.URL = [NSURL fileURLWithPath:path];
    return local;
}

static NSURLRequest *withAppAgent(NSURLSession *session, NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url || url.isFileURL || !isSigned(url)) return request;
    NSURLRequest *thumbnail = withThumbnail(request);
    if (thumbnail) return thumbnail;
    NSString *current = [request valueForHTTPHeaderField:@"User-Agent"] ?: session.configuration.HTTPAdditionalHeaders[@"User-Agent"];
    if (loggedRequests++ < 12)
        CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"request %@ agent %@ range %@", [url.path lastPathComponent], current ?: @"(default)", [request valueForHTTPHeaderField:@"Range"] ?: @"-"]);
    // Discord's own loaders set the agent the links were signed for, only fill it in where it's missing
    if (current) {
        if ([current hasPrefix:@"Discord/"] && ![current containsString:@"CFNetwork"]) rememberAgent(current);
        return request;
    }
    NSString *agent = currentAgent();
    if (!agent) return request;
    NSMutableURLRequest *patched = [request mutableCopy];
    [patched setValue:agent forHTTPHeaderField:@"User-Agent"];
    return patched;
}

static id taskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    return originalTaskWithRequest(self, _cmd, withAppAgent(self, request));
}

static id taskWithRequestHandler(id self, SEL _cmd, NSURLRequest *request, id handler) {
    return originalTaskWithRequestHandler(self, _cmd, withAppAgent(self, request), handler);
}

void CEMediaPrefetch(NSString *raw, double size) {
    NSURL *url = [NSURL URLWithString:raw];
    NSString *attachmentId = url ? attachmentIdOf(url) : nil;
    // 15 MB keeps background downloads light
    if (!attachmentId || !isSigned(url) || size <= 0 || size > 15 * 1024 * 1024) return;
    if ([NSFileManager.defaultManager fileExistsAtPath:CEThumbnailPath(attachmentId)]) return;
    CERangeLoaderPrefetch(url, ^{
        return currentAgent();
    });
}

// loads a url the way the player would, to check what actually goes out
void CEMediaProbe(NSString *raw) {
    NSURL *url = [NSURL URLWithString:raw];
    if (!url) return;
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[ @"playable" ]
                         completionHandler:^{
                             NSError *error = nil;
                             AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
                             CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"probe status %ld playable %d error %@", (long)status, asset.playable, error.localizedDescription]);
                         }];
}

__attribute__((constructor)) static void installMediaHooks(void) {
    if (!NSClassFromString(@"DCDVoiceEngine")) return;
    Method method = class_getInstanceMethod(AVURLAsset.class, @selector(initWithURL:options:));
    if (method) originalInitWithURL = (InitWithURL)method_setImplementation(method, (IMP)initWithURL);
    CERangeLoaderInstall();
    // NSURLSession is a class cluster, hook the class sessions actually are
    Class session = object_getClass(NSURLSession.sharedSession);
    Method plain = class_getInstanceMethod(session, @selector(dataTaskWithRequest:));
    Method handler = class_getInstanceMethod(session, @selector(dataTaskWithRequest:completionHandler:));
    if (plain) originalTaskWithRequest = (TaskWithRequest)method_setImplementation(plain, (IMP)taskWithRequest);
    if (handler) originalTaskWithRequestHandler = (TaskWithRequestHandler)method_setImplementation(handler, (IMP)taskWithRequestHandler);
    CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"session class %@ plain %d handler %d", NSStringFromClass(session), !!plain, !!handler]);
}
