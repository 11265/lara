//
//  clock_overlay.m
//  lara
//
//  Global floating clock, excluded from screenshots and screen recordings.
//
//  Cosmetic UI only: a small pill showing this device's local time, drawn by
//  SpringBoard so it floats above apps. The only data source is [NSDate date]
//  in this process — no memory reads, no other process' data.
//
//  Why it is written this way (all three points come from on-device logs):
//
//   1. Every target-side call goes through remote_objc's r_msg2_main* family
//      (NSInvocation + -performSelectorOnMainThread:). Plain remote_msg issues a
//      raw objc_msgSend on the hijacked thread: on this device that killed the
//      trojan thread on the first object method ([UILabel init]), after which
//      every call returned 0.
//   2. No struct-returning remote calls. An earlier build died inside
//      r_msg2_main_struct_ret on [UIScreen mainScreen].bounds. Screen geometry is
//      read locally instead — lara is an app on the same screen, so its own
//      [UIScreen mainScreen].bounds is the same rectangle and costs no call.
//   3. The call shape itself is copied from the peace_esp overlay, which is known
//      to run on this device: connectedScenes.anyObject, alloc + initWithWindowScene:
//      for the window, alloc + init for views, r_nsstr_retained + CFRelease for
//      strings, r_settle_us(1500).
//
//  Screenshot / recording protection (two independent mechanisms):
//   * recording and mirroring: the tick reads [UIScreen mainScreen].isCaptured in
//     lara's own process and hides the whole overlay while the screen is being
//     captured, restoring it afterwards. This needs no private behaviour and
//     cannot silently fail;
//   * screenshots: the pill lives inside a UITextField with secureTextEntry = YES
//     (UIKit treats secure input as capturable-ineligible), and the window and the
//     pill are each probed for the private capture switches that exist on some iOS
//     builds (_setSecure: / setSecure: / setScreenCaptureProhibited:). Step [8/9]
//     reports which object answered to what.
//
//  Steps print "(clock) [n/9] ..." to stdout, which lara's logger captures, so
//  lara.log always ends at the last call that came back.
//

#import "clock_overlay.h"
#import "remote_objc.h"
#import "ARCCompat.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>      /* class_copyMethodList / method_* used by the opt-in device-wide block */
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Tunables

#define CLOCK_TAG            0x1A2B3C4DULL
#define CLOCK_WINDOW_LEVEL   999999.0   /* above app windows and alerts */
#define CLOCK_WIDTH          92.0
#define CLOCK_HEIGHT         26.0
#define CLOCK_CORNER_RADIUS  8.0
#define CLOCK_FONT_SIZE      15.0
#define CLOCK_TOP            62.0       /* clear of the status bar / notch */
#define CLOCK_TICK_MS        250ULL     /* poll 4x/s, push a string only when the second flips */
#define CLOCK_TEXT_MAX       16
#define CLOCK_STATUS_MAX     512

/* Private capture switches, tried in order. Values are BOOL 1. */
static const char *kClockSecureSelectors[] = {
    "_setSecure:",
    "setSecure:",
    "setScreenCaptureProhibited:",
};
#define CLOCK_SECURE_SELECTOR_COUNT (sizeof(kClockSecureSelectors) / sizeof(kClockSecureSelectors[0]))

/* Screenshot and screen-recording handling lives in SpringBoard under one of
   these names, depending on the iOS build. Whatever exists gets enumerated, so
   lara.log always shows the real API of the device it ran on. */
static const char *kCaptureClassNames[] = {
    /* screenshots */
    "SBScreenShotService",
    "SBScreenShotManager",
    "SBScreenshotManager",
    "SBScreenCaptureService",
    "SBScreenShotUIService",
    /* screen recording */
    "SBRecordingService",
    "SBScreenRecordingService",
    "SBRecordingManager",
    "SBScreenRecordingManager",
    "SBScreenRecordingIndicatorManager",
    "SBScreenRecordingAssertion",
    /* mirroring */
    "SBScreenMirroringService",
    "SBAirPlayMirroringService",
    "SBExternalDisplayService",
    /* control center record button */
    "CCUIScreenRecordingModuleViewController",
    "CCUIScreenRecordingModule",
};
#define CLOCK_CAPTURE_CLASS_COUNT (sizeof(kCaptureClassNames) / sizeof(kCaptureClassNames[0]))

/* A selector is a block candidate when its name looks like a capture action. */
static const char *kCaptureKeywords[] = {
    "creenshot", "creencapture", "ecord", "irroring",
};
#define CLOCK_CAPTURE_KEYWORD_COUNT (sizeof(kCaptureKeywords) / sizeof(kCaptureKeywords[0]))

#define CLOCK_CAPTURE_MAX_METHODS 96
#define CLOCK_CAPTURE_MAX_BLOCKED 12

#pragma mark - State

static pthread_mutex_t gClockLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gClockTimer = nil;
static bool gClockRunning = false;
static pid_t gClockPid = 0;
static uint64_t gClockWindow = 0;
static uint64_t gClockContainer = 0;   /* the secure text field */
static uint64_t gClockPill = 0;        /* the label with the time */
static bool gClockWindowSecured = false;
static const char *gClockPillSecuredBy = NULL;
static bool gClockHiddenForCapture = false;   /* hidden because the screen is being captured */
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

/* One-line description of what is currently protecting the pill. */
static const char *clock_protection_summary(void)
{
    if (gClockWindowSecured && gClockPillSecuredBy) return "安全层+窗口开关+图层开关+录屏隐藏";
    if (gClockWindowSecured || gClockPillSecuredBy)  return "安全层+图层开关+录屏隐藏";
    return "安全层+录屏隐藏";
}

/* Asks `obj` for the private capture switches, in order, and applies the first
   one it answers to. Returns the selector that took, or NULL. */
static const char *clock_apply_secure_switch(RemoteCall *proc, uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return NULL;
    for (size_t i = 0; i < CLOCK_SECURE_SELECTOR_COUNT; i++) {
        if (r_responds_main(obj, kClockSecureSelectors[i])) {
            r_msg2_main(obj, kClockSecureSelectors[i], 1, 0, 0, 0);
            return kClockSecureSelectors[i];
        }
    }
    return NULL;
}

/* Screen recording / mirroring protection that needs no private behaviour at
   all: while the screen is being captured, the whole overlay is hidden, and it
   comes back when the capture ends. [UIScreen isCaptured] is read in *this*
   process (lara sits on the same screen), so the check costs no remote call.
   Caller must hold gClockLock. */
static void clock_sync_capture_state(void)
{
    if (!r_is_objc_ptr(gClockPill) && !r_is_objc_ptr(gClockWindow)) return;

    BOOL captured = [UIScreen mainScreen].isCaptured;
    if ((bool)captured == gClockHiddenForCapture) return;   /* nothing changed */
    gClockHiddenForCapture = (bool)captured;

    uint64_t flag = captured ? 1 : 0;
    if (r_is_objc_ptr(gClockContainer)) r_msg2_main(gClockContainer, "setHidden:", flag, 0, 0, 0);
    if (r_is_objc_ptr(gClockPill))      r_msg2_main(gClockPill, "setHidden:", flag, 0, 0, 0);
    if (r_is_objc_ptr(gClockWindow))    r_msg2_main(gClockWindow, "setHidden:", flag, 0, 0, 0);

    printf("(clock) 捕获状态: %s → 悬浮时间已%s\n", captured ? "检测到录屏/镜像" : "结束",
           captured ? "隐藏" : "恢复");
    fflush(stdout);
}

/* Pushes the current time into the pill (main thread, one call per second).
   Caller must hold gClockLock. */
static void clock_push_text(void)
{
    if (!r_is_objc_ptr(gClockPill)) return;

    const char *cstr = [clock_formatter() stringFromDate:[NSDate date]].UTF8String;
    if (!cstr) return;
    if (strncmp(cstr, gClockLastText, sizeof(gClockLastText)) == 0) return;

    strncpy(gClockLastText, cstr, sizeof(gClockLastText) - 1);
    gClockLastText[sizeof(gClockLastText) - 1] = '\0';

    uint64_t str = r_nsstr_retained(cstr);          /* +1 in the target */
    if (!r_is_objc_ptr(str)) return;
    r_msg2_main(gClockPill, "setText:", str, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", str, 0, 0, 0, 0, 0, 0, 0);
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
        if (gClockRunning) {
            clock_sync_capture_state();
            if (!gClockHiddenForCapture) clock_push_text();
        }
        pthread_mutex_unlock(&gClockLock);
    });

    gClockTimer = timer;
    dispatch_resume(gClockTimer);
}

#pragma mark - Build

/* ---------------------------------------------------------------------------
   Global capture blocking: screenshots, screen recording and mirroring.

   For every candidate service class that exists in SpringBoard, walk its method
   list. A method is neutralised only when all of these hold:
     * its name looks like a capture action (screenshot / screen-capture /
       record / mirroring);
     * it is not wiring or UI (setter / is-getter / has / can / should /
       observer / notification / delegate / will / did / indicator / view /
       controller / assertion);
     * its type encoding says it returns void — the replacement IMP is
       -[NSObject class], which takes no arguments and has no side effects, so a
       void caller cannot tell the difference while the action never runs.
   Every candidate and every skip reason is printed, so if this heuristic misses a
   build, lara.log still contains the real selector names for the next round.

   Uses the same remote primitives rc.m uses for its own method patches:
   class_copyMethodList / method_getName / sel_getName / method_getTypeEncoding /
   method_getImplementation / method_setImplementation.
   --------------------------------------------------------------------------- */
int clock_overlay_block_capture(RemoteCall *proc)
{
    if (!proc) {
        clock_status("阻止截屏失败：RemoteCall 为空");
        return 0;
    }

    pthread_mutex_lock(&gClockLock);

    uint64_t clsNSObject = remote_getClass(proc, "NSObject");
    uint64_t noopImp = 0;
    if (r_is_objc_ptr(clsNSObject)) {
        uint64_t selClass = remote_sel(proc, "class");
        uint64_t method = RemoteArbCall(proc, class_getInstanceMethod, clsNSObject, selClass);
        if (method) noopImp = RemoteArbCall(proc, method_getImplementation, method);
    }
    if (!noopImp) {
        pthread_mutex_unlock(&gClockLock);
        clock_status("阻止截屏：拿不到空实现，未做任何修改");
        return 0;
    }

    printf("(clock) === 全局阻止截屏 ===\n");
    fflush(stdout);

    int blocked = 0;
    for (size_t c = 0; c < CLOCK_CAPTURE_CLASS_COUNT; c++) {
        uint64_t cls = remote_getClass(proc, kCaptureClassNames[c]);
        if (!r_is_objc_ptr(cls)) {
            printf("(clock)   类 %s：不存在\n", kCaptureClassNames[c]);
            fflush(stdout);
            continue;
        }

        uint64_t countPtr = RemoteArbCall(proc, malloc, (uint64_t)sizeof(uint32_t));
        if (!countPtr) continue;
        uint64_t list = RemoteArbCall(proc, class_copyMethodList, cls, countPtr);
        uint32_t count = 0;
        if (list) [proc remoteRead:countPtr to:&count size:sizeof(count)];
        if (count > CLOCK_CAPTURE_MAX_METHODS) count = CLOCK_CAPTURE_MAX_METHODS;
        printf("(clock)   类 %s：0x%llx，%u 个方法\n", kCaptureClassNames[c], cls, count);
        fflush(stdout);

        for (uint32_t i = 0; list && i < count; i++) {
            uint64_t method = 0;
            if (![proc remoteRead:list + (uint64_t)i * 8 to:&method size:sizeof(method)] || !method) continue;

            uint64_t sel = RemoteArbCall(proc, method_getName, method);
            uint64_t namePtr = sel ? RemoteArbCall(proc, sel_getName, sel) : 0;
            if (!namePtr) continue;
            char name[128] = {0};
            if (![proc remoteRead:namePtr to:name size:sizeof(name) - 1]) continue;

            bool looksLikeCapture = false;
            for (size_t k = 0; k < CLOCK_CAPTURE_KEYWORD_COUNT && !looksLikeCapture; k++) {
                looksLikeCapture = (strstr(name, kCaptureKeywords[k]) != NULL);
            }
            if (!looksLikeCapture) continue;

            printf("(clock)     候选 %s\n", name);
            fflush(stdout);

            if (strncmp(name, "set", 3) == 0 || strncmp(name, "is", 2) == 0 ||
                strncmp(name, "has", 3) == 0 || strncmp(name, "can", 3) == 0 ||
                strncmp(name, "should", 6) == 0 ||
                strstr(name, "Observer") || strstr(name, "Notification") ||
                strstr(name, "delegate") || strstr(name, "Delegate") ||
                strstr(name, "will") || strstr(name, "did") ||
                strstr(name, "Indicator") || strstr(name, "ViewController") ||
                strstr(name, "View") || strstr(name, "Window") ||
                strstr(name, "Assertion")) {
                printf("(clock)       跳过：属于装配/通知/界面而非动作\n");
                fflush(stdout);
                continue;
            }

            uint64_t encPtr = RemoteArbCall(proc, method_getTypeEncoding, method);
            char enc[32] = {0};
            if (!encPtr || ![proc remoteRead:encPtr to:enc size:sizeof(enc) - 1]) continue;
            if (enc[0] != 'v') {
                printf("(clock)       跳过：返回类型 '%c'（非 void）\n", enc[0]);
                fflush(stdout);
                continue;
            }

            if (blocked >= CLOCK_CAPTURE_MAX_BLOCKED) {
                printf("(clock)       跳过：已达上限 %d\n", CLOCK_CAPTURE_MAX_BLOCKED);
                fflush(stdout);
                continue;
            }

            RemoteArbCall(proc, method_setImplementation, method, noopImp);
            blocked++;
            printf("(clock)       → 已置为空实现（该截屏动作会被吞掉）\n");
            fflush(stdout);
        }

        if (countPtr) RemoteArbCall(proc, free, countPtr);
        if (list) RemoteArbCall(proc, free, list);
    }

    clock_status("全局防录屏/防截屏：已吞掉 %d 个捕获动作（候选与跳过原因见日志）", blocked);
    pthread_mutex_unlock(&gClockLock);
    return blocked;
}

/* Numbered steps, printed as we go: the last line in lara.log is the last call
   that came back alive. */
static bool clock_build(RemoteCall *proc)
{
    int step = 0;

    /* Point remote_objc's global helpers at lara's live SpringBoard session —
       the same single-context arrangement the peace_esp overlay used. */
    arc_use_existing_remote_call((__bridge void *)proc);
    r_settle_us(1500);

    /* 1/9 — classes. */
    uint64_t clsApplication = r_class("UIApplication");
    uint64_t clsWindow      = r_class("UIWindow");
    uint64_t clsLabel       = r_class("UILabel");
    uint64_t clsField       = r_class("UITextField");
    uint64_t clsColor       = r_class("UIColor");
    uint64_t clsFont        = r_class("UIFont");
    step++;
    clock_status("[%d/9] 类: app=0x%llx win=0x%llx label=0x%llx field=0x%llx color=0x%llx font=0x%llx",
                 step, clsApplication, clsWindow, clsLabel, clsField, clsColor, clsFont);
    if (!r_is_objc_ptr(clsApplication) || !r_is_objc_ptr(clsWindow) ||
        !r_is_objc_ptr(clsLabel) || !r_is_objc_ptr(clsField)) {
        return false;
    }

    /* 2/9 — application object. */
    uint64_t app = r_msg2_main(clsApplication, "sharedApplication", 0, 0, 0, 0);
    step++;
    clock_status("[%d/9] sharedApplication=0x%llx", step, app);
    if (!r_is_objc_ptr(app)) return false;

    /* 3/9 — the scene to host the window on. */
    uint64_t scenes = r_msg2_main(app, "connectedScenes", 0, 0, 0, 0);
    uint64_t scene = r_is_objc_ptr(scenes) ? r_msg2_main(scenes, "anyObject", 0, 0, 0, 0) : 0;
    step++;
    clock_status("[%d/9] connectedScenes=0x%llx scene=0x%llx", step, scenes, scene);
    if (!r_is_objc_ptr(scene)) return false;

    /* 4/9 — our own high-level window. Screen geometry is local (see header). */
    CGRect screen = [UIScreen mainScreen].bounds;
    if (screen.size.width < 1.0 || screen.size.height < 1.0) screen = CGRectMake(0, 0, 390, 844);

    uint64_t allocatedWindow = r_msg2_main(clsWindow, "alloc", 0, 0, 0, 0);
    uint64_t window = r_is_objc_ptr(allocatedWindow)
        ? r_msg2_main(allocatedWindow, "initWithWindowScene:", scene, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(window)) {
        step++;
        clock_status("[%d/9] 窗口创建失败 allocated=0x%llx", step, allocatedWindow);
        return false;
    }

    double level = CLOCK_WINDOW_LEVEL;
    r_msg2_main_raw(window, "setWindowLevel:", &level, sizeof(level), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(window, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(window, "setOpaque:", 0, 0, 0, 0);
    uint64_t clear = r_msg2_main(clsColor, "clearColor", 0, 0, 0, 0);
    if (r_is_objc_ptr(clear)) r_msg2_main(window, "setBackgroundColor:", clear, 0, 0, 0);
    r_msg2_main_raw(window, "setFrame:", &screen, sizeof(screen), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(window, "setHidden:", 1, 0, 0, 0);
    step++;
    clock_status("[%d/9] window=0x%llx screen=%.0fx%.0f level=%.0f", step, window,
                 screen.size.width, screen.size.height, level);

    /* 5/9 — the pill itself. */
    CGRect frame = CGRectMake((screen.size.width - CLOCK_WIDTH) / 2.0, CLOCK_TOP,
                              CLOCK_WIDTH, CLOCK_HEIGHT);

    uint64_t allocatedLabel = r_msg2_main(clsLabel, "alloc", 0, 0, 0, 0);
    uint64_t pill = r_is_objc_ptr(allocatedLabel)
        ? r_msg2_main(allocatedLabel, "init", 0, 0, 0, 0)
        : 0;
    step++;
    clock_status("[%d/9] label allocated=0x%llx pill=0x%llx", step, allocatedLabel, pill);
    if (!r_is_objc_ptr(pill)) return false;

    /* 6/9 — pill styling. */
    double fontSize = CLOCK_FONT_SIZE;
    uint64_t font = r_is_objc_ptr(clsFont)
        ? r_msg2_main_raw(clsFont, "systemFontOfSize:", &fontSize, sizeof(fontSize),
                          NULL, 0, NULL, 0, NULL, 0)
        : 0;
    if (r_is_objc_ptr(font)) r_msg2_main(pill, "setFont:", font, 0, 0, 0);
    r_msg2_main(pill, "setTextAlignment:", 1 /* centre */, 0, 0, 0);
    r_msg2_main(pill, "setNumberOfLines:", 1, 0, 0, 0);
    r_msg2_main(pill, "setClipsToBounds:", 1, 0, 0, 0);
    uint64_t white = r_msg2_main(clsColor, "whiteColor", 0, 0, 0, 0);
    uint64_t black = r_msg2_main(clsColor, "blackColor", 0, 0, 0, 0);
    if (r_is_objc_ptr(white)) r_msg2_main(pill, "setTextColor:", white, 0, 0, 0);
    if (r_is_objc_ptr(black)) r_msg2_main(pill, "setBackgroundColor:", black, 0, 0, 0);
    uint64_t layer = r_msg2_main(pill, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        double radius = CLOCK_CORNER_RADIUS;
        r_msg2_main_raw(layer, "setCornerRadius:", &radius, sizeof(radius), NULL, 0, NULL, 0, NULL, 0);
    }
    /* The pill fills its secure container, so the container carries the position. */
    CGRect inner = CGRectMake(0, 0, CLOCK_WIDTH, CLOCK_HEIGHT);
    r_msg2_main_raw(pill, "setFrame:", &inner, sizeof(inner), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(pill, "setTag:", (uint64_t)CLOCK_TAG, 0, 0, 0);
    step++;
    clock_status("[%d/9] 样式完成 font=0x%llx white=0x%llx black=0x%llx layer=0x%llx", step,
                 font, white, black, layer);

    /* 7/9 — the secure container that keeps the pill out of screenshots and
       recordings. A secure UITextField is capturable-ineligible along with its
       subtree; it carries no text of its own. */
    uint64_t allocatedField = r_msg2_main(clsField, "alloc", 0, 0, 0, 0);
    uint64_t field = r_is_objc_ptr(allocatedField)
        ? r_msg2_main(allocatedField, "init", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(field)) {
        r_msg2_main(field, "setSecureTextEntry:", 1, 0, 0, 0);
        r_msg2_main(field, "setUserInteractionEnabled:", 0, 0, 0, 0);
        r_msg2_main(field, "setBorderStyle:", 0 /* none */, 0, 0, 0);
        r_msg2_main(field, "setClipsToBounds:", 1, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(field, "setBackgroundColor:", clear, 0, 0, 0);
        r_msg2_main_raw(field, "setFrame:", &frame, sizeof(frame), NULL, 0, NULL, 0, NULL, 0);
        r_msg2_main(field, "addSubview:", pill, 0, 0, 0);
        r_msg2_main(window, "addSubview:", field, 0, 0, 0);
    } else {
        /* No secure container available: show the pill directly. */
        r_msg2_main_raw(pill, "setFrame:", &frame, sizeof(frame), NULL, 0, NULL, 0, NULL, 0);
        r_msg2_main(window, "addSubview:", pill, 0, 0, 0);
    }
    step++;
    clock_status("[%d/9] 安全容器 field=0x%llx secureTextEntry=1 frame=%.0f,%.0f", step, field,
                 frame.origin.x, frame.origin.y);

    /* 8/9 — capture switches, probed on the window and on the pill itself. */
    const char *securedBy = clock_apply_secure_switch(proc, window);
    gClockWindowSecured = (securedBy != NULL);
    const char *pillSecuredBy = clock_apply_secure_switch(proc, pill);
    gClockPillSecuredBy = pillSecuredBy;
    step++;
    clock_status("[%d/9] 捕获开关: window=%s pill=%s", step,
                 securedBy ? securedBy : "无", pillSecuredBy ? pillSecuredBy : "无");

    /* 9/9 — first text, then show, then verify. */
    gClockContainer = field;
    gClockPill = pill;
    clock_push_text();
    r_msg2_main(window, "setHidden:", 0, 0, 0, 0);

    uint64_t found = r_msg2_main(window, "viewWithTag:", (uint64_t)CLOCK_TAG, 0, 0, 0);
    uint64_t hidden = r_msg2_main(pill, "isHidden", 0, 0, 0, 0);
    step++;
    clock_status("[%d/9] 校验 tag=0x%llx(应为0x%llx) hidden=%llu 防录屏=%s", step, found, pill,
                 (unsigned long long)(hidden & 0xff), clock_protection_summary());

    gClockWindow = window;
    gClockPid = proc.pid;
    return r_is_objc_ptr(found) && found == pill;
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

    /* Still alive in the same target? Just show it again. */
    if (gClockPid == proc.pid && r_is_objc_ptr(gClockPill) && r_is_objc_ptr(gClockWindow)) {
        uint64_t found = r_msg2_main(gClockWindow, "viewWithTag:", (uint64_t)CLOCK_TAG, 0, 0, 0);
        if (found == gClockPill) {
            if (r_is_objc_ptr(gClockContainer)) {
                r_msg2_main(gClockContainer, "setHidden:", 0, 0, 0, 0);
            }
            r_msg2_main(gClockPill, "setHidden:", 0, 0, 0, 0);
            gClockLastText[0] = '\0';
            clock_push_text();
            gClockRunning = true;
            clock_start_timer(proc);
            clock_status("复用已有胶囊：window=0x%llx field=0x%llx pill=0x%llx",
                         gClockWindow, gClockContainer, gClockPill);
            pthread_mutex_unlock(&gClockLock);
            return true;
        }
    }

    gClockWindow = 0;
    gClockContainer = 0;
    gClockPill = 0;
    gClockWindowSecured = false;
    gClockPillSecuredBy = NULL;
    gClockHiddenForCapture = false;
    gClockLastText[0] = '\0';

    bool attached = clock_build(proc);
    if (!attached) {
        /* clock_build printed the last step it reached. */
        pthread_mutex_unlock(&gClockLock);
        return false;
    }

    gClockRunning = true;
    clock_start_timer(proc);
    clock_status("已显示：window=0x%llx field=0x%llx pill=0x%llx 防录屏=%s",
                 gClockWindow, gClockContainer, gClockPill, clock_protection_summary());

    pthread_mutex_unlock(&gClockLock);

    /* NOTE: clock_overlay_block_capture() is deliberately NOT called here. It
       blocks capture device-wide by patching SpringBoard's capture services,
       which is a much bigger hammer than protecting this app; it stays available
       for explicit, opt-in use only. The whole-app protection now lives in
       Swift (funcs/captureprotect.swift). */
    return true;
}

bool clock_overlay_selftest(RemoteCall *proc)
{
    if (!proc) {
        clock_status("自检失败：RemoteCall 为空");
        return false;
    }

    /* Clean slate, so the numbered steps below tell the whole story. */
    pthread_mutex_lock(&gClockLock);
    gClockRunning = false;
    if (gClockTimer) {
        dispatch_source_cancel(gClockTimer);
        gClockTimer = nil;
    }
    if (r_is_objc_ptr(gClockContainer)) {
        r_msg2_main(gClockContainer, "setHidden:", 1, 0, 0, 0);
    }
    if (r_is_objc_ptr(gClockPill)) {
        r_msg2_main(gClockPill, "setHidden:", 1, 0, 0, 0);
    }
    gClockWindow = 0;
    gClockContainer = 0;
    gClockPill = 0;
    gClockWindowSecured = false;
    gClockPillSecuredBy = NULL;
    gClockHiddenForCapture = false;
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

    /* Hide what we own; SpringBoard's own windows are never touched. */
    if (r_is_objc_ptr(gClockContainer)) {
        r_msg2_main(gClockContainer, "setHidden:", 1, 0, 0, 0);
    }
    if (r_is_objc_ptr(gClockPill)) {
        r_msg2_main(gClockPill, "setHidden:", 1, 0, 0, 0);
    }
    if (r_is_objc_ptr(gClockWindow)) {
        r_msg2_main(gClockWindow, "setHidden:", 1, 0, 0, 0);
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
    /* lara is destroying the RemoteCall session; drop the global binding so a
       later start cannot talk to the destroyed object. */
    abandon_remote_call();
}
