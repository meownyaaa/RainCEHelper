#import <AVFoundation/AVFoundation.h>

// serves video byte ranges from one full download, for servers that ignore Range
void CERangeLoaderInstall(void);
NSURL *CERangeLoaderPrepare(NSURL *url);
void CERangeLoaderAttach(AVURLAsset *asset, NSString * (^agent)(void));
// [channel id, attachment id, width, height] for videos measured since the last call
NSArray *CEMediaSizesDrain(void);
// downloads a video in the background so it gets measured and a preview frame
void CERangeLoaderPrefetch(NSURL *url, NSString * (^agent)(void));
NSString *CEThumbnailPath(NSString *attachmentId);
