//
//  clock_overlay.h
//  lara
//
//  A purely cosmetic global overlay: a floating pill that shows the device's
//  own local time, drawn by the target process (SpringBoard) so it floats
//  above everything.
//
//  Data source: nothing but the host process' NSDate. It never reads memory,
//  other processes, or any app's state.
//

#ifndef clock_overlay_h
#define clock_overlay_h

#include <stdbool.h>

#ifdef __OBJC__

#import "TaskRop/RemoteCall.h"

/// Creates (or re-shows) the floating clock in `proc` — expected to be a live
/// SpringBoard RemoteCall — and starts ticking it once per second.
/// Returns true when the overlay is up and ticking.
bool clock_overlay_start(RemoteCall *proc);

/// Stops ticking and hides the overlay. The pill is hidden, not destroyed, so
/// starting it again is instant; a respring clears it for good.
/// Safe to call when the clock is not running.
void clock_overlay_stop(RemoteCall *proc);

/// True while the clock is ticking.
bool clock_overlay_is_running(void);

#endif /* __OBJC__ */

#endif /* clock_overlay_h */
