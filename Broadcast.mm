#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#import "Broadcast.h"
#import "Frames.h"
#import "Voice.h"

typedef struct __SecTask *SecTaskRef;
extern "C" SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern "C" CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static NSArray<NSString *> *entitledGroups(void) {
    static NSArray *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SecTaskRef task = SecTaskCreateFromSelf(NULL);
        if (!task) return;
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
        CFRelease(task);
        id list = CFBridgingRelease(value);
        if ([list isKindOfClass:NSArray.class]) groups = [list sortedArrayUsingSelector:@selector(compare:)];
    });
    return groups;
}

typedef NSURL *(*ContainerURL)(id, SEL, NSString *);
static ContainerURL originalContainerURL;

// re-signing renames the app groups, Discord still asks for its own so the app and the broadcast extension never meet
static NSURL *containerURL(id self, SEL _cmd, NSString *group) {
    NSURL *url = originalContainerURL(self, _cmd, group);
    NSArray *groups = entitledGroups();
    if (!url && group.length && groups.count && ![groups containsObject:group]) {
        // both processes carry the same groups, so they agree on the substitute
        url = originalContainerURL(self, _cmd, groups.firstObject);
        CEVoiceEmit(@"", @"container", [NSString stringWithFormat:@"%@ -> %@ %@", group, groups.firstObject, url.path]);
    } else {
        CEVoiceEmit(@"", @"container", [NSString stringWithFormat:@"%@ %@", group, url.path]);
    }
    return url;
}

__attribute__((constructor)) static void installContainerHook(void) {
    Method method = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (method) originalContainerURL = (ContainerURL)method_setImplementation(method, (IMP)containerURL);
}

// the extension can't reach the js bridge, so it also tries a file
static void note(NSString *line) {
    CEVoiceEmit(@"", @"broadcast", line);
    NSString *entry = [NSString stringWithFormat:@"%@ [%@] %@\n", NSDate.date, NSProcessInfo.processInfo.processName, line];
    for (NSString *dir in @[ @"/var/mobile/Documents/ChangeEndpoint", NSTemporaryDirectory() ]) {
        NSString *path = [dir stringByAppendingPathComponent:@"broadcast.log"];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file && [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]) file = [NSFileHandle fileHandleForWritingAtPath:path];
        [file seekToEndOfFile];
        [file writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    }
}

typedef id (*PathDelegate)(id, SEL, NSString *, id);
static PathDelegate originalServerWithPath, originalConnectToPath;
typedef void (*StartWithError)(id, SEL, NSError *__autoreleasing *);
static StartWithError originalStartWithError;

typedef char *(*GroupPathLookup)(const char *group, uint64_t *error);

// rain sends the app's group lookups to its own documents, the extension can't see those, so both sides use the real shared container
NSString *CESharedDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *group = entitledGroups().firstObject;
        GroupPathLookup lookup = (GroupPathLookup)dlsym(RTLD_DEFAULT, "container_create_or_lookup_app_group_path_by_app_group_identifier");
        if (!group || !lookup) return;
        uint64_t error = 0;
        char *found = lookup(group.UTF8String, &error);
        if (found) {
            dir = [NSString stringWithUTF8String:found];
            free(found);
        }
        note([NSString stringWithFormat:@"shared container %@ error %llu", dir, error]);
    });
    return dir;
}

static NSString *sharedSocketPath(NSString *path) {
    NSString *dir = CESharedDir();
    return dir ? [dir stringByAppendingPathComponent:path.lastPathComponent] : path;
}

static id serverWithPath(id self, SEL _cmd, NSString *path, id delegate) {
    NSString *shared = sharedSocketPath(path);
    note([NSString stringWithFormat:@"server %@ -> %@ delegate %@", path, shared, NSStringFromClass([delegate class])]);
    return originalServerWithPath(self, _cmd, shared, delegate);
}

static void startWithError(id self, SEL _cmd, NSError *__autoreleasing *error) {
    NSError *__autoreleasing local = nil;
    NSError *__autoreleasing *target = error ?: &local;
    originalStartWithError(self, _cmd, target);
    note([NSString stringWithFormat:@"server start %@", *target ?: @"ok"]);
}

static id connectToPath(id self, SEL _cmd, NSString *path, id delegate) {
    NSString *shared = sharedSocketPath(path);
    id connection = originalConnectToPath(self, _cmd, shared, delegate);
    note([NSString stringWithFormat:@"connect %@ -> %@ %@", path, shared, connection ? @"ok" : @"failed"]);
    return connection;
}

typedef void (*ReceivedMessage)(id, SEL, id, id, id);
static ReceivedMessage originalReceivedMessage;
static NSUInteger messageCount;

static NSString *describeMessage(id message) {
    if ([message isKindOfClass:NSData.class]) {
        NSData *data = message;
        NSMutableString *hex = [NSMutableString new];
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        for (NSUInteger i = 0; i < MIN(data.length, (NSUInteger)48); i++) [hex appendFormat:@"%02x", bytes[i]];
        return [NSString stringWithFormat:@"NSData %lu %@", (unsigned long)data.length, hex];
    }
    if ([message isKindOfClass:NSDictionary.class]) {
        NSMutableArray *parts = [NSMutableArray new];
        [(NSDictionary *)message enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSString *text = [value isKindOfClass:NSData.class] ? [NSString stringWithFormat:@"<data %lu>", (unsigned long)[(NSData *)value length]] : [[value description] substringToIndex:MIN([[value description] length], (NSUInteger)120)];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, text]];
        }];
        return [NSString stringWithFormat:@"%@ {%@}", NSStringFromClass([message class]), [parts componentsJoinedByString:@", "]];
    }
    NSString *text = [message description];
    return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([message class]), [text substringToIndex:MIN(text.length, (NSUInteger)300)]];
}

static void receivedMessage(id self, SEL _cmd, id server, id connection, id message) {
    if (messageCount++ < 40 || messageCount % 300 == 0) note([NSString stringWithFormat:@"message %lu %@", (unsigned long)messageCount, describeMessage(message)]);
    originalReceivedMessage(self, _cmd, server, connection, message);
}

static void hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (method) *original = method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void installBroadcastHooks(void) {
    note([NSString stringWithFormat:@"loaded in %@", NSBundle.mainBundle.bundleIdentifier]);
    Class server = NSClassFromString(@"DCDBroadcastSocketServer");
    Class connection = NSClassFromString(@"DCDBroadcastSocketConnection");
    hook(object_getClass(server), @selector(serverWithPath:delegate:), (IMP)serverWithPath, (IMP *)&originalServerWithPath);
    hook(server, @selector(startWithError:), (IMP)startWithError, (IMP *)&originalStartWithError);
    hook(object_getClass(connection), @selector(connectToPath:delegate:), (IMP)connectToPath, (IMP *)&originalConnectToPath);
    hook(NSClassFromString(@"DCDVoiceEngine"), @selector(broadcastSocketServer:connection:receivedMessage:), (IMP)receivedMessage, (IMP *)&originalReceivedMessage);
    CEFramesInstall();
}
