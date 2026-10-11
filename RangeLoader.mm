#import "RangeLoader.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "Voice.h"

// spacebar's cdn ignores Range and always sends the whole file, which AVPlayer refuses to play from.
// one download per video goes to a temp file and the player's range requests are answered from it
@interface CERangeDownload : NSObject
@property(nonatomic, strong) NSURL *remote;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSFileHandle *writer;
@property(nonatomic, strong) NSFileHandle *reader;
@property(nonatomic, copy) NSString *contentType;
@property(nonatomic, assign) long long expected;
@property(nonatomic, assign) long long received;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) NSMutableArray<AVAssetResourceLoadingRequest *> *pending;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation CERangeDownload
@end

@interface CERangeLoader : NSObject <AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CERangeDownload *> *downloads;
@property(nonatomic, strong) NSMapTable<NSURLSessionTask *, CERangeDownload *> *byTask;
@property(nonatomic, copy) NSString * (^agent)(void);
@property(nonatomic, strong) NSMutableArray<NSURL *> *prefetchQueue;
@property(nonatomic, strong) CERangeDownload *prefetching;
@end

static const void *kOwnedLoader = &kOwnedLoader;

static NSMutableArray *measured;

NSArray *CEMediaSizesDrain(void) {
    @synchronized(CERangeDownload.class) {
        NSArray *out = measured ?: @[];
        measured = nil;
        return out;
    }
}

// spacebar doesn't send video sizes, so the finished download is measured for the js side to remember
NSString *CEThumbnailPath(NSString *attachmentId) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"changeendpoint-thumbs"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return [dir stringByAppendingPathComponent:[attachmentId stringByAppendingPathExtension:@"jpg"]];
}

// spacebar can't make video thumbnails, so a frame from the download stands in for Discord's preview
static void writeThumbnail(AVURLAsset *local, NSString *attachmentId) {
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:local];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(640, 640);
    NSError *error = nil;
    CGImageRef frame = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:&error];
    if (!frame) return;
    NSURL *target = [NSURL fileURLWithPath:CEThumbnailPath(attachmentId)];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)target, CFSTR("public.jpeg"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, frame, (__bridge CFDictionaryRef) @{(id)kCGImageDestinationLossyCompressionQuality : @0.8});
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(frame);
}

static void measure(CERangeDownload *download) {
    NSArray<NSString *> *parts = download.remote.pathComponents;
    NSUInteger at = [parts indexOfObject:@"attachments"];
    if (at == NSNotFound || parts.count < at + 3) return;
    NSString *channelId = parts[at + 1], *attachmentId = parts[at + 2];
    AVURLAsset *local = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:download.path] options:nil];
    [local loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                         completionHandler:^{
                             AVAssetTrack *track = [local tracksWithMediaType:AVMediaTypeVideo].firstObject;
                             if (!track) return;
                             CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
                             NSInteger width = (NSInteger)llround(fabs(size.width)), height = (NSInteger)llround(fabs(size.height));
                             if (!width || !height) return;
                             @synchronized(CERangeDownload.class) {
                                 if (!measured) measured = [NSMutableArray new];
                                 [measured addObject:@[ channelId, attachmentId, @(width), @(height) ]];
                             }
                             writeThumbnail(local, attachmentId);
                             CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"measured %@ %ldx%ld", attachmentId, (long)width, (long)height]);
                         }];
}

@implementation CERangeLoader

+ (instancetype)shared {
    static CERangeLoader *loader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loader = [CERangeLoader new];
        loader.queue = dispatch_queue_create("changeendpoint.range", DISPATCH_QUEUE_SERIAL);
        NSOperationQueue *callbacks = [NSOperationQueue new];
        callbacks.underlyingQueue = loader.queue;
        callbacks.maxConcurrentOperationCount = 1;
        loader.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:loader delegateQueue:callbacks];
        loader.downloads = [NSMutableDictionary new];
        loader.byTask = [NSMapTable weakToStrongObjectsMapTable];
    });
    return loader;
}

// ll-https://… (Discord's own loader scheme) or ce-https://… back to the real link
static NSURL *remoteURL(NSURL *url) {
    NSString *scheme = url.scheme;
    NSRange dash = [scheme rangeOfString:@"-"];
    if (dash.location == NSNotFound) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = [scheme substringFromIndex:dash.location + 1];
    return components.URL;
}

- (CERangeDownload *)downloadFor:(NSURL *)url {
    NSURL *remote = remoteURL(url);
    // the signature changes on refresh, the file doesn't
    NSString *key = remote.path;
    CERangeDownload *download = self.downloads[key];
    if (download && !download.error) return download;

    download = [CERangeDownload new];
    download.remote = remote;
    download.pending = [NSMutableArray new];
    download.path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ce-video-%lu-%@", (unsigned long)key.hash, remote.lastPathComponent]];
    [NSFileManager.defaultManager createFileAtPath:download.path contents:nil attributes:nil];
    download.writer = [NSFileHandle fileHandleForWritingAtPath:download.path];
    download.reader = [NSFileHandle fileHandleForReadingAtPath:download.path];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remote];
    NSString *agent = self.agent ? self.agent() : nil;
    if (agent) [request setValue:agent forHTTPHeaderField:@"User-Agent"];
    download.task = [self.session dataTaskWithRequest:request];
    [self.byTask setObject:download forKey:download.task];
    self.downloads[key] = download;
    [download.task resume];
    CEVoiceEmit(@"", @"media", [@"range download " stringByAppendingString:remote.lastPathComponent]);
    return download;
}

- (void)serve:(CERangeDownload *)download {
    for (AVAssetResourceLoadingRequest *request in [download.pending copy]) {
        if (request.isCancelled || request.isFinished) {
            [download.pending removeObject:request];
            continue;
        }
        if (download.error) {
            [request finishLoadingWithError:download.error];
            [download.pending removeObject:request];
            continue;
        }
        AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
        if (info && download.contentType) {
            info.contentType = [UTType typeWithMIMEType:download.contentType].identifier ?: @"public.mpeg-4";
            info.contentLength = download.expected;
            info.byteRangeAccessSupported = YES;
        }
        AVAssetResourceLoadingDataRequest *data = request.dataRequest;
        if (!data) {
            if (!info || download.contentType) {
                [request finishLoading];
                [download.pending removeObject:request];
            }
            continue;
        }
        long long total = download.expected > 0 ? download.expected : download.finished ? download.received : LLONG_MAX;
        long long end = data.requestsAllDataToEndOfResource ? total : MIN(total, data.requestedOffset + (long long)data.requestedLength);
        // once the download is done nothing else calls back, so hand over everything that's there now
        for (;;) {
            long long available = MIN(download.received, end) - data.currentOffset;
            if (available <= 0) break;
            [download.reader seekToFileOffset:data.currentOffset];
            NSData *chunk = [download.reader readDataOfLength:(NSUInteger)MIN(available, 1024 * 1024)];
            if (!chunk.length) break;
            [data respondWithData:chunk];
        }
        if (end != LLONG_MAX && data.currentOffset >= end) {
            [request finishLoading];
            [download.pending removeObject:request];
        }
    }
}

// one background download at a time, the phone shouldn't have to work through a whole channel at once
- (void)prefetch:(NSURL *)url {
    dispatch_async(self.queue, ^{
        if (self.downloads[url.path]) return;
        for (NSURL *queued in self.prefetchQueue)
            if ([queued.path isEqualToString:url.path]) return;
        if (!self.prefetchQueue) self.prefetchQueue = [NSMutableArray new];
        [self.prefetchQueue addObject:url];
        [self pump];
    });
}

- (void)pump {
    if (self.prefetching || !self.prefetchQueue.count) return;
    // the link only works with Discord's agent, which is learned from its first image request
    if (!(self.agent ? self.agent() : nil)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), self.queue, ^{
            [self pump];
        });
        return;
    }
    NSURL *next = self.prefetchQueue.firstObject;
    [self.prefetchQueue removeObjectAtIndex:0];
    if (self.downloads[next.path]) return [self pump];
    self.prefetching = [self downloadFor:next];
}

#pragma mark AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    CERangeDownload *download = [self downloadFor:loadingRequest.request.URL];
    [download.pending addObject:loadingRequest];
    [self serve:download];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    for (CERangeDownload *download in self.downloads.allValues) [download.pending removeObject:loadingRequest];
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    CERangeDownload *download = [self.byTask objectForKey:task];
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
    CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"range response %ld %@ %lld", (long)status, response.MIMEType, response.expectedContentLength]);
    if (status >= 400) {
        download.error = [NSError errorWithDomain:@"ChangeEndpoint" code:status userInfo:nil];
        [self serve:download];
        return completionHandler(NSURLSessionResponseCancel);
    }
    download.contentType = response.MIMEType ?: @"video/mp4";
    download.expected = response.expectedContentLength;
    [self serve:download];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    CERangeDownload *download = [self.byTask objectForKey:task];
    [download.writer seekToEndOfFile];
    [download.writer writeData:data];
    download.received += data.length;
    [self serve:download];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    CERangeDownload *download = [self.byTask objectForKey:task];
    download.finished = YES;
    if (error) download.error = error;
    if (download.expected <= 0) download.expected = download.received;
    CEVoiceEmit(@"", @"media", [NSString stringWithFormat:@"range done %lld bytes %@", download.received, error.localizedDescription ?: @""]);
    [self serve:download];
    if (!error) measure(download);
    if (download == self.prefetching) {
        self.prefetching = nil;
        [self pump];
    }
}

@end

typedef void (*SetDelegate)(id, SEL, id, dispatch_queue_t);
static SetDelegate originalSetDelegate;

// Discord sets its own loader after creating the asset, keep ours on the ones we took
static void setDelegate(AVAssetResourceLoader *self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (objc_getAssociatedObject(self, kOwnedLoader) && delegate != CERangeLoader.shared) return;
    originalSetDelegate(self, _cmd, delegate, queue);
}

NSURL *CERangeLoaderPrepare(NSURL *url) {
    // the player only asks a delegate for schemes it can't load itself
    if ([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        components.scheme = [@"ce-" stringByAppendingString:url.scheme];
        return components.URL;
    }
    return url;
}

void CERangeLoaderAttach(AVURLAsset *asset, NSString * (^agent)(void)) {
    CERangeLoader *loader = CERangeLoader.shared;
    loader.agent = agent;
    objc_setAssociatedObject(asset.resourceLoader, kOwnedLoader, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    originalSetDelegate(asset.resourceLoader, @selector(setDelegate:queue:), loader, loader.queue);
}

void CERangeLoaderPrefetch(NSURL *url, NSString * (^agent)(void)) {
    CERangeLoader *loader = CERangeLoader.shared;
    loader.agent = agent;
    [loader prefetch:url];
}

void CERangeLoaderInstall(void) {
    Method method = class_getInstanceMethod(AVAssetResourceLoader.class, @selector(setDelegate:queue:));
    if (method) originalSetDelegate = (SetDelegate)method_setImplementation(method, (IMP)setDelegate);
}
