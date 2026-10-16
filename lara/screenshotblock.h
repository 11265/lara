//
//  screenshotblock.h
//  lara
//
//  Device-wide capture block, applied from the running app through the
//  SpringBoard remote call: while it is active the device cannot take
//  screenshots and cannot start a screen recording.
//
//  Everything lives in SpringBoard's process; lara only drives it. The original
//  implementations are remembered, so the block can be lifted again without a
//  respring.
//

#ifndef screenshotblock_h
#define screenshotblock_h

#include <stdbool.h>

#ifdef __OBJC__

#import "TaskRop/RemoteCall.h"

/// Discovers the capture services inside SpringBoard and neutralises their
/// capture actions. Returns how many methods were neutralised (0 when nothing
/// matched — the log then lists every candidate it saw).
int sb_capture_block_apply(RemoteCall *proc);

/// Puts every neutralised method back the way it was.
void sb_capture_block_revert(RemoteCall *proc);

/// True while at least one method is neutralised.
bool sb_capture_block_active(void);

/// Human readable one-line state of the last apply/revert.
const char *sb_capture_block_status(void);

#endif /* __OBJC__ */

#endif /* screenshotblock_h */
