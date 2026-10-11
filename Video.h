#import <Foundation/Foundation.h>

// remote video tracks are drawn by Discord's own DCDVideoRenderer views, matched by stream id
void CEVideoAttach(NSString *streamId, id track);
void CEVideoDetach(NSString *streamId);
void CEVideoInstallRendererHook(void);
