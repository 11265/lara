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
/// Returns true when the pill was attached and made visible.
bool clock_overlay_start(RemoteCall *proc);

/// Stops ticking and hides the overlay. The pill is hidden, not destroyed, so
/// starting it again is instant; a respring clears it for good.
/// Safe to call when the clock is not running.
void clock_overlay_stop(RemoteCall *proc);

/// True while the clock is ticking.
bool clock_overlay_is_running(void);

/// Human readable one-line state of the last start attempt (never NULL):
/// plan/scene/window/label/level/hidden/text/screen. Meant to be shown to the
/// user so a failed overlay can be diagnosed without a debugger.
const char *clock_overlay_status(void);

/// Drops the binding to the RemoteCall session (call it when lara destroys the
/// remote call, so a later start cannot use a destroyed session).
void clock_overlay_unbind(void);

#endif /* __OBJC__ */

#endif /* clock_overlay_h */
