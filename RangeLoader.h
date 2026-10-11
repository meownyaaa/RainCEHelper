#import <AVFoundation/AVFoundation.h>

// serves video byte ranges from one full download, for servers that ignore Range
void CERangeLoaderInstall(void);
NSURL *CERangeLoaderPrepare(NSURL *url);
void CERangeLoaderAttach(AVURLAsset *asset, NSString * (^agent)(void));
