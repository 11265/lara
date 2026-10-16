//
//  clock_overlay.m
//  lara
//
//  Global floating clock.
//
//  Cosmetic UI only: translucent black pills showing this device's local time,
//  hosted inside the target process (SpringBoard). The only data source is
//  [NSDate date] in this process — no memory reads, no other process' data.
//
//  Why the r_* helpers instead of raw remote_msg:
//   * remote_objc's r_msg2_main* family builds an NSInvocation and runs it with
//     -performSelectorOnMainThread:withObject:waitUntilDone:, so every UIKit call
//     happens on the target's main thread (a UIWindow created off the main thread
//     silently never shows);
//   * arguments are set with -setArgument:atIndex:, so CGFloats and CGRects are
//     passed correctly instead of being guessed from registers.
//  Those helpers talk to a global RemoteCall, so start() binds lara's session
//  into them through arc_use_existing_remote_call().
//
//  Two hosts are tried, because "attached" is not the same as "actually on
//  screen": our own high-level window on the foreground scene (floats above
//  apps) and SpringBoard's own window (the same host rc.m's freaky-dog overlay
//  uses, visible whenever SpringBoard is). Either one showing is a success, and
//  clock_overlay_status() reports what each host verified.
//
//  stop() only hides the pills. It never touches a host window — hiding
//  SpringBoard's own window would blank the whole UI.
//

#import "clock_overlay.h"
#import "remote_objc.h"
#import "ARCCompat.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdarg.h>
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
#define CLOCK_STATUS_MAX     640
#define CLOCK_MAX_HOSTS      2

#define CLOCK_HOST_OWN       1          /* our own high-level UIWindow */
#define CLOCK_HOST_SB        2          /* SpringBoard's own window */

#pragma mark - State

static pthread_mutex_t gClockLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gClockTimer = nil;
static bool gClockRunning = false;
static pid_t gClockPid = 0;

static uint64_t gClockHost[CLOCK_MAX_HOSTS] = {0};
static uint64_t gClockPill[CLOCK_MAX_HOSTS] = {0};
static int      gClockHostKind[CLOCK_MAX_HOSTS] = {0};
static int      gClockHostCount = 0;

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
    return r_is_objc_ptr(p);
}

/* Appends to a status buffer without ever letting the offset run past the end
   (snprintf returns the untruncated length, which would underflow a naive
   `sizeof(buf) - used`). */
static void clock_append(char *buf, size_t cap, int *used, const char *fmt, ...)
{
    if (!buf || cap == 0 || !used || *used < 0 || (size_t)*used >= cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *used, cap - (size_t)*used, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    *used += n;
    if ((size_t)*used >= cap) *used = (int)cap - 1;
}

static void clock_hosts_reset(void)
{
    for (int i = 0; i < CLOCK_MAX_HOSTS; i++) {
        gClockHost[i] = 0;
        gClockPill[i] = 0;
        gClockHostKind[i] = 0;
    }
    gClockHostCount = 0;
}

#pragma mark - Target-side lookups

/* The foreground-active scene, falling back to the first scene we can see. */
static uint64_t clock_pick_scene(uint64_t app)
{
    if (!clock_ptr(app)) return 0;

    uint64_t scenes = r_msg2(app, "connectedScenes", 0, 0, 0, 0);
    if (!clock_ptr(scenes)) return 0;

    uint64_t any = r_msg2(scenes, "anyObject", 0, 0, 0, 0);
    uint64_t array = r_msg2(scenes, "allObjects", 0, 0, 0, 0);
    if (!clock_ptr(array)) return any;

    uint64_t count = r_msg2(array, "count", 0, 0, 0, 0);
    if (count == 0) return any;
    if (count > 16) count = 16;

    uint64_t first = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t scene = r_msg2(array, "objectAtIndex:", i, 0, 0, 0);
        if (!clock_ptr(scene)) continue;
        if (!first) first = scene;
        /* UISceneActivationStateForegroundActive == 0 */
        uint64_t state = r_msg2(scene, "activationState", 0, 0, 0, 0);
        if ((state & 0xffffffffULL) == 0) return scene;
    }
    return first ? first : any;
}

/* SpringBoard's own window: keyWindow -> windows.firstObject -> delegate.window. */
static uint64_t clock_fallback_window(uint64_t app)
{
    if (!clock_ptr(app)) return 0;

    uint64_t window = r_msg2(app, "keyWindow", 0, 0, 0, 0);
    if (clock_ptr(window)) return window;

    uint64_t windows = r_msg2(app, "windows", 0, 0, 0, 0);
    if (clock_ptr(windows)) {
        window = r_msg2(windows, "firstObject", 0, 0, 0, 0);
        if (clock_ptr(window)) return window;
    }

    uint64_t delegate = r_msg2(app, "delegate", 0, 0, 0, 0);
    if (clock_ptr(delegate)) {
        window = r_msg2(delegate, "window", 0, 0, 0, 0);
        if (clock_ptr(window)) return window;
    }
    return 0;
}

static CGRect clock_screen_bounds(uint64_t clsUIScreen)
{
    CGRect result = CGRectMake(0, 0, 390, 844);
    uint64_t screen = clock_ptr(clsUIScreen) ? r_msg2(clsUIScreen, "mainScreen", 0, 0, 0, 0) : 0;
    if (!clock_ptr(screen)) return result;

    CGRect bounds;
    memset(&bounds, 0, sizeof(bounds));
    if (r_msg2_main_struct_ret(screen, "bounds", &bounds, sizeof(bounds),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
        if (bounds.size.width > 1.0 && bounds.size.height > 1.0) result = bounds;
    }
    return result;
}

static double clock_top_inset(uint64_t scene)
{
    double top = CLOCK_TOP_FALLBACK;
    if (!clock_ptr(scene)) return top;

    uint64_t manager = r_msg2(scene, "statusBarManager", 0, 0, 0, 0);
    if (!clock_ptr(manager)) return top;

    CGRect bar;
    memset(&bar, 0, sizeof(bar));
    if (r_msg2_main_struct_ret(manager, "statusBarFrame", &bar, sizeof(bar),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
        if (bar.size.height > 1.0 && bar.size.height < 200.0) top = bar.size.height;
    }
    return top;
}

#pragma mark - The pill

static uint64_t clock_build_pill(uint64_t clsUILabel, uint64_t clsUIColor, uint64_t clsUIFont, CGRect frame)
{
    uint64_t allocated = r_msg2(clsUILabel, "alloc", 0, 0, 0, 0);
    if (!clock_ptr(allocated)) return 0;

    uint64_t label = r_msg2_main(allocated, "init", 0, 0, 0, 0);
    if (!clock_ptr(label)) return 0;

    /* Monospaced digits keep the fixed-width frame from jittering. */
    double size = CLOCK_FONT_SIZE;
    double weight = 0.0;   /* UIFontWeightRegular */
    uint64_t font = r_msg2_main_raw(clsUIFont, "monospacedDigitSystemFontOfSize:weight:",
                                    &size, sizeof(size), &weight, sizeof(weight), NULL, 0, NULL, 0);
    if (!clock_ptr(font)) {
        font = r_msg2_main_raw(clsUIFont, "systemFontOfSize:", &size, sizeof(size),
                               NULL, 0, NULL, 0, NULL, 0);
    }
    if (clock_ptr(font)) r_msg2_main(label, "setFont:", font, 0, 0, 0);

    r_msg2_main(label, "setTextAlignment:", 1 /* centre */, 0, 0, 0);
    r_msg2_main(label, "setNumberOfLines:", 1, 0, 0, 0);
    r_msg2_main(label, "setClipsToBounds:", 1, 0, 0, 0);

    double white = 0.0;
    double alpha = 0.55;
    uint64_t pill = r_msg2_main_raw(clsUIColor, "colorWithWhite:alpha:",
                                    &white, sizeof(white), &alpha, sizeof(alpha), NULL, 0, NULL, 0);
    if (clock_ptr(pill)) r_msg2_main(label, "setBackgroundColor:", pill, 0, 0, 0);

    uint64_t textColor = r_msg2(clsUIColor, "whiteColor", 0, 0, 0, 0);
    if (clock_ptr(textColor)) r_msg2_main(label, "setTextColor:", textColor, 0, 0, 0);

    double radius = CLOCK_CORNER_RADIUS;
    uint64_t layer = r_msg2(label, "layer", 0, 0, 0, 0);
    if (clock_ptr(layer)) {
        r_msg2_main_raw(layer, "setCornerRadius:", &radius, sizeof(radius), NULL, 0, NULL, 0, NULL, 0);
    }

    r_msg2_main_raw(label, "setFrame:", &frame, sizeof(frame), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(label, "setTag:", (uint64_t)CLOCK_TAG, 0, 0, 0);
    return label;
}

/* What we can prove from the target's side; `level` only means something for our
   own window, SpringBoard's window keeps whatever level it has. */
static void clock_verify(uint64_t host, uint64_t pill,
                         bool *attached, bool *visible, bool *levelOK, double *level,
                         char *textOut, size_t textLen)
{
    if (attached) *attached = false;
    if (visible) *visible = false;
    if (levelOK) *levelOK = false;
    if (level) *level = 0.0;
    if (textOut && textLen) textOut[0] = '\0';
    if (!clock_ptr(host)) return;

    uint64_t found = r_msg2(host, "viewWithTag:", (uint64_t)CLOCK_TAG, 0, 0, 0);
    if (attached) *attached = (clock_ptr(found) && found == pill);

    uint64_t hidden = r_msg2(pill, "isHidden", 0, 0, 0, 0);
    if (visible) *visible = ((hidden & 0xff) == 0);

    double value = 0.0;
    bool ok = r_msg2_main_struct_ret(host, "windowLevel", &value, sizeof(value),
                                     NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    if (levelOK) *levelOK = ok;
    if (level) *level = value;

    if (textOut && textLen && clock_ptr(pill)) {
        uint64_t text = r_msg2(pill, "text", 0, 0, 0, 0);
        if (clock_ptr(text)) r_read_nsstring(text, textOut, textLen);
    }
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

/* Pushes the current time into every pill. Only touches the target when the
   second actually changed. Caller must hold gClockLock. */
static void clock_push_text(void)
{
    if (gClockHostCount == 0) return;

    NSString *now = [clock_formatter() stringFromDate:[NSDate date]];
    const char *cstr = now.UTF8String;
    if (!cstr) return;
    if (strncmp(cstr, gClockLastText, sizeof(gClockLastText)) == 0) return;

    strncpy(gClockLastText, cstr, sizeof(gClockLastText) - 1);
    gClockLastText[sizeof(gClockLastText) - 1] = '\0';

    uint64_t str = r_nsstr_retained(cstr);   /* +1 in the target */
    if (!clock_ptr(str)) return;

    for (int i = 0; i < gClockHostCount; i++) {
        if (clock_ptr(gClockPill[i])) {
            r_perform_main(gClockPill[i], r_sel("setText:"), str, true);
        }
    }
    r_dlsym_call(R_TIMEOUT, "CFRelease", str, 0, 0, 0, 0, 0, 0, 0);
}

#pragma mark - Ticking

static void clock_start_timer(RemoteCall *proc)
{
    if (gClockTimer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!timer) {
        clock_status("定时器创建失败");
        return;
    }

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              CLOCK_TICK_MS * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);

    /* `proc` is captured strongly so the RemoteCall stays alive while ticking. */
    dispatch_source_set_event_handler(timer, ^{
        pthread_mutex_lock(&gClockLock);
        if (gClockRunning) clock_push_text();
        pthread_mutex_unlock(&gClockLock);
    });

    gClockTimer = timer;
    dispatch_resume(gClockTimer);
}

#pragma mark - Public API

bool clock_overlay_start(RemoteCall *proc)
{
    if (!proc) {
        clock_status("RemoteCall 为空：请先在主页初始化远程调用");
        return false;
    }

    pthread_mutex_lock(&gClockLock);

    if (gClockRunning) {
        pthread_mutex_unlock(&gClockLock);
        return true;
    }

    /* Point remote_objc's global helpers at lara's live SpringBoard session. */
    arc_use_existing_remote_call((__bridge void *)proc);
    r_settle_us(1500);

    /* Still alive in the same target? Just show the pills again. */
    if (gClockPid == proc.pid && gClockHostCount > 0 && clock_ptr(gClockPill[0])) {
        for (int i = 0; i < gClockHostCount; i++) {
            if (clock_ptr(gClockPill[i])) r_msg2_main(gClockPill[i], "setHidden:", 0, 0, 0, 0);
        }
        gClockLastText[0] = '\0';
        clock_push_text();
        gClockRunning = true;
        clock_start_timer(proc);
        clock_status("复用已有悬浮窗：hosts=%d pill0=0x%llx", gClockHostCount, gClockPill[0]);
        pthread_mutex_unlock(&gClockLock);
        return true;
    }

    clock_hosts_reset();
    gClockLastText[0] = '\0';

    uint64_t clsUIApplication = r_class("UIApplication");
    uint64_t clsUIWindow      = r_class("UIWindow");
    uint64_t clsUILabel       = r_class("UILabel");
    uint64_t clsUIColor       = r_class("UIColor");
    uint64_t clsUIFont        = r_class("UIFont");
    uint64_t clsUIScreen      = r_class("UIScreen");
    if (!clock_ptr(clsUIApplication) || !clock_ptr(clsUIWindow) ||
        !clock_ptr(clsUILabel) || !clock_ptr(clsUIColor) || !clock_ptr(clsUIFont)) {
        clock_status("目标进程缺少 UIKit 类：app=0x%llx win=0x%llx label=0x%llx color=0x%llx font=0x%llx",
                     clsUIApplication, clsUIWindow, clsUILabel, clsUIColor, clsUIFont);
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    uint64_t app = r_msg2(clsUIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!clock_ptr(app)) {
        clock_status("sharedApplication 取不到：app=0x%llx", app);
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    uint64_t scene = clock_pick_scene(app);
    uint64_t sceneState = clock_ptr(scene) ? r_msg2(scene, "activationState", 0, 0, 0, 0) : 0xffffULL;

    CGRect screen = clock_screen_bounds(clsUIScreen);
    double top = clock_top_inset(scene);
    CGRect frame = CGRectMake((screen.size.width - CLOCK_WIDTH) / 2.0,
                              top + CLOCK_TOP_MARGIN,
                              CLOCK_WIDTH,
                              CLOCK_HEIGHT);

    /* Host 1: our own high-level window on the foreground scene. */
    uint64_t ownWindow = 0;
    if (clock_ptr(scene)) {
        uint64_t allocated = r_msg2(clsUIWindow, "alloc", 0, 0, 0, 0);
        if (clock_ptr(allocated)) {
            ownWindow = r_msg2_main(allocated, "initWithWindowScene:", scene, 0, 0, 0);
        }
        if (clock_ptr(ownWindow)) {
            double windowLevel = CLOCK_WINDOW_LEVEL;
            r_msg2_main_raw(ownWindow, "setWindowLevel:", &windowLevel, sizeof(windowLevel),
                            NULL, 0, NULL, 0, NULL, 0);
            r_msg2_main(ownWindow, "setUserInteractionEnabled:", 0, 0, 0, 0);
            r_msg2_main(ownWindow, "setOpaque:", 0, 0, 0, 0);
            uint64_t clear = r_msg2(clsUIColor, "clearColor", 0, 0, 0, 0);
            if (clock_ptr(clear)) r_msg2_main(ownWindow, "setBackgroundColor:", clear, 0, 0, 0);
            r_msg2_main_raw(ownWindow, "setFrame:", &screen, sizeof(screen), NULL, 0, NULL, 0, NULL, 0);
            r_msg2_main(ownWindow, "setHidden:", 1, 0, 0, 0);
        } else {
            ownWindow = 0;
        }
    }

    /* Host 2: SpringBoard's own window. */
    uint64_t sbWindow = clock_fallback_window(app);
    if (sbWindow == ownWindow) sbWindow = 0;

    uint64_t hosts[CLOCK_MAX_HOSTS] = { ownWindow, sbWindow };
    int hostKinds[CLOCK_MAX_HOSTS] = { CLOCK_HOST_OWN, CLOCK_HOST_SB };

    /* Attach one pill per usable host. */
    int attachedHosts = 0;
    for (int i = 0; i < CLOCK_MAX_HOSTS && attachedHosts < CLOCK_MAX_HOSTS; i++) {
        if (!clock_ptr(hosts[i])) continue;
        uint64_t pill = clock_build_pill(clsUILabel, clsUIColor, clsUIFont, frame);
        if (!clock_ptr(pill)) continue;
        r_perform_main(hosts[i], r_sel("addSubview:"), pill, true);
        r_msg2_main(pill, "setHidden:", 0, 0, 0, 0);
        gClockHost[attachedHosts] = hosts[i];
        gClockPill[attachedHosts] = pill;
        gClockHostKind[attachedHosts] = hostKinds[i];
        attachedHosts++;
    }
    gClockHostCount = attachedHosts;

    if (gClockHostCount == 0) {
        clock_status("找不到可用宿主：own=0x%llx sb=0x%llx scene=0x%llx state=%llu screen=%.0fx%.0f top=%.0f",
                     ownWindow, sbWindow, scene, (unsigned long long)sceneState,
                     screen.size.width, screen.size.height, top);
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    /* Our own window is created hidden; show it now that the pill is inside. */
    if (clock_ptr(ownWindow)) r_msg2_main(ownWindow, "setHidden:", 0, 0, 0, 0);

    clock_push_text();

    /* Prove what we can and report per host. */
    char report[CLOCK_STATUS_MAX] = {0};
    int written = 0;
    int good = 0;
    clock_append(report, sizeof(report), &written,
                 "hosts=%d scene=0x%llx state=%llu screen=%.0fx%.0f top=%.0f",
                 gClockHostCount, scene, (unsigned long long)sceneState,
                 screen.size.width, screen.size.height, top);

    for (int i = 0; i < gClockHostCount; i++) {
        bool attached = false, visible = false, levelOK = false;
        double level = 0.0;
        char text[CLOCK_TEXT_MAX] = {0};
        clock_verify(gClockHost[i], gClockPill[i], &attached, &visible, &levelOK, &level,
                     text, sizeof(text));
        bool ok = attached && visible;
        if (ok) good++;
        clock_append(report, sizeof(report), &written,
                     " | %s host=0x%llx pill=0x%llx attach=%d show=%d lvl=%.0f(ok=%d) text='%s'%s",
                     gClockHostKind[i] == CLOCK_HOST_OWN ? "own" : "sb",
                     gClockHost[i], gClockPill[i],
                     attached ? 1 : 0, visible ? 1 : 0, level, levelOK ? 1 : 0,
                     text, ok ? "" : "(未通过)");
    }

    if (good == 0) {
        clock_status("已挂载但未通过校验：%s", report);
        gClockRunning = false;
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    gClockPid = proc.pid;
    gClockRunning = true;
    clock_start_timer(proc);
    clock_status("已显示（%d/%d 通过）：%s", good, gClockHostCount, report);

    pthread_mutex_unlock(&gClockLock);
    return true;
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

    /* Hide the pills only. The host windows stay untouched: hiding SpringBoard's
       own window would blank the whole UI, and our own window is transparent and
       non-interactive anyway. Keeping the objects makes a later start instant. */
    for (int i = 0; i < gClockHostCount; i++) {
        if (clock_ptr(gClockPill[i])) {
            r_msg2_main(gClockPill[i], "setHidden:", 1, 0, 0, 0);
        }
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
    abandon_remote_call();
}
