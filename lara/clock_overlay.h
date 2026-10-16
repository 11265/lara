//
//  clock_overlay.h
//  lara
//
//  A purely cosmetic global overlay: a floating pill that shows the device's
//  own local time, drawn by the target process (SpringBoard) so it floats
//  above everything. It is kept out of recordings (hidden while the screen is
//  captured) and out of screenshots (hosted in a secure text field, plus the
//  private capture switches where the window supports them). Screenshots can
//  additionally be blocked device-wide with clock_overlay_block_capture().
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

/// Tears the overlay down and rebuilds it from scratch, printing a numbered
/// line for every step into stdout (which lara's logger captures). Meant for
/// the "自检" button: if a step kills the remote call, the last line in the log
/// says exactly which one it was.
bool clock_overlay_selftest(RemoteCall *proc);

/// Stops ticking and hides the overlay. The pill is hidden, not destroyed, so
/// starting it again is instant; a respring clears it for good.
/// Safe to call when the clock is not running.
void clock_overlay_stop(RemoteCall *proc);

/// True while the clock is ticking.
bool clock_overlay_is_running(void);

/// Globally prevents screen capture on this device: screenshots, screen
/// recording and mirroring. Enumerates SpringBoard's capture service class(es),
/// prints every capture-shaped selector it finds (with the reason for leaving the
/// others alone) and replaces the void-returning capture actions with a
/// side-effect-free implementation. Returns how many were neutralised.
/// Idempotent; also called automatically once the clock is up.
int clock_overlay_block_capture(RemoteCall *proc);

/// Human readable one-line state of the last start attempt (never NULL).
const char *clock_overlay_status(void);

/// Drops the binding to the RemoteCall session (call it when lara destroys the
/// remote call, so a later start cannot use a destroyed session).
void clock_overlay_unbind(void);

#endif /* __OBJC__ */

#endif /* clock_overlay_h */
