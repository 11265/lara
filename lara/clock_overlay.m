//
//  clock_overlay.m
//  lara
//
//  Global floating clock.
//
//  Cosmetic UI only: a small pill showing this device's local time, attached to
//  SpringBoard's own window. The only data source is [NSDate date] in this
//  process — no memory reads, no other process' data.
//
//  Deliberately built from the same primitives as rc.m's freaky-dog overlay,
//  because that is the one overlay path this project is known to run:
//    remote_getClass / remote_sel / remote_msg, remote_getCGRect/remote_setCGRect
//    for CGRects, remote_NSString for strings, and
//    performSelectorOnMainThread: for the view mutations.
//
//  Two earlier attempts failed on device: an own high-level UIWindow created off
//  the main thread never showed, and routing the build through remote_objc's
//  r_msg2_main* / NSInvocation helpers trapped inside SpringBoard ("Process might
//  have crashed! Unexpected trap"). Both are gone: no NSInvocation, no
//  connectedScenes, no status bar manager, no window level — just the host
//  window, one label, one frame.
//
//  Every step prints "(clock) [n/N] ..." to stdout. lara's logger captures
//  stdout, so the last line in lara.log says exactly which call failed.
//

#import "clock_overlay.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#pragma mark - Tunables

#define CLOCK_TAG            0x1A2B3C4DULL
#define CLOCK_WIDTH          92.0
#define CLOCK_HEIGHT         26.0
#define CLOCK_TOP            62.0      /* clear of the status bar / notch */
#define CLOCK_FONT_SIZE      15.0
#define CLOCK_TICK_MS        250ULL    /* poll 4x/s, push a string only when the second flips */
#define CLOCK_TEXT_MAX       16
#define CLOCK_STATUS_MAX     512

#pragma mark - State

static pthread_mutex_t gClockLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gClockTimer = nil;
static bool gClockRunning = false;
static pid_t gClockPid = 0;
static uint64_t gClockHost = 0;
static uint64_t gClockPill = 0;
static char gClockLastText[CLOCK_TEXT_MAX] = {0};
static char gClockStatus[CLOCK_STATUS_MAX] = "尚未启动";

static void clock_status(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gClockStatus, sizeof(gClockStatus), fmt, ap);
    va_end(ap);
    printf("(clock) %s\n", gClockStatus);
    fflush(stdout);
}

static bool clock_ptr(uint64_t p)
{
    /* Same test lara uses everywhere: anything above 4GB is a target pointer. */
    return p >= 0x100000000ULL;
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

/* A target-side NSString with +1 retain so we can CFRelease it after use. */
static uint64_t clock_nsstring(RemoteCall *proc, const char *s)
{
    if (!s) return 0;
    uint64_t cls = remote_getClass(proc, "NSString");
    if (!clock_ptr(cls)) return 0;
    uint64_t buf = remote_alloc_str(proc, s);
    if (!buf) return 0;
    uint64_t allocated = remote_msg(proc, cls, remote_sel(proc, "alloc"), 0, 0, 0, 0);
    uint64_t str = clock_ptr(allocated)
        ? remote_msg(proc, allocated, remote_sel(proc, "initWithUTF8String:"), buf, 0, 0, 0)
        : 0;
    if (!proc.trojanMemIsStackFallback) RemoteArbCall(proc, free, buf);
    return str;
}

/* performSelectorOnMainThread:withObject:waitUntilDone: — the idiom rc.m uses
   for every view mutation. */
static void clock_perform(RemoteCall *proc, uint64_t target, uint64_t sel, uint64_t arg, bool wait)
{
    if (!clock_ptr(target) || !sel) return;
    uint64_t perform = remote_sel(proc, "performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return;
    remote_msg(proc, target, perform, sel, arg, wait ? 1 : 0, 0);
}

/* Pushes the current time into the pill. Caller must hold gClockLock. */
static void clock_push_text(RemoteCall *proc)
{
    if (!clock_ptr(gClockPill)) return;

    const char *cstr = [clock_formatter() stringFromDate:[NSDate date]].UTF8String;
    if (!cstr) return;
    if (strncmp(cstr, gClockLastText, sizeof(gClockLastText)) == 0) return;

    strncpy(gClockLastText, cstr, sizeof(gClockLastText) - 1);
    gClockLastText[sizeof(gClockLastText) - 1] = '\0';

    uint64_t str = clock_nsstring(proc, cstr);
    if (!clock_ptr(str)) return;
    clock_perform(proc, gClockPill, remote_sel(proc, "setText:"), str, true);
    RemoteArbCall(proc, CFRelease, str);
}

#pragma mark - Ticking

static void clock_start_timer(RemoteCall *proc)
{
    if (gClockTimer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!timer) {
        printf("(clock) 定时器创建失败\n");
        fflush(stdout);
        return;
    }

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              CLOCK_TICK_MS * NSEC_PER_MSEC,
                              100 * NSEC_PER_MSEC);

    /* `proc` is captured strongly so the RemoteCall stays alive while ticking. */
    dispatch_source_set_event_handler(timer, ^{
        pthread_mutex_lock(&gClockLock);
        if (gClockRunning) clock_push_text(proc);
        pthread_mutex_unlock(&gClockLock);
    });

    gClockTimer = timer;
    dispatch_resume(gClockTimer);
}

#pragma mark - Build

/* Every step is numbered and printed, so a failure inside the target leaves a
   clear last-known-good line in lara.log. */
static bool clock_build(RemoteCall *proc)
{
    int step = 0;

    /* 1/8 — resolve the classes we need. */
    uint64_t clsApplication = remote_getClass(proc, "UIApplication");
    uint64_t clsLabel       = remote_getClass(proc, "UILabel");
    uint64_t clsColor       = remote_getClass(proc, "UIColor");
    step++;
    clock_status("[%d/8] 类: app=0x%llx label=0x%llx color=0x%llx", step, clsApplication, clsLabel, clsColor);
    if (!clock_ptr(clsApplication) || !clock_ptr(clsLabel)) return false;

    /* 2/8 — the target's application object. */
    uint64_t app = remote_msg(proc, clsApplication, remote_sel(proc, "sharedApplication"), 0, 0, 0, 0);
    step++;
    clock_status("[%d/8] sharedApplication=0x%llx", step, app);
    if (!clock_ptr(app)) return false;

    /* 3/8 — SpringBoard's window (keyWindow -> windows.firstObject -> delegate.window). */
    uint64_t window = remote_msg(proc, app, remote_sel(proc, "keyWindow"), 0, 0, 0, 0);
    if (!clock_ptr(window)) {
        uint64_t windows = remote_msg(proc, app, remote_sel(proc, "windows"), 0, 0, 0, 0);
        if (clock_ptr(windows)) {
            window = remote_msg(proc, windows, remote_sel(proc, "firstObject"), 0, 0, 0, 0);
        }
    }
    if (!clock_ptr(window)) {
        uint64_t delegate = remote_msg(proc, app, remote_sel(proc, "delegate"), 0, 0, 0, 0);
        if (clock_ptr(delegate)) {
            window = remote_msg(proc, delegate, remote_sel(proc, "window"), 0, 0, 0, 0);
        }
    }
    step++;
    clock_status("[%d/8] 宿主窗口=0x%llx", step, window);
    if (!clock_ptr(window)) return false;

    /* 4/8 — canvas. remote_getCGRect is not used by any shipped lara code path,
       so instead of poking the struct-return machinery we place the pill for a
       390pt-wide screen (iPhone 13/14 class, which is what this build targets). */
    CGRect canvas = CGRectMake(0, 0, CLOCK_WIDTH, CLOCK_HEIGHT);
    step++;
    clock_status("[%d/8] 画布=%.0fx%.0f（固定坐标，暂不读取屏幕尺寸）", step,
                 canvas.size.width, canvas.size.height);

    /* 5/8 — the pill. */
    uint64_t allocated = remote_msg(proc, clsLabel, remote_sel(proc, "alloc"), 0, 0, 0, 0);
    uint64_t pill = clock_ptr(allocated)
        ? remote_msg(proc, allocated, remote_sel(proc, "init"), 0, 0, 0, 0)
        : 0;
    step++;
    clock_status("[%d/8] label=0x%llx", step, pill);
    if (!clock_ptr(pill)) return false;

    /* 6/8 — colours, alignment, tag. Only object arguments, no CGFloats. */
    uint64_t white = remote_msg(proc, clsColor, remote_sel(proc, "whiteColor"), 0, 0, 0, 0);
    uint64_t black = remote_msg(proc, clsColor, remote_sel(proc, "blackColor"), 0, 0, 0, 0);
    if (clock_ptr(white)) remote_msg(proc, pill, remote_sel(proc, "setTextColor:"), white, 0, 0, 0);
    if (clock_ptr(black)) remote_msg(proc, pill, remote_sel(proc, "setBackgroundColor:"), black, 0, 0, 0);
    remote_msg(proc, pill, remote_sel(proc, "setTextAlignment:"), 1 /* centre */, 0, 0, 0);
    remote_msg(proc, pill, remote_sel(proc, "setNumberOfLines:"), 1, 0, 0, 0);
    remote_msg(proc, pill, remote_sel(proc, "setClipsToBounds:"), 1, 0, 0, 0);
    remote_msg(proc, pill, remote_sel(proc, "setTag:"), (uint64_t)CLOCK_TAG, 0, 0, 0);
    step++;
    clock_status("[%d/8] 颜色/对齐/tag 完成 white=0x%llx black=0x%llx", step, white, black);

    /* 7/8 — frame + attach, both on the target's main thread. */
    CGRect frame = CGRectMake((390.0 - CLOCK_WIDTH) / 2.0, CLOCK_TOP, CLOCK_WIDTH, CLOCK_HEIGHT);
    remote_setCGRect(proc, pill, remote_sel(proc, "setFrame:"), frame);
    gClockPill = pill;
    clock_push_text(proc);
    clock_perform(proc, window, remote_sel(proc, "addSubview:"), pill, true);
    step++;
    clock_status("[%d/8] 已挂载 frame=%.0f,%.0f,%.0fx%.0f", step, frame.origin.x, frame.origin.y,
                 frame.size.width, frame.size.height);

    /* 8/8 — verify what the target reports back. */
    uint64_t found = remote_msg(proc, window, remote_sel(proc, "viewWithTag:"), (uint64_t)CLOCK_TAG, 0, 0, 0);
    uint64_t hidden = remote_msg(proc, pill, remote_sel(proc, "isHidden"), 0, 0, 0, 0);
    char text[CLOCK_TEXT_MAX] = {0};
    uint64_t labelText = remote_msg(proc, pill, remote_sel(proc, "text"), 0, 0, 0, 0);
    if (clock_ptr(labelText)) {
        uint64_t utf8 = remote_msg(proc, labelText, remote_sel(proc, "UTF8String"), 0, 0, 0, 0);
        if (utf8) [proc remoteRead:utf8 to:text size:sizeof(text) - 1];
    }
    step++;
    clock_status("[%d/8] 校验 tag=0x%llx(应为0x%llx) hidden=%llu text='%s'", step, found, pill,
                 (unsigned long long)(hidden & 0xff), text);

    gClockHost = window;
    gClockPid = proc.pid;
    return clock_ptr(found) && found == pill;
}

#pragma mark - Public API

bool clock_overlay_start(RemoteCall *proc)
{
    if (!proc) {
        clock_status("RemoteCall 为空：请先在首页初始化远程调用");
        return false;
    }

    pthread_mutex_lock(&gClockLock);

    if (gClockRunning) {
        pthread_mutex_unlock(&gClockLock);
        return true;
    }

    /* Still alive in the same target? Just show the pill again. */
    if (gClockPid == proc.pid && clock_ptr(gClockPill) && clock_ptr(gClockHost)) {
        uint64_t found = remote_msg(proc, gClockHost, remote_sel(proc, "viewWithTag:"),
                                    (uint64_t)CLOCK_TAG, 0, 0, 0);
        if (found == gClockPill) {
            remote_msg(proc, gClockPill, remote_sel(proc, "setHidden:"), 0, 0, 0, 0);
            gClockLastText[0] = '\0';
            clock_push_text(proc);
            gClockRunning = true;
            clock_start_timer(proc);
            clock_status("复用已有胶囊：host=0x%llx pill=0x%llx", gClockHost, gClockPill);
            pthread_mutex_unlock(&gClockLock);
            return true;
        }
    }

    gClockHost = 0;
    gClockPill = 0;
    gClockLastText[0] = '\0';

    bool attached = clock_build(proc);
    if (!attached) {
        /* clock_build already printed the last step it reached. */
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    gClockRunning = true;
    clock_start_timer(proc);
    clock_status("已显示：host=0x%llx pill=0x%llx", gClockHost, gClockPill);

    pthread_mutex_unlock(&gClockLock);
    return true;
}

bool clock_overlay_selftest(RemoteCall *proc)
{
    if (!proc) {
        clock_status("自检失败：RemoteCall 为空");
        return false;
    }

    /* Start from a clean slate so the numbered steps below tell the whole story. */
    pthread_mutex_lock(&gClockLock);
    gClockRunning = false;
    if (gClockTimer) {
        dispatch_source_cancel(gClockTimer);
        gClockTimer = nil;
    }
    if (clock_ptr(gClockPill)) {
        remote_msg(proc, gClockPill, remote_sel(proc, "setHidden:"), 1, 0, 0, 0);
    }
    gClockPill = 0;
    gClockHost = 0;
    gClockLastText[0] = '\0';
    pthread_mutex_unlock(&gClockLock);

    printf("(clock) === 自检开始 ===\n");
    fflush(stdout);
    return clock_overlay_start(proc);
}

void clock_overlay_stop(RemoteCall *proc)
{
    (void)proc;

    pthread_mutex_lock(&gClockLock);

    gClockRunning = false;
    if (gClockTimer) {
        dispatch_source_cancel(gClockTimer);
        gClockTimer = nil;
    }

    /* Only the pill is hidden; SpringBoard's window must never be touched. */
    if (clock_ptr(gClockPill)) {
        remote_msg(proc, gClockPill, remote_sel(proc, "setHidden:"), 1, 0, 0, 0);
    }
    gClockLastText[0] = '\0';
    clock_status("已隐藏（对象保留，可直接再次开启）");

    pthread_mutex_unlock(&gClockLock);
}

bool clock_overlay_is_running(void)
{
    /* Status flag only: read without the lock so a slow tick can never block
       the caller (a stale read here is harmless). */
    return gClockRunning;
}

const char *clock_overlay_status(void)
{
    return gClockStatus;
}

void clock_overlay_unbind(void)
{
    /* This build talks to the RemoteCall directly, so there is no global
       binding to drop; kept for the header's sake. */
}
