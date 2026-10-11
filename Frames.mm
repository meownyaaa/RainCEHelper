#import "Frames.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>

#import <atomic>

#import "Broadcast.h"
#import "RTC.h"
#import "Voice.h"

struct CEFrameHeader {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t rotation;
};

static const uint32_t kFrameMagic = 0x43454652;
static const size_t kMaxSide = 1280;
static const size_t kMaxInputSide = 4096;
static const double kMinInterval = 1.0 / 30;

static NSString *framesPath(void) {
    NSString *dir = CESharedDir();
    return dir ? [dir stringByAppendingPathComponent:@"ce_frames.sock"] : nil;
}

static BOOL fillAddress(struct sockaddr_un *address, NSString *path) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    const char *raw = path.fileSystemRepresentation;
    if (strlen(raw) >= sizeof(address->sun_path)) return NO;
    strlcpy(address->sun_path, raw, sizeof(address->sun_path));
    return YES;
}

static BOOL writeAll(int fd, const uint8_t *bytes, size_t length) {
    while (length) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL readAll(int fd, uint8_t *bytes, size_t length) {
    while (length) {
        ssize_t got = read(fd, bytes, length);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        bytes += got;
        length -= (size_t)got;
    }
    return YES;
}

#pragma mark - extension: scale each screen frame down and send it

static dispatch_queue_t sendQueue;
static std::atomic<bool> sendBusy(false);
static int sendFd = -1;
static CFAbsoluteTime lastConnectAttempt, lastSent;
static VTPixelTransferSessionRef transfer;
static CVPixelBufferPoolRef sendPool;
static size_t poolWidth, poolHeight;

static void ensureConnected(void) {
    if (sendFd >= 0 || CFAbsoluteTimeGetCurrent() - lastConnectAttempt < 1) return;
    lastConnectAttempt = CFAbsoluteTimeGetCurrent();
    struct sockaddr_un address;
    NSString *path = framesPath();
    if (!path || !fillAddress(&address, path)) return;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return;
    }
    sendFd = fd;
}

// ReplayKit reports how the screen is turned, WebRTC carries it as frame rotation
static uint32_t rotationFor(CMSampleBufferRef sample) {
    NSNumber *orientation = (__bridge NSNumber *)CMGetAttachment(sample, CFSTR("RPVideoSampleOrientationKey"), NULL);
    switch (orientation.intValue) {
        case 3: return 180;
        case 6: return 270;
        case 8: return 90;
        default: return 0;
    }
}

static CVPixelBufferRef scaled(CVPixelBufferRef source) {
    size_t width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
    double scale = MIN(1.0, (double)kMaxSide / MAX(width, height));
    size_t targetWidth = ((size_t)(width * scale)) & ~1UL, targetHeight = ((size_t)(height * scale)) & ~1UL;
    if (!sendPool || poolWidth != targetWidth || poolHeight != targetHeight) {
        if (sendPool) CVPixelBufferPoolRelease(sendPool);
        sendPool = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (id)kCVPixelBufferWidthKey : @(targetWidth),
            (id)kCVPixelBufferHeightKey : @(targetHeight),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &sendPool) != kCVReturnSuccess) return NULL;
        poolWidth = targetWidth;
        poolHeight = targetHeight;
    }
    if (!transfer && VTPixelTransferSessionCreate(NULL, &transfer) != noErr) return NULL;
    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, sendPool, &out) != kCVReturnSuccess) return NULL;
    if (VTPixelTransferSessionTransferImage(transfer, source, out) != noErr) {
        CVPixelBufferRelease(out);
        return NULL;
    }
    return out;
}

static void sendFrame(CVPixelBufferRef source, uint32_t rotation) {
    ensureConnected();
    if (sendFd < 0) return;
    CVPixelBufferRef frame = scaled(source);
    if (!frame) return;
    CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame);
    NSMutableData *packet = [NSMutableData dataWithLength:sizeof(CEFrameHeader) + width * height * 3 / 2];
    uint8_t *bytes = (uint8_t *)packet.mutableBytes;
    CEFrameHeader header = {kFrameMagic, (uint32_t)width, (uint32_t)height, rotation};
    memcpy(bytes, &header, sizeof(header));
    uint8_t *cursor = bytes + sizeof(header);
    for (size_t plane = 0; plane < 2; plane++) {
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane);
        size_t rows = plane ? height / 2 : height;
        for (size_t row = 0; row < rows; row++, cursor += width) memcpy(cursor, base + row * stride, width);
    }
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(frame);
    if (!writeAll(sendFd, bytes, packet.length)) {
        close(sendFd);
        sendFd = -1;
    }
}

typedef void (*ProcessSample)(id, SEL, CMSampleBufferRef, NSInteger);
static ProcessSample originalProcessSample;

static void processSample(id self, SEL _cmd, CMSampleBufferRef sample, NSInteger type) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CVPixelBufferRef image = type == 1 ? CMSampleBufferGetImageBuffer(sample) : NULL;
    // drop frames while the previous one is still going out rather than queueing them
    if (image && now - lastSent >= kMinInterval && !sendBusy.exchange(true)) {
        lastSent = now;
        uint32_t rotation = rotationFor(sample);
        CVPixelBufferRetain(image);
        dispatch_async(sendQueue, ^{
            sendFrame(image, rotation);
            CVPixelBufferRelease(image);
            sendBusy = false;
        });
    }
    originalProcessSample(self, _cmd, sample, type);
}

#pragma mark - app: read frames and hand them to the go live video source

static id sink;
static CERTCVideoCapturer *capturer;
static CVPixelBufferPoolRef receivePool;
static size_t receiveWidth, receiveHeight;
static NSUInteger received;

void CEFramesSetSink(id videoSource) {
    @synchronized(CEVoiceSession.class) {
        sink = videoSource;
        capturer = [[CERTC(@"VideoCapturer") alloc] initWithDelegate:videoSource];
    }
}

void CEFramesClearSink(id videoSource) {
    @synchronized(CEVoiceSession.class) {
        if (sink != videoSource) return;
        sink = nil;
        capturer = nil;
    }
}

static CVPixelBufferRef receiveBuffer(size_t width, size_t height) {
    if (!receivePool || receiveWidth != width || receiveHeight != height) {
        if (receivePool) CVPixelBufferPoolRelease(receivePool);
        receivePool = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (id)kCVPixelBufferWidthKey : @(width),
            (id)kCVPixelBufferHeightKey : @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &receivePool) != kCVReturnSuccess) return NULL;
        receiveWidth = width;
        receiveHeight = height;
    }
    CVPixelBufferRef out = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, receivePool, &out);
    return out;
}

static void deliver(const uint8_t *planes, size_t width, size_t height, uint32_t rotation) {
    CVPixelBufferRef buffer = receiveBuffer(width, height);
    if (!buffer) return;
    CVPixelBufferLockBaseAddress(buffer, 0);
    const uint8_t *cursor = planes;
    for (size_t plane = 0; plane < 2; plane++) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        size_t rows = plane ? height / 2 : height;
        for (size_t row = 0; row < rows; row++, cursor += width) memcpy(base + row * stride, cursor, width);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    id target;
    CERTCVideoCapturer *from;
    @synchronized(CEVoiceSession.class) {
        target = sink;
        from = capturer;
    }
    if (target) {
        CERTCCVPixelBuffer *wrapped = [[CERTC(@"CVPixelBuffer") alloc] initWithPixelBuffer:buffer];
        int64_t timestamp = (int64_t)(CACurrentMediaTime() * NSEC_PER_SEC);
        CERTCVideoFrame *frame = [[CERTC(@"VideoFrame") alloc] initWithBuffer:wrapped rotation:rotation timeStampNs:timestamp];
        [(CERTCVideoSource *)target capturer:from didCaptureVideoFrame:frame];
    }
    CVPixelBufferRelease(buffer);
    if (received++ % 300 == 0)
        CEVoiceEmit(@"", @"frames", [NSString stringWithFormat:@"%lu %zux%zu rotation %u %@", (unsigned long)received, width, height, rotation, target ? @"sending" : @"no stream"]);
}

static void readClient(int fd) {
    NSMutableData *planes = [NSMutableData new];
    CEFrameHeader header;
    while (readAll(fd, (uint8_t *)&header, sizeof(header))) {
        if (header.magic != kFrameMagic || !header.width || !header.height || header.width > kMaxInputSide || header.height > kMaxInputSide ||
            header.width % 2 || header.height % 2)
            break;
        size_t length = (size_t)header.width * header.height * 3 / 2;
        planes.length = length;
        if (!readAll(fd, (uint8_t *)planes.mutableBytes, length)) break;
        @autoreleasepool {
            deliver((const uint8_t *)planes.bytes, header.width, header.height, header.rotation);
        }
    }
    close(fd);
    CEVoiceEmit(@"", @"frames", @"extension disconnected");
}

static void startServer(void) {
    NSString *path = framesPath();
    struct sockaddr_un address;
    if (!path || !fillAddress(&address, path)) return CEVoiceEmit(@"", @"frames", @"no shared container");
    unlink(path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 2) != 0) {
        CEVoiceEmit(@"", @"frames", [NSString stringWithFormat:@"server failed errno %d", errno]);
        if (fd >= 0) close(fd);
        return;
    }
    CEVoiceEmit(@"", @"frames", @"server listening");
    [NSThread detachNewThreadWithBlock:^{
        for (;;) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                break;
            }
            CEVoiceEmit(@"", @"frames", @"extension connected");
            [NSThread detachNewThreadWithBlock:^{
                readClient(client);
            }];
        }
    }];
}

void CEFramesInstall(void) {
    Class handler = NSClassFromString(@"DCDSampleHandler");
    Method method = handler ? class_getInstanceMethod(handler, @selector(processSampleBuffer:withType:)) : NULL;
    if (method) {
        sendQueue = dispatch_queue_create("changeendpoint.frames", DISPATCH_QUEUE_SERIAL);
        originalProcessSample = (ProcessSample)method_setImplementation(method, (IMP)processSample);
    } else if (NSClassFromString(@"DCDVoiceEngine")) {
        startServer();
    }
}
