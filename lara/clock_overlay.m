//
//  clock_overlay.m
//  lara
//
//  Global floating overlay = 第一视角（FPS）雷达。
//
//  浮层由 SpringBoard 绘制（所以能浮在所有应用之上）。内容优先用 WKWebView
//  加载局域网页面 http://<电脑IP>:<端口>/（rr/fpv 服务，数据来自电脑上的解析
//  核心）；如果目标进程里拿不到 WKWebView，就退回原来的时间胶囊。
//
//  为什么沿用旧的调用形态（来自真机日志的教训）：
//   1. 所有目标侧调用都走 remote_objc 的 r_msg2_main* 家族
//      (NSInvocation + -performSelectorOnMainThread:)。直接 remote_msg 会在
//      hijack 线程上裸调 objc_msgSend，在这台设备上第一次对象方法调用就打死线程。
//   2. 不做“返回结构体”的远程调用：远程读 [UIScreen mainScreen].bounds 会把目标
//      卡死。几何一律在本地读（lara 与 SpringBoard 同一块屏幕）。
//   3. 带结构体参数（CGRect 等）的调用用 r_msg2_main_raw 传指针 + 长度，
//      与旧的 setWindowLevel:/setFrame: 完全一致。
//
//  地址与尺寸可热改：主进程把偏好写进 UserDefaults，这里的定时器每秒比对一次，
//  变了就重新 loadRequest，不用重启 lara。
//
//  每一步都会打印 "(overlay) [n/m] ..." 到 stdout，由 lara 的日志捕获，
//  日志停在哪个编号就说明哪一步把远程调用弄死了。
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
#import <unistd.h>

#pragma mark - Tunables

#define OV_TAG                0x1A2B3C4DULL
#define OV_WINDOW_LEVEL       999999.0   /* above app windows and alerts */
#define OV_DEFAULT_URL        "http://192.168.137.1:18099/"
#define OV_URL_MAX            256
#define OV_STATUS_MAX         512
#define OV_TICK_MS            250ULL     /* 4x/s：胶囊走秒；网页每 OV_URL_CHECK_TICKS 次比对地址 */
#define OV_URL_CHECK_TICKS    4          /* 4 * 250ms = 1s 检查一次地址变化 */

/* 胶囊（退回方案）外观 */
#define OV_PILL_WIDTH         92.0
#define OV_PILL_HEIGHT        26.0
#define OV_PILL_RADIUS        8.0
#define OV_PILL_FONT          15.0
#define OV_PILL_TEXT_MAX      16

/* 第一视角浮层默认几何 */
#define OV_WEB_WIDTH_RATIO    0.92       /* 屏宽占比 */
#define OV_WEB_TOP            56.0       /* 避开状态栏/刘海 */
#define OV_WEB_ASPECT         9.0 / 16.0 /* 高 = 宽 * 9/16 */

#pragma mark - State

static pthread_mutex_t gOvLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gOvTimer = nil;
static bool gOvRunning = false;
static pid_t gOvPid = 0;
static uint64_t gOvWindow = 0;
static uint64_t gOvPill = 0;             /* 退回方案：时间胶囊 */
static uint64_t gOvWeb = 0;              /* 主方案：WKWebView */
static bool gOvWebMode = false;
static char gOvLastText[OV_PILL_TEXT_MAX] = {0};
static char gOvStatus[OV_STATUS_MAX] = "尚未启动";
static char gOvUrl[OV_URL_MAX] = OV_DEFAULT_URL;
static char gOvUrlLoaded[OV_URL_MAX] = {0};
static double gOvWidthRatio = OV_WEB_WIDTH_RATIO;
static double gOvTop = OV_WEB_TOP;
static unsigned gOvTick = 0;
/* 单飞 + 失败闩锁：
   远程调用的参数缓冲区在 lara 进程里是全局共享的，两次远程调用同时在飞
   （真机日志里出现过：malloc/getpid 的回复交错）会让 malloc 返回垃圾指针，
   接着 remote_write 写到地址 0，目标进程就带着脏寄存器执行 objc_getClass →
   SpringBoard 崩溃。所以：同一时刻只允许一次构建；一旦失败，绝不再自动重试。 */
static bool gOvBuilding = false;
static bool gOvFailed = false;
static unsigned gOvGuard = 0;      /* 触摸穿透自愈计数（每 8 个 tick = 2 秒一次） */

/* 方向 / 全屏：由 lara 主线程用设备方向推过来（见 clock_overlay_set_layout）。
   目标进程的窗口空间跟随设备方向，所以横屏 = 长短边对调；尺寸全部按本机真实
   分辨率算，方向变化时只重设 frame，不重建浮层、不重新加载页面。 */
static int gOvLandscape = 0;
static int gOvFullscreen = 0;
static int gOvAppliedLandscape = -1;
static int gOvAppliedFullscreen = -1;
static double gOvAppliedW = 0;
static double gOvAppliedH = 0;

/* BOOL / NSInteger 参数必须走 raw 形态按字节传：
   用 r_msg2_main(obj, sel, 0, ...) 传标量时，参数会被当成“对象”，目标侧实际
   收到垃圾值（真机表现＝ setUserInteractionEnabled: 没生效，全屏浮层把触摸全吃掉）。 */
static void ov_set_bool(uint64_t obj, const char *sel, bool value)
{
    if (!r_is_objc_ptr(obj)) return;
    signed char v = value ? 1 : 0;
    r_msg2_main_raw(obj, sel, &v, sizeof(v), NULL, 0, NULL, 0, NULL, 0);
}
static void ov_set_int(uint64_t obj, const char *sel, long long value)
{
    if (!r_is_objc_ptr(obj)) return;
    long long v = value;
    r_msg2_main_raw(obj, sel, &v, sizeof(v), NULL, 0, NULL, 0, NULL, 0);
}

static void ov_status(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gOvStatus, sizeof(gOvStatus), fmt, ap);
    va_end(ap);
    printf("(overlay) %s\n", gOvStatus);
    fflush(stdout);
}

#pragma mark - Config (called from lara's process)

void clock_overlay_set_url(const char *url)
{
    pthread_mutex_lock(&gOvLock);
    if (!url || !url[0]) {
        strncpy(gOvUrl, OV_DEFAULT_URL, sizeof(gOvUrl) - 1);
        gOvUrl[sizeof(gOvUrl) - 1] = '\0';
    } else {
        strncpy(gOvUrl, url, sizeof(gOvUrl) - 1);
        gOvUrl[sizeof(gOvUrl) - 1] = '\0';
    }
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_geometry(double widthRatio, double topMargin)
{
    pthread_mutex_lock(&gOvLock);
    gOvWidthRatio = (widthRatio >= 0.2 && widthRatio <= 1.0) ? widthRatio : OV_WEB_WIDTH_RATIO;
    gOvTop = (topMargin >= 0.0 && topMargin <= 600.0) ? topMargin : OV_WEB_TOP;
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_layout(int landscape, int fullscreen)
{
    pthread_mutex_lock(&gOvLock);
    gOvLandscape = landscape ? 1 : 0;
    gOvFullscreen = fullscreen ? 1 : 0;
    pthread_mutex_unlock(&gOvLock);
}

/* 本机真实分辨率的“长边/短边”。本地读取：远程读 bounds 会把目标卡死。 */
static void ov_screen_sides(double *longSide, double *shortSide)
{
    CGRect b = [UIScreen mainScreen].bounds;
    double w = b.size.width, h = b.size.height;
    if (w < 1.0 || h < 1.0) { w = 390.0; h = 844.0; }
    *longSide = (w > h) ? w : h;
    *shortSide = (w > h) ? h : w;
}

/* 当前内容（网页或胶囊）应该占的 frame：横屏把长短边对调，全屏铺满整屏。 */
static CGRect ov_content_frame(void)
{
    double L = 0, S = 0;
    ov_screen_sides(&L, &S);
    double W = gOvLandscape ? L : S;          /* 目标进程的窗口空间跟随设备方向 */
    double H = gOvLandscape ? S : L;

    if (!gOvWebMode) {                        /* 退回方案：时间胶囊，居中靠顶 */
        return CGRectMake((W - OV_PILL_WIDTH) / 2.0, gOvTop, OV_PILL_WIDTH, OV_PILL_HEIGHT);
    }

    if (gOvFullscreen) {
        double top = gOvTop;
        if (top < 0.0 || top > H - 120.0) top = 0.0;
        return CGRectMake(0, top, W, H - top);
    }

    double width = W * gOvWidthRatio;
    if (width < 200.0) width = W * OV_WEB_WIDTH_RATIO;
    if (width > W) width = W;
    double height = width * OV_WEB_ASPECT;
    double maxHeight = H - gOvTop - 20.0;
    if (height > maxHeight) height = maxHeight;
    if (height < 120.0) height = 120.0;
    return CGRectMake((W - width) / 2.0, gOvTop, width, height);
}

/* 把方向/全屏/尺寸变化应用到目标（只改 frame，页面不动）。 */
static void ov_apply_layout(void)
{
    if (!r_is_objc_ptr(gOvWindow)) return;
    double L = 0, S = 0;
    ov_screen_sides(&L, &S);
    double W = gOvLandscape ? L : S;
    double H = gOvLandscape ? S : L;

    CGRect win = CGRectMake(0, 0, W, H);
    CGRect content = ov_content_frame();
    r_msg2_main_raw(gOvWindow, "setFrame:", &win, sizeof(win), NULL, 0, NULL, 0, NULL, 0);
    uint64_t target = gOvWebMode ? gOvWeb : gOvPill;
    if (r_is_objc_ptr(target)) {
        r_msg2_main_raw(target, "setFrame:", &content, sizeof(content), NULL, 0, NULL, 0, NULL, 0);
    }
    gOvAppliedLandscape = gOvLandscape;
    gOvAppliedFullscreen = gOvFullscreen;
    gOvAppliedW = W;
    gOvAppliedH = H;
    ov_status("布局已更新：%s%s %.0fx%.0f → 内容 %.0f,%.0f %.0fx%.0f",
              gOvLandscape ? "横屏" : "竖屏", gOvFullscreen ? " 全屏" : "",
              W, H, content.origin.x, content.origin.y, content.size.width, content.size.height);
}

const char *clock_overlay_url(void)
{
    return gOvUrl;
}

#pragma mark - 时间胶囊（退回方案）

static NSDateFormatter *ov_formatter(void)
{
    static NSDateFormatter *fmt = nil;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"HH:mm:ss";
    }
    return fmt;
}

/* Pushes the current time into the pill (main thread, one call per second).
   Caller must hold gOvLock. */
static void ov_push_text(void)
{
    if (!r_is_objc_ptr(gOvPill)) return;

    const char *cstr = [ov_formatter() stringFromDate:[NSDate date]].UTF8String;
    if (!cstr) return;
    if (strncmp(cstr, gOvLastText, sizeof(gOvLastText)) == 0) return;

    strncpy(gOvLastText, cstr, sizeof(gOvLastText) - 1);
    gOvLastText[sizeof(gOvLastText) - 1] = '\0';

    uint64_t str = r_nsstr_retained(cstr);          /* +1 in the target */
    if (!r_is_objc_ptr(str)) return;
    r_msg2_main(gOvPill, "setText:", str, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", str, 0, 0, 0, 0, 0, 0, 0);
}

#pragma mark - 第一视角网页（主方案）

/* 让 WKWebView 加载 gOvUrl（可在主线程之外调用，内部用的都是 r_msg2_main*）。
   Caller must hold gOvLock. */
static void ov_load_url(void)
{
    if (!r_is_objc_ptr(gOvWeb) || !gOvUrl[0]) return;

    uint64_t clsNSURL = r_class("NSURL");
    uint64_t clsReq   = r_class("NSURLRequest");
    if (!r_is_objc_ptr(clsNSURL) || !r_is_objc_ptr(clsReq)) {
        ov_status("网页失败：找不到 NSURL/NSURLRequest");
        return;
    }

    uint64_t str = r_nsstr_retained(gOvUrl);
    if (!r_is_objc_ptr(str)) { ov_status("网页失败：地址字符串创建失败"); return; }

    uint64_t nsurl = r_msg2_main(clsNSURL, "URLWithString:", str, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", str, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(nsurl)) { ov_status("网页失败：URL 解析失败（%s）", gOvUrl); return; }

    uint64_t req = r_msg2_main(clsReq, "requestWithURL:", nsurl, 0, 0, 0);
    if (!r_is_objc_ptr(req)) { ov_status("网页失败：NSURLRequest 创建失败"); return; }

    r_msg2_main(gOvWeb, "loadRequest:", req, 0, 0, 0);
    strncpy(gOvUrlLoaded, gOvUrl, sizeof(gOvUrlLoaded) - 1);
    gOvUrlLoaded[sizeof(gOvUrlLoaded) - 1] = '\0';
    ov_status("第一视角已加载：%s", gOvUrl);
}

/* 建 WKWebView；失败返回 0。 */
static uint64_t ov_build_web(RemoteCall *proc, CGRect screen, CGRect frame)
{
    uint64_t clsWeb = r_class("WKWebView");
    uint64_t clsCfg = r_class("WKWebViewConfiguration");
    if (!r_is_objc_ptr(clsWeb) || !r_is_objc_ptr(clsCfg)) {
        printf("(overlay) 目标进程没有 WKWebView（web=0x%llx cfg=0x%llx），改用时间胶囊\n",
               clsWeb, clsCfg);
        fflush(stdout);
        return 0;
    }

    uint64_t cfgAlloc = r_msg2_main(clsCfg, "alloc", 0, 0, 0, 0);
    uint64_t cfg = r_is_objc_ptr(cfgAlloc) ? r_msg2_main(cfgAlloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(cfg)) { ov_status("网页失败：WKWebViewConfiguration 创建失败"); return 0; }

    uint64_t webAlloc = r_msg2_main(clsWeb, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(webAlloc)) { ov_status("网页失败：WKWebView alloc 失败"); return 0; }

    /* initWithFrame:configuration: —— 结构体 + 对象指针一起走 raw 形态 */
    uint64_t cfgVal = cfg;
    uint64_t web = r_msg2_main_raw(webAlloc, "initWithFrame:configuration:",
                                   &frame, sizeof(frame), &cfgVal, sizeof(cfgVal),
                                   NULL, 0, NULL, 0);
    if (!r_is_objc_ptr(web)) { ov_status("网页失败：WKWebView init 失败"); return 0; }

    /* 外观与行为：整层透明（只留网页画的方框/文字/准星）、不可滚动、不吃触摸 */
    uint64_t clsColor = r_class("UIColor");
    uint64_t clear = 0;
    if (r_is_objc_ptr(clsColor)) clear = r_msg2_main(clsColor, "clearColor", 0, 0, 0, 0);
    if (r_is_objc_ptr(clear)) {
        r_msg2_main(web, "setBackgroundColor:", clear, 0, 0, 0);
        /* WKWebView 自带的底色在这几个地方，不清掉就会出现一块黑/白底挡着游戏 */
        if (r_responds(web, "setUnderPageBackgroundColor:")) {
            r_msg2_main(web, "setUnderPageBackgroundColor:", clear, 0, 0, 0);
        }
    }
    ov_set_bool(web, "setOpaque:", 0);
    ov_set_bool(web, "setUserInteractionEnabled:", 0);
    ov_set_bool(web, "setMultipleTouchEnabled:", 0);
    uint64_t scroll = r_msg2_main(web, "scrollView", 0, 0, 0, 0);
    if (r_is_objc_ptr(scroll)) {
        /* 触摸穿透 + 透明：窗口 + 网页 + 内部滚动视图全部关掉交互与底色，
           命中测试会直接跳过整棵子树，手指全部落到下面的游戏里。 */
        ov_set_bool(scroll, "setUserInteractionEnabled:", 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(scroll, "setBackgroundColor:", clear, 0, 0, 0);
        ov_set_bool(scroll, "setScrollEnabled:", 0);
        ov_set_bool(scroll, "setBounces:", 0);
        ov_set_bool(scroll, "setShowsVerticalScrollIndicator:", 0);
        ov_set_bool(scroll, "setShowsHorizontalScrollIndicator:", 0);
    }
    uint64_t layer = r_msg2_main(web, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        double radius = 14.0;
        r_msg2_main_raw(layer, "setCornerRadius:", &radius, sizeof(radius), NULL, 0, NULL, 0, NULL, 0);
        ov_set_bool(layer, "setMasksToBounds:", 1);
    }
    double opacity = 0.96;
    r_msg2_main_raw(web, "setAlpha:", &opacity, sizeof(opacity), NULL, 0, NULL, 0, NULL, 0);
    ov_set_int(web, "setTag:", (long long)(OV_TAG));
    (void)proc;
    (void)screen;

    gOvWeb = web;
    gOvWebMode = true;
    ov_load_url();
    return web;
}

/* 建时间胶囊；失败返回 0。 */
static uint64_t ov_build_pill(CGRect screen, CGRect frame)
{
    uint64_t clsLabel = r_class("UILabel");
    uint64_t clsColor = r_class("UIColor");
    uint64_t clsFont  = r_class("UIFont");
    if (!r_is_objc_ptr(clsLabel)) { ov_status("胶囊失败：找不到 UILabel"); return 0; }

    uint64_t allocatedLabel = r_msg2_main(clsLabel, "alloc", 0, 0, 0, 0);
    uint64_t pill = r_is_objc_ptr(allocatedLabel) ? r_msg2_main(allocatedLabel, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(pill)) { ov_status("胶囊失败：UILabel init 失败"); return 0; }

    double fontSize = OV_PILL_FONT;
    uint64_t font = r_is_objc_ptr(clsFont)
        ? r_msg2_main_raw(clsFont, "systemFontOfSize:", &fontSize, sizeof(fontSize), NULL, 0, NULL, 0, NULL, 0)
        : 0;
    if (r_is_objc_ptr(font)) r_msg2_main(pill, "setFont:", font, 0, 0, 0);
    r_msg2_main(pill, "setTextAlignment:", 1 /* centre */, 0, 0, 0);
    ov_set_int(pill, "setNumberOfLines:", (long long)(1));
    ov_set_bool(pill, "setClipsToBounds:", 1);
    if (r_is_objc_ptr(clsColor)) {
        uint64_t white = r_msg2_main(clsColor, "whiteColor", 0, 0, 0, 0);
        uint64_t black = r_msg2_main(clsColor, "blackColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(white)) r_msg2_main(pill, "setTextColor:", white, 0, 0, 0);
        if (r_is_objc_ptr(black)) r_msg2_main(pill, "setBackgroundColor:", black, 0, 0, 0);
    }
    uint64_t layer = r_msg2_main(pill, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        double radius = OV_PILL_RADIUS;
        r_msg2_main_raw(layer, "setCornerRadius:", &radius, sizeof(radius), NULL, 0, NULL, 0, NULL, 0);
    }
    r_msg2_main_raw(pill, "setFrame:", &frame, sizeof(frame), NULL, 0, NULL, 0, NULL, 0);
    ov_set_int(pill, "setTag:", (long long)(OV_TAG));
    (void)screen;

    gOvPill = pill;
    gOvWebMode = false;
    ov_push_text();
    return pill;
}

#pragma mark - Ticking

static void ov_tick(void)
{
    pthread_mutex_lock(&gOvLock);
    if (!gOvRunning) { pthread_mutex_unlock(&gOvLock); return; }

    if (gOvWebMode) {
        /* 每秒比对一次地址：主进程改了偏好就热重载，不用重启 lara */
        if (++gOvTick >= OV_URL_CHECK_TICKS) {
            gOvTick = 0;
            if (strncmp(gOvUrl, gOvUrlLoaded, sizeof(gOvUrl)) != 0) {
                printf("(overlay) 地址变化：%s -> %s，重新加载\n", gOvUrlLoaded, gOvUrl);
                fflush(stdout);
                ov_load_url();
            }
        }
    } else {
        ov_push_text();
    }

    /* 方向（横竖屏）、全屏开关、分辨率变化：只重设 frame，页面不重建。 */
    double L = 0, S = 0;
    ov_screen_sides(&L, &S);
    double W = gOvLandscape ? L : S;
    double H = gOvLandscape ? S : L;
    if (gOvAppliedLandscape != gOvLandscape || gOvAppliedFullscreen != gOvFullscreen
        || gOvAppliedW != W || gOvAppliedH != H) {
        ov_apply_layout();
    }

    /* 触摸穿透自愈：iOS 有时会重建窗口内部视图、把交互重新打开，
       而一个 999999 层级、全屏的窗口一旦变回“可交互”，就会把游戏的手指全吃掉
       （真机现象：桌面和 lara 能点、别的游戏点不动）。这里每 2 秒重新关一次，
       并把回读值打进日志，让穿透状态可验证。 */
    if (++gOvGuard >= 8) {
        gOvGuard = 0;
        ov_set_bool(gOvWindow, "setUserInteractionEnabled:", 0);
        if (r_is_objc_ptr(gOvWeb)) {
            ov_set_bool(gOvWeb, "setUserInteractionEnabled:", 0);
            uint64_t scroll = r_msg2_main(gOvWeb, "scrollView", 0, 0, 0, 0);
            if (r_is_objc_ptr(scroll)) ov_set_bool(scroll, "setUserInteractionEnabled:", 0);
        }
        uint64_t winUI = r_msg2_main(gOvWindow, "isUserInteractionEnabled", 0, 0, 0, 0);
        if ((winUI & 0xff) != 0) {
            printf("(overlay) 警告：窗口又变成可交互（winUI=%u），已再次关闭\n",
                   (unsigned)(winUI & 0xff));
            fflush(stdout);
        }
    }
    pthread_mutex_unlock(&gOvLock);
}

static void ov_start_timer(RemoteCall *proc)
{
    if (gOvTimer) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!timer) {
        printf("(overlay) 定时器创建失败\n");
        fflush(stdout);
        return;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              OV_TICK_MS * NSEC_PER_MSEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        ov_tick();
    });
    gOvTimer = timer;
    dispatch_resume(gOvTimer);
    (void)proc;
}

#pragma mark - 会话健康检查

/* 远程会话自检：在碰任何 objc 类之前，先确认远程内存通道是好的。
   判据只用 RemoteCall 自己的 vm 通道（真机日志里一直稳定）：
     取目标线程结构地址 → 读 8 字节 → 把原值写回 → 再读，必须一致。
   不碰 objc、不分配内存、不改动目标状态。
   刻意不看 getpid：r_call_stable 对 getpid 有已知的偶发返回 0 特例
   （RemoteCall.m 里就专门处理过），拿它当判据会误判成“会话坏了”。
   读不到地址（可能不可映射）时不下结论、继续建浮层——只有“写失败/读回不一致”
   才认定通道坏了并放弃。 */
static bool ov_session_healthy(RemoteCall *proc, const char **why)
{
    bool conclusive_bad = false;

    for (int attempt = 0; attempt < 3; attempt++) {
        /* 让上一次调用彻底回收，避免和残留的调用交错 */
        r_settle_us(30000);
        usleep(80 * 1000);

        uint64_t addr = proc.trojanThreadAddr ? proc.trojanThreadAddr : proc.callThreadAddr;
        if (addr < 0x1000ULL) {
            *why = "拿不到目标线程结构地址";
            printf("(overlay) 健康检查[%d]：线程地址无效\n", attempt);
            fflush(stdout);
            continue;
        }

        uint64_t before = [proc remoteRead64From:addr];
        if (before == 0) {
            *why = "远程读取返回 0（该地址可能不可映射）";
            printf("(overlay) 健康检查[%d]：读不到 0x%llx\n", attempt, addr);
            fflush(stdout);
            continue;                      /* 不下结论 */
        }
        if (![proc remote_write64:addr value:before]) {
            *why = "远程写入失败";
            printf("(overlay) 健康检查[%d]：写 0x%llx 失败\n", attempt, addr);
            fflush(stdout);
            conclusive_bad = true;
            continue;
        }
        if ([proc remoteRead64From:addr] != before) {
            *why = "远程读回不一致";
            printf("(overlay) 健康检查[%d]：0x%llx 读回不一致\n", attempt, addr);
            fflush(stdout);
            conclusive_bad = true;
            continue;
        }

        printf("(overlay) 健康检查[%d]：远程内存通道 OK（addr=0x%llx value=0x%llx）\n",
               attempt, addr, before);
        fflush(stdout);
        return true;
    }

    if (conclusive_bad) return false;
    printf("(overlay) 健康检查无结论（三次都读不到线程结构），按可用处理，继续建浮层\n");
    fflush(stdout);
    return true;
}

#pragma mark - Build

/* Numbered steps, printed as we go: the last line in lara.log is the last call
   that came back alive. */
static bool ov_build(RemoteCall *proc)
{
    int step = 0;

    /* Point remote_objc's global helpers at lara's live SpringBoard session. */
    arc_use_existing_remote_call((__bridge void *)proc);
    r_settle_us(1500);
    /* 参数缓冲区是全局共享的：开工前留一点时间让上一次调用彻底收尾，
       否则两次远程调用同时在飞会让 malloc 返回垃圾指针 → 目标进程崩溃。 */
    usleep(120 * 1000);

    /* 1/6 — classes. */
    uint64_t clsApplication = r_class("UIApplication");
    uint64_t clsWindow      = r_class("UIWindow");
    uint64_t clsColor       = r_class("UIColor");
    step++;
    ov_status("[%d/6] 类: app=0x%llx win=0x%llx color=0x%llx",
              step, clsApplication, clsWindow, clsColor);
    if (!r_is_objc_ptr(clsApplication) || !r_is_objc_ptr(clsWindow)) return false;

    /* 2/6 — application object. */
    uint64_t app = r_msg2_main(clsApplication, "sharedApplication", 0, 0, 0, 0);
    step++;
    ov_status("[%d/6] sharedApplication=0x%llx", step, app);
    if (!r_is_objc_ptr(app)) return false;

    /* 3/6 — the scene to host the window on. */
    uint64_t scenes = r_msg2_main(app, "connectedScenes", 0, 0, 0, 0);
    uint64_t scene = r_is_objc_ptr(scenes) ? r_msg2_main(scenes, "anyObject", 0, 0, 0, 0) : 0;
    step++;
    ov_status("[%d/6] connectedScenes=0x%llx scene=0x%llx", step, scenes, scene);
    if (!r_is_objc_ptr(scene)) return false;

    /* 4/6 — our own high-level window. Screen geometry is local (see header). */
    CGRect screen = [UIScreen mainScreen].bounds;
    if (screen.size.width < 1.0 || screen.size.height < 1.0) screen = CGRectMake(0, 0, 390, 844);

    uint64_t allocatedWindow = r_msg2_main(clsWindow, "alloc", 0, 0, 0, 0);
    uint64_t window = r_is_objc_ptr(allocatedWindow)
        ? r_msg2_main(allocatedWindow, "initWithWindowScene:", scene, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(window)) {
        step++;
        ov_status("[%d/6] 窗口创建失败 allocated=0x%llx", step, allocatedWindow);
        return false;
    }

    double level = OV_WINDOW_LEVEL;
    r_msg2_main_raw(window, "setWindowLevel:", &level, sizeof(level), NULL, 0, NULL, 0, NULL, 0);
    ov_set_bool(window, "setUserInteractionEnabled:", 0);
    ov_set_bool(window, "setOpaque:", 0);
    if (r_is_objc_ptr(clsColor)) {
        uint64_t clear = r_msg2_main(clsColor, "clearColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(window, "setBackgroundColor:", clear, 0, 0, 0);
    }
    r_msg2_main_raw(window, "setFrame:", &screen, sizeof(screen), NULL, 0, NULL, 0, NULL, 0);
    ov_set_bool(window, "setHidden:", 1);

    /* 5/6 — content: 第一视角网页优先，失败退回时间胶囊。
       frame 按当前方向/全屏/真实分辨率算（见 ov_content_frame）。 */
    gOvWebMode = true;
    CGRect webFrame = ov_content_frame();
    gOvWebMode = false;
    CGRect pillFrame = ov_content_frame();

    uint64_t content = ov_build_web(proc, screen, webFrame);
    if (!r_is_objc_ptr(content)) {
        content = ov_build_pill(screen, pillFrame);
    }
    step++;
    ov_status("[%d/6] content=0x%llx web=%d frame=%.0f,%.0f %.0fx%.0f 触摸穿透=开 url=%s",
              step, content, gOvWebMode ? 1 : 0,
              webFrame.origin.x, webFrame.origin.y, webFrame.size.width, webFrame.size.height, gOvUrl);
    if (!r_is_objc_ptr(content)) return false;

    /* 6/6 — attach, show, verify. */
    r_msg2_main(window, "addSubview:", content, 0, 0, 0);
    ov_set_bool(window, "setHidden:", 0);
    ov_set_bool(content, "setHidden:", 0);

    uint64_t found = r_msg2_main(window, "viewWithTag:", (uint64_t)OV_TAG, 0, 0, 0);
    /* 回读校验：触摸穿透靠的就是这几个值必须是 0，日志里直接写出结果 */
    uint64_t winUI = r_msg2_main(window, "isUserInteractionEnabled", 0, 0, 0, 0);
    uint64_t webUI = r_is_objc_ptr(gOvWeb) ? r_msg2_main(gOvWeb, "isUserInteractionEnabled", 0, 0, 0, 0) : 0;
    step++;
    ov_status("[%d/6] 校验 tag=0x%llx(应为0x%llx) 内容=%s 窗口可交互=%u 网页可交互=%u（都应是 0）",
              step, found, content, gOvWebMode ? "第一视角" : "时间胶囊",
              (unsigned)(winUI & 0xff), (unsigned)(webUI & 0xff));

    gOvWindow = window;
    gOvPid = proc.pid;
    /* 记录当前布局，之后方向/全屏变化时 tick 会自己重排 */
    gOvAppliedLandscape = -1;
    ov_apply_layout();
    return r_is_objc_ptr(found) && found == content;
}

#pragma mark - Public API

bool clock_overlay_start(RemoteCall *proc)
{
    if (!proc) {
        ov_status("RemoteCall 为空：请先在首页初始化远程调用");
        return false;
    }

    pthread_mutex_lock(&gOvLock);

    if (gOvRunning) {
        pthread_mutex_unlock(&gOvLock);
        return true;
    }
    /* 上一次已经把远程会话弄坏了：绝不再自动重试（要重试请按「自检」）。 */
    if (gOvFailed) {
        pthread_mutex_unlock(&gOvLock);
        return false;
    }
    /* 单飞：同一时刻只允许一次构建，避免两次远程调用同时在飞。 */
    if (gOvBuilding) {
        pthread_mutex_unlock(&gOvLock);
        return false;
    }
    gOvBuilding = true;
    pthread_mutex_unlock(&gOvLock);

    /* 动 objc 之前先探一探会话是否健康（不健康就什么都不做，目标进程活着）。 */
    const char *why = "未知原因";
    if (!ov_session_healthy(proc, &why)) {
        pthread_mutex_lock(&gOvLock);
        gOvBuilding = false;
        gOvFailed = true;
        pthread_mutex_unlock(&gOvLock);
        ov_status("已放弃：远程会话不健康（%s）。目标进程未受影响；修好后按「自检」重试。", why);
        return false;
    }

    pthread_mutex_lock(&gOvLock);

    /* Still alive in the same target? Just show it again. */
    uint64_t existing = r_is_objc_ptr(gOvWeb) ? gOvWeb : gOvPill;
    if (gOvPid == proc.pid && r_is_objc_ptr(existing) && r_is_objc_ptr(gOvWindow)) {
        uint64_t found = r_msg2_main(gOvWindow, "viewWithTag:", (uint64_t)OV_TAG, 0, 0, 0);
        if (found == existing) {
            ov_set_bool(gOvWindow, "setHidden:", 0);
            ov_set_bool(existing, "setHidden:", 0);
            gOvRunning = true;
            if (gOvWebMode && strncmp(gOvUrl, gOvUrlLoaded, sizeof(gOvUrl)) != 0) ov_load_url();
            if (!gOvWebMode) { gOvLastText[0] = '\0'; ov_push_text(); }
            ov_start_timer(proc);
            ov_status("复用已有浮层：window=0x%llx content=0x%llx(%s)",
                      gOvWindow, existing, gOvWebMode ? "第一视角" : "时间胶囊");
            gOvBuilding = false;
            pthread_mutex_unlock(&gOvLock);
            return true;
        }
    }

    gOvWindow = 0;
    gOvPill = 0;
    gOvWeb = 0;
    gOvLastText[0] = '\0';
    gOvUrlLoaded[0] = '\0';

    bool attached = ov_build(proc);
    gOvBuilding = false;
    if (!attached) {
        /* ov_build printed the last step it reached. 会话很可能已被破坏 → 上锁不再重试 */
        gOvFailed = true;
        pthread_mutex_unlock(&gOvLock);
        return false;
    }

    gOvRunning = true;
    ov_start_timer(proc);
    ov_status("已显示：%s window=0x%llx content=0x%llx url=%s",
              gOvWebMode ? "第一视角" : "时间胶囊", gOvWindow,
              gOvWebMode ? gOvWeb : gOvPill, gOvUrl);

    pthread_mutex_unlock(&gOvLock);
    return true;
}

bool clock_overlay_failed(void)
{
    return gOvFailed;
}

bool clock_overlay_selftest(RemoteCall *proc)
{
    if (!proc) {
        ov_status("自检失败：RemoteCall 为空");
        return false;
    }

    /* Clean slate, so the numbered steps below tell the whole story. */
    pthread_mutex_lock(&gOvLock);
    gOvRunning = false;
    gOvFailed = false;                 /* 用户显式重试：解开失败闩锁 */
    if (gOvTimer) {
        dispatch_source_cancel(gOvTimer);
        gOvTimer = nil;
    }
    if (r_is_objc_ptr(gOvWeb)) ov_set_bool(gOvWeb, "setHidden:", 1);
    if (r_is_objc_ptr(gOvPill)) ov_set_bool(gOvPill, "setHidden:", 1);
    gOvWindow = 0;
    gOvPill = 0;
    gOvWeb = 0;
    gOvWebMode = false;
    gOvLastText[0] = '\0';
    gOvUrlLoaded[0] = '\0';
    pthread_mutex_unlock(&gOvLock);

    printf("(overlay) === 自检开始 ===\n");
    fflush(stdout);
    return clock_overlay_start(proc);
}

void clock_overlay_stop(RemoteCall *proc)
{
    (void)proc;

    pthread_mutex_lock(&gOvLock);

    gOvRunning = false;
    if (gOvTimer) {
        dispatch_source_cancel(gOvTimer);
        gOvTimer = nil;
    }

    if (r_is_objc_ptr(gOvWeb)) ov_set_bool(gOvWeb, "setHidden:", 1);
    if (r_is_objc_ptr(gOvPill)) ov_set_bool(gOvPill, "setHidden:", 1);
    if (r_is_objc_ptr(gOvWindow)) ov_set_bool(gOvWindow, "setHidden:", 1);
    gOvLastText[0] = '\0';
    ov_status("已隐藏（对象保留，可直接再次开启）");

    pthread_mutex_unlock(&gOvLock);
}

bool clock_overlay_is_running(void)
{
    /* Status flag only: read without the lock so a slow tick can never block
       the caller (a stale read here is harmless). */
    return gOvRunning;
}

const char *clock_overlay_status(void)
{
    return gOvStatus;
}

void clock_overlay_unbind(void)
{
    /* lara is destroying the RemoteCall session; drop the global binding so a
       later start cannot talk to the destroyed object. */
    abandon_remote_call();
}
