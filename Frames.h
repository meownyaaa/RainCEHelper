#import <Foundation/Foundation.h>

// the broadcast extension sends screen frames to the app over a socket in the shared container
void CEFramesInstall(void);
void CEFramesSetSink(id videoSource);
void CEFramesClearSink(id videoSource);
