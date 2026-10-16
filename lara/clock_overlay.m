//
//  clock_overlay.m
//  lara
//
//  Global floating clock.
//
//  Everything here is cosmetic UI: a black pill with the host's local time,
//  hosted in a high-level UIWindow inside the target process (SpringBoard) so
//  it floats above apps. The only input is [NSDate date] from this process —
//  no kernel reads, no other process' data.
//
//  Remote-call conventions mirror rc.m / RemoteCall.m:
//   * object arguments travel as uint64_t through remote_msg();
//   * argument lists are serialized by gClockLock, because a RemoteCall
//     instance can only run one call at a time;
//   * CGFloats (window level, font size, corner radius, colours) cannot be
//     passed through the normal thread state, so they use the same
//     double-register spill trick as remote_setCGRect().
//

#import "clock_overlay.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>

#pragma mark - Tunables

#define CLOCK_TAG            0x1A2B3C4DULL
#define CLOCK_WINDOW_LEVEL   999999.0   /* above app windows and alerts */
#define CLOCK_WIDTH          96.0
#define CLOCK_HEIGHT         26.0
#define CLOCK_CORNER_RADIUS  8.0
#define CLOCK_FONT_SIZE      15.0
#define CLOCK_TOP_MARGIN     6.0
#define CLOCK_TOP_FALLBACK   44.0       /* used when statusBarFrame is unavailable */
#define CLOCK_TICK_MS        200ULL     /* poll 5x/s, push a string only when the second flips */
#define CLOCK_TEXT_MAX       16

#pragma mark - State

static pthread_mutex_t gClockLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gClockTimer = nil;
static bool gClockRunning = false;
static uint64_t gClockWindow = 0;
static uint64_t gClockLabel = 0;
static pid_t gClockPid = 0;
static char gClockLastText[CLOCK_TEXT_MAX] = {0};

#pragma mark - Double-argument calls

// Loads up to four doubles from the trojan scratch page into d0..d3 and then
// performs `sel` on `obj`. Same mechanism (and same assumption about
// -[CAMetalDrawable dirtyRect]) as remote_setCGRect() in RemoteCall.m.
static uint64_t clock_msg_doubles(RemoteCall *proc, uint64_t obj, uint64_t sel,
                                  const double *values, int count)
{
    if (!proc || !obj || !sel || !values || count <= 0 || count > 4) return 0;

    static bool warned = false;
    Class metal = NSClassFromString(@"CAMetalDrawable");
    Method m = metal ? class_getInstanceMethod(metal, @selector(dirtyRect)) : NULL;
    void *spillImp = m ? method_getImplementation(m) : NULL;
    if (!spillImp) {
        if (!warned) {
            warned = true;
            printf("(clock) double-register spill unavailable, CGFloat methods will be skipped\n");
            fflush(stdout);
        }
        return 0;
    }

    uint64_t where = proc.trojanMem;
    if (!where) return 0;

    // stp d0,d1,[x0,#0x20] / stp d2,d3,[x0,#0x30] in the spill IMP means the
    // doubles must land at `where` (16-byte aligned, as trojan memory is).
    if (![proc remote_write:where from:values size:(uint64_t)count * sizeof(double)]) return 0;
    RemoteArbCall(proc, spillImp, where - 0x20);
    return remote_msg(proc, obj, sel, 0, 0, 0, 0);
}

static uint64_t clock_msg_double(RemoteCall *proc, uint64_t obj, uint64_t sel, double value)
{
    return clock_msg_doubles(proc, obj, sel, &value, 1);
}

// Struct getters/setters also ride the trojan scratch page, so refuse them
// when the RemoteCall has no scratch page rather than computing a wild address.
static CGRect clock_get_rect(RemoteCall *proc, uint64_t obj, uint64_t sel)
{
    if (!proc || !obj || !sel || !proc.trojanMem) return CGRectZero;
    return remote_getCGRect(proc, obj, sel);
}

static void clock_set_rect(RemoteCall *proc, uint64_t obj, uint64_t sel, CGRect rect)
{
    if (!proc || !obj || !sel || !proc.trojanMem) return;
    remote_setCGRect(proc, obj, sel, rect);
}

#pragma mark - Small remote helpers

// A target-side NSString with a +1 retain, so the caller can CFRelease it once
// the target has consumed it. (remote_NSString() returns an autoreleased
// object, which has no pool to drain inside these calls.)
static uint64_t clock_nsstring(RemoteCall *proc, const char *s)
{
    if (!s) return 0;
    uint64_t cls = remote_getClass(proc, "NSString");
    if (!cls) return 0;

    uint64_t buf = remote_alloc_str(proc, s);
    if (!buf) return 0;

    uint64_t allocated = remote_msg(proc, cls, remote_sel(proc, "alloc"), 0, 0, 0, 0);
    uint64_t str = allocated
        ? remote_msg(proc, allocated, remote_sel(proc, "initWithUTF8String:"), buf, 0, 0, 0)
        : 0;

    if (!proc.trojanMemIsStackFallback) RemoteArbCall(proc, free, buf);
    return str;
}

// UI mutations go through the target's main thread, like rc.m's freakyperform().
static void clock_perform(RemoteCall *proc, uint64_t target, uint64_t sel, uint64_t arg, bool wait)
{
    if (!proc || !target || !sel) return;
    uint64_t perform = remote_sel(proc, "performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return;
    remote_msg(proc, target, perform, sel, arg, wait ? 1 : 0, 0);
}

static NSDateFormatter *clock_formatter(void)
{
    static NSDateFormatter *fmt = nil;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"HH:mm:ss";
    }
    return fmt;
}

// Pushes the current time into the label. Only touches the target when the
// second actually changed. Caller must hold gClockLock.
static void clock_push_text(RemoteCall *proc)
{
    if (!proc || !gClockWindow || !gClockLabel) return;

    NSString *now = [clock_formatter() stringFromDate:[NSDate date]];
    const char *cstr = now.UTF8String;
    if (!cstr) return;
    if (strncmp(cstr, gClockLastText, sizeof(gClockLastText)) == 0) return;

    strncpy(gClockLastText, cstr, sizeof(gClockLastText) - 1);
    gClockLastText[sizeof(gClockLastText) - 1] = '\0';

    uint64_t str = clock_nsstring(proc, cstr);
    if (!str) return;
    clock_perform(proc, gClockLabel, remote_sel(proc, "setText:"), str, true);
    RemoteArbCall(proc, CFRelease, str);
}

// The label we still remember, or 0 when the target no longer has it.
static uint64_t clock_live_label(RemoteCall *proc)
{
    if (!proc || !gClockWindow || !gClockLabel) return 0;
    uint64_t found = remote_msg(proc, gClockWindow, remote_sel(proc, "viewWithTag:"),
                                (uint64_t)CLOCK_TAG, 0, 0, 0);
    return (found == gClockLabel) ? found : 0;
}

#pragma mark - Ticking

static void clock_start_timer(RemoteCall *proc)
{
    if (gClockTimer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!timer) {
        printf("(clock) timer creation failed\n");
        fflush(stdout);
        return;
    }

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              CLOCK_TICK_MS * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);

    // `proc` is captured strongly so the RemoteCall stays alive while ticking.
    dispatch_source_set_event_handler(timer, ^{
        pthread_mutex_lock(&gClockLock);
        if (gClockRunning && gClockWindow && gClockLabel) clock_push_text(proc);
        pthread_mutex_unlock(&gClockLock);
    });

    gClockTimer = timer;
    dispatch_resume(gClockTimer);
}

#pragma mark - Public API

bool clock_overlay_start(RemoteCall *proc)
{
    if (!proc) return false;

    pthread_mutex_lock(&gClockLock);

    if (gClockRunning) {
        pthread_mutex_unlock(&gClockLock);
        return true;
    }

    // Still alive in the same target? Just show it again.
    if (gClockPid == proc.pid && clock_live_label(proc)) {
        remote_msg(proc, gClockWindow, remote_sel(proc, "setHidden:"), 0, 0, 0, 0);
        gClockLastText[0] = '\0';
        clock_push_text(proc);
        gClockRunning = true;
        clock_start_timer(proc);
        pthread_mutex_unlock(&gClockLock);
        printf("(clock) reusing existing overlay\n");
        fflush(stdout);
        return true;
    }
    gClockWindow = 0;
    gClockLabel = 0;
    gClockLastText[0] = '\0';

    uint64_t clsUIApplication = remote_getClass(proc, "UIApplication");
    uint64_t clsUIWindow      = remote_getClass(proc, "UIWindow");
    uint64_t clsUILabel       = remote_getClass(proc, "UILabel");
    uint64_t clsUIColor       = remote_getClass(proc, "UIColor");
    uint64_t clsUIFont        = remote_getClass(proc, "UIFont");
    uint64_t clsUIScreen      = remote_getClass(proc, "UIScreen");
    if (!clsUIApplication || !clsUIWindow || !clsUILabel || !clsUIColor || !clsUIFont) {
        pthread_mutex_unlock(&gClockLock);
        printf("(clock) UIKit classes unavailable in target\n");
        fflush(stdout);
        return false;
    }

    uint64_t app = remote_msg(proc, clsUIApplication, remote_sel(proc, "sharedApplication"), 0, 0, 0, 0);
    uint64_t scenes = app ? remote_msg(proc, app, remote_sel(proc, "connectedScenes"), 0, 0, 0, 0) : 0;
    uint64_t scene = scenes ? remote_msg(proc, scenes, remote_sel(proc, "anyObject"), 0, 0, 0, 0) : 0;
    if (!scene) {
        pthread_mutex_unlock(&gClockLock);
        printf("(clock) no window scene in target\n");
        fflush(stdout);
        return false;
    }

    uint64_t allocatedWindow = RemoteArbCall(proc, objc_alloc, clsUIWindow);
    uint64_t window = allocatedWindow
        ? remote_msg(proc, allocatedWindow, remote_sel(proc, "initWithWindowScene:"), scene, 0, 0, 0)
        : 0;
    if (!window) {
        pthread_mutex_unlock(&gClockLock);
        printf("(clock) window creation failed\n");
        fflush(stdout);
        return false;
    }

    // Screen geometry, and how far to stay clear of the status bar.
    CGRect screenRect = CGRectMake(0, 0, 390, 844);
    if (clsUIScreen) {
        uint64_t screen = remote_msg(proc, clsUIScreen, remote_sel(proc, "mainScreen"), 0, 0, 0, 0);
        if (screen) {
            CGRect bounds = clock_get_rect(proc, screen, remote_sel(proc, "bounds"));
            if (bounds.size.width > 1.0 && bounds.size.height > 1.0) screenRect = bounds;
        }
    }

    double top = CLOCK_TOP_FALLBACK;
    uint64_t statusBar = remote_msg(proc, scene, remote_sel(proc, "statusBarManager"), 0, 0, 0, 0);
    if (statusBar) {
        CGRect bar = clock_get_rect(proc, statusBar, remote_sel(proc, "statusBarFrame"));
        if (bar.size.height > 1.0 && bar.size.height < 200.0) top = bar.size.height;
    }

    clock_msg_double(proc, window, remote_sel(proc, "setWindowLevel:"), CLOCK_WINDOW_LEVEL);
    remote_msg(proc, window, remote_sel(proc, "setUserInteractionEnabled:"), 0, 0, 0, 0);
    remote_msg(proc, window, remote_sel(proc, "setOpaque:"), 0, 0, 0, 0);
    uint64_t clear = remote_msg(proc, clsUIColor, remote_sel(proc, "clearColor"), 0, 0, 0, 0);
    if (clear) remote_msg(proc, window, remote_sel(proc, "setBackgroundColor:"), clear, 0, 0, 0);
    clock_set_rect(proc, window, remote_sel(proc, "setFrame:"), screenRect);
    remote_msg(proc, window, remote_sel(proc, "setHidden:"), 1, 0, 0, 0);

    uint64_t allocatedLabel = RemoteArbCall(proc, objc_alloc, clsUILabel);
    uint64_t label = allocatedLabel ? remote_msg(proc, allocatedLabel, remote_sel(proc, "init"), 0, 0, 0, 0) : 0;
    if (!label) {
        pthread_mutex_unlock(&gClockLock);
        printf("(clock) label creation failed\n");
        fflush(stdout);
        return false;
    }

    remote_msg(proc, label, remote_sel(proc, "setTextAlignment:"), 1 /* centre */, 0, 0, 0);
    remote_msg(proc, label, remote_sel(proc, "setNumberOfLines:"), 1, 0, 0, 0);
    remote_msg(proc, label, remote_sel(proc, "setClipsToBounds:"), 1, 0, 0, 0);

    // Monospaced digits keep the fixed-width frame from jittering.
    double fontArgs[2] = { CLOCK_FONT_SIZE, 0.0 /* UIFontWeightRegular */ };
    uint64_t font = clock_msg_doubles(proc, clsUIFont,
                                      remote_sel(proc, "monospacedDigitSystemFontOfSize:weight:"),
                                      fontArgs, 2);
    if (!font) font = clock_msg_double(proc, clsUIFont, remote_sel(proc, "systemFontOfSize:"), CLOCK_FONT_SIZE);
    if (font) remote_msg(proc, label, remote_sel(proc, "setFont:"), font, 0, 0, 0);

    double pill[2] = { 0.0, 0.55 };
    uint64_t pillColor = clock_msg_doubles(proc, clsUIColor, remote_sel(proc, "colorWithWhite:alpha:"), pill, 2);
    if (pillColor) remote_msg(proc, label, remote_sel(proc, "setBackgroundColor:"), pillColor, 0, 0, 0);

    uint64_t textColor = remote_msg(proc, clsUIColor, remote_sel(proc, "whiteColor"), 0, 0, 0, 0);
    if (textColor) remote_msg(proc, label, remote_sel(proc, "setTextColor:"), textColor, 0, 0, 0);

    uint64_t layer = remote_msg(proc, label, remote_sel(proc, "layer"), 0, 0, 0, 0);
    if (layer) clock_msg_double(proc, layer, remote_sel(proc, "setCornerRadius:"), CLOCK_CORNER_RADIUS);

    CGRect labelFrame = CGRectMake((screenRect.size.width - CLOCK_WIDTH) / 2.0,
                                   top + CLOCK_TOP_MARGIN,
                                   CLOCK_WIDTH,
                                   CLOCK_HEIGHT);
    clock_set_rect(proc, label, remote_sel(proc, "setFrame:"), labelFrame);
    remote_msg(proc, label, remote_sel(proc, "setTag:"), (uint64_t)CLOCK_TAG, 0, 0, 0);

    clock_perform(proc, window, remote_sel(proc, "addSubview:"), label, true);
    remote_msg(proc, window, remote_sel(proc, "setHidden:"), 0, 0, 0, 0);

    gClockWindow = window;
    gClockLabel = label;
    gClockPid = proc.pid;
    gClockLastText[0] = '\0';
    clock_push_text(proc);
    gClockRunning = true;
    clock_start_timer(proc);

    pthread_mutex_unlock(&gClockLock);
    printf("(clock) overlay up (%.0fx%.0f, top=%.0f)\n",
           screenRect.size.width, screenRect.size.height, top);
    fflush(stdout);
    return true;
}

void clock_overlay_stop(RemoteCall *proc)
{
    pthread_mutex_lock(&gClockLock);

    gClockRunning = false;
    if (gClockTimer) {
        dispatch_source_cancel(gClockTimer);
        gClockTimer = nil;
    }

    // The pill stays as a hidden subview so a later start() is instant; the
    // handles are kept and re-validated by tag on the next start().
    if (proc && gClockWindow) {
        remote_msg(proc, gClockWindow, remote_sel(proc, "setHidden:"), 1, 0, 0, 0);
    }
    gClockLastText[0] = '\0';

    pthread_mutex_unlock(&gClockLock);
}

bool clock_overlay_is_running(void)
{
    // Status flag only: read without the lock so a slow tick can never block
    // the caller (a stale read here is harmless).
    return gClockRunning;
}
