//
//  clock_overlay.m
//  lara
//
//  Global floating overlay = 第一视角（FPS）雷达 · 原生绘制版。
//
//  为什么这么写（参考 peace_esp / 准猫&沐辞 的开源绘制版，以及本机的真机日志）：
//   1. 绘制只用**原生 UIView + UILabel**：方框 = layer.borderWidth/borderColor，
//      文字 = UILabel。不用 WKWebView —— 它内部会建 WKContentView/WKScrollView
//      并挂手势识别器，是"覆盖区域吃触摸"和启动崩溃的来源。
//   2. 目标侧调用全部走 remote_objc 的 r_msg2_main* 家族；标量（BOOL/NSInteger/
//      CGFloat/CGRect）一律用 r_msg2_main_raw 按字节传，对象才用 r_msg2_main。
//      （用对象形态传标量时目标侧收到的是垃圾值，setUserInteractionEnabled: 会失效。）
//   3. 几何/投影全部在 lara 侧算好，只把 frame/文本推给目标，尽量减少远程调用。
//   4. 每帧更新会临时把 stdout 接到 /dev/null：远程调用每次都会打印十几行 (rc)/(pac)，
//      30Hz 下足以把日志刷爆；更新完立刻恢复，lara 自己的日志照常。
//
//  数据来源：lara 通过局域网从电脑上的 rr/fpv 服务取 /api/state，压成一行文本后
//  调 clock_overlay_set_snapshot()。不读内存、不读其它进程。
//

#import "clock_overlay.h"
#import "remote_objc.h"
#import "ARCCompat.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <math.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#pragma mark - Tunables

#define OV_TAG                0x1A2B3C4DULL
#define OV_WINDOW_LEVEL       999999.0
#define OV_STATUS_MAX         512
#define OV_URL_MAX            256
#define OV_SNAP_MAX           4096
#define OV_MAX_SLOTS          48
#define OV_DEFAULT_SLOTS      24
#define OV_TICK_HZ            20                      /* 绘制帧率 */
#define OV_TICK_MS            (1000 / OV_TICK_HZ)
#define OV_DEFAULT_FOV        90.0
#define OV_DEFAULT_EYE        1.60
#define OV_PERSON_HEIGHT      1.80                    /* 米 */
#define OV_MIN_BOX_PX         24.0
#define OV_NAME_TEXT_MAX      32

/* 原生绘制用的几何（目标侧坐标） */
typedef struct { double x, y, w, h; } OV_Rect;

#pragma mark - State

static pthread_mutex_t gOvLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t gOvTimer = nil;
static bool gOvRunning = false;
static bool gOvBuilding = false;
static bool gOvFailed = false;
static pid_t gOvPid = 0;

static uint64_t gOvWindow = 0;
static uint64_t gOvBox[OV_MAX_SLOTS];
static uint64_t gOvName[OV_MAX_SLOTS];
static uint64_t gOvDist[OV_MAX_SLOTS];
static uint64_t gOvCrossH = 0, gOvCrossV = 0;
static int gOvSlotsAllocated = 0;

/* 增量建方框用的状态（建窗时只建窗口，方框每帧建一对，见 ov_build_slots_step） */
static int gOvSlotTarget = 0;
static int gOvBuilderStep = 0;
static bool gOvBuildFailed = false;
static bool gOvCrossDone = false;
static uint64_t gOvFont = 0, gOvWhiteColor = 0, gOvRedCGColor = 0, gOvClearColor = 0;
static uint64_t gOvClsView = 0, gOvClsLabel = 0;
static unsigned long gOvCallCount = 0;

/* 每格的上一次下发值：只有真的变了才发远程调用。
   远程调用很贵（每次还打印十几行调试），静止画面下应该几乎不发。 */
typedef struct { bool used; bool hidden; OV_Rect r; int dist; } OV_SlotCache;
static OV_SlotCache gOvCache[OV_MAX_SLOTS];
static bool gOvCacheValid = false;

static char gOvStatus[OV_STATUS_MAX] = "尚未启动";
static char gOvUrl[OV_URL_MAX] = "";
static char gOvSnap[OV_SNAP_MAX] = {0};
static bool gOvSnapFresh = false;

/* 用户配置 */
static int gOvMaxSlots = OV_DEFAULT_SLOTS;
static double gOvFov = OV_DEFAULT_FOV;
static double gOvEye = OV_DEFAULT_EYE;
static int gOvShowNames = 1;
static int gOvShowDist = 1;
static int gOvShowCross = 1;
static double gOvWidthRatio = 0.92;
static double gOvTop = 56.0;
static double gOvHeightRatio = 0.0;
static int gOvLandscape = 1;          /* 默认横屏（用户手选） */
static int gOvFullscreen = 0;

static void ov_status(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gOvStatus, sizeof(gOvStatus), fmt, ap);
    va_end(ap);
    printf("(overlay) %s\n", gOvStatus);
    fflush(stdout);
}

/* 帧内更新期间把 stdout 静音：远程调用每次都打印十几行 (rc)/(pac)，
   30Hz × 几十次调用会把日志刷爆。dup2 到 /dev/null，更新完恢复。 */
static int gOvSavedStdout = -1;
static void ov_log_mute(void)
{
    fflush(stdout);
    if (gOvSavedStdout >= 0) return;
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) return;
    gOvSavedStdout = dup(STDOUT_FILENO);
    dup2(devnull, STDOUT_FILENO);
    close(devnull);
}
static void ov_log_unmute(void)
{
    if (gOvSavedStdout < 0) return;
    fflush(stdout);
    dup2(gOvSavedStdout, STDOUT_FILENO);
    close(gOvSavedStdout);
    gOvSavedStdout = -1;
}

#pragma mark - 远程调用小工具（标量必须按字节传）

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
static void ov_set_double(uint64_t obj, const char *sel, double value)
{
    if (!r_is_objc_ptr(obj)) return;
    double v = value;
    r_msg2_main_raw(obj, sel, &v, sizeof(v), NULL, 0, NULL, 0, NULL, 0);
}
static void ov_set_rect(uint64_t obj, const char *sel, OV_Rect r)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, sel, &r, sizeof(r), NULL, 0, NULL, 0, NULL, 0);
}
static void ov_set_text(uint64_t obj, const char *utf8)
{
    if (!r_is_objc_ptr(obj) || !utf8) return;
    uint64_t str = r_nsstr_retained(utf8);
    if (!r_is_objc_ptr(str)) return;
    r_msg2_main(obj, "setText:", str, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", str, 0, 0, 0, 0, 0, 0, 0);
}

#pragma mark - 会话健康检查

/* 动 objc 之前先确认远程内存通道是好的：读 8 字节 → 原值写回 → 再读，必须一致。
   刻意不看 getpid：r_call_stable 对它有已知的偶发返回 0 特例。
   读不到地址（可能不可映射）不下结论、继续；只有写失败/读回不一致才算坏。 */
static bool ov_session_healthy(RemoteCall *proc, const char **why)
{
    bool conclusive_bad = false;
    for (int attempt = 0; attempt < 3; attempt++) {
        r_settle_us(30000);
        usleep(80 * 1000);

        uint64_t addr = proc.trojanThreadAddr ? proc.trojanThreadAddr : proc.callThreadAddr;
        if (addr < 0x1000ULL) { *why = "拿不到目标线程结构地址"; continue; }

        uint64_t before = [proc remoteRead64From:addr];
        if (before == 0) { *why = "远程读取返回 0（地址可能不可映射）"; continue; }
        if (![proc remote_write64:addr value:before]) { *why = "远程写入失败"; conclusive_bad = true; continue; }
        if ([proc remoteRead64From:addr] != before) { *why = "远程读回不一致"; conclusive_bad = true; continue; }

        printf("(overlay) 健康检查 OK（addr=0x%llx）\n", addr);
        fflush(stdout);
        return true;
    }
    if (conclusive_bad) return false;
    printf("(overlay) 健康检查无结论，按可用处理\n");
    fflush(stdout);
    return true;
}

#pragma mark - 投影

typedef struct { double x, y, z; } OV_Vec3;

static OV_Vec3 ov_sub(OV_Vec3 a, OV_Vec3 b) { OV_Vec3 r = {a.x-b.x, a.y-b.y, a.z-b.z}; return r; }
static double ov_dot(OV_Vec3 a, OV_Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static OV_Vec3 ov_norm(OV_Vec3 a)
{
    double n = sqrt(ov_dot(a, a));
    if (n < 1e-9) { OV_Vec3 z = {0,0,0}; return z; }
    OV_Vec3 r = {a.x/n, a.y/n, a.z/n};
    return r;
}
static OV_Vec3 ov_cross(OV_Vec3 a, OV_Vec3 b)
{
    OV_Vec3 r = {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x};
    return r;
}

/* UE 厘米 -> 渲染世界（米，Z 朝上）：与主程序/网页一致 */
static OV_Vec3 ov_ue_to_world(double x, double y, double z)
{
    OV_Vec3 v = {x * 0.01, -y * 0.01, z * 0.01};
    return v;
}

#pragma mark - 建窗与元素

static void ov_screen_sides(double *longSide, double *shortSide)
{
    CGRect b = [UIScreen mainScreen].bounds;
    double w = b.size.width, h = b.size.height;
    if (w < 1.0 || h < 1.0) { w = 390.0; h = 844.0; }
    *longSide = (w > h) ? w : h;
    *shortSide = (w > h) ? h : w;
}

/* 面板区域：横屏/竖屏 + 全屏/面板 + 宽高比例，全部按真实分辨率算。 */
static void ov_panel_rect(double *px, double *py, double *pw, double *ph)
{
    double L = 0, S = 0;
    ov_screen_sides(&L, &S);
    double W = gOvLandscape ? L : S;
    double H = gOvLandscape ? S : L;

    if (gOvFullscreen) {
        *px = 0; *py = 0; *pw = W; *ph = H;
        return;
    }
    double width = W * gOvWidthRatio;
    if (width < 200.0) width = W * 0.92;
    if (width > W) width = W;
    double height = (gOvHeightRatio > 0.0) ? H * gOvHeightRatio : width * 9.0 / 16.0;
    double maxH = H - gOvTop - 20.0;
    if (height > maxH) height = maxH;
    if (height < 60.0) height = 60.0;
    *px = (W - width) / 2.0;
    *py = gOvTop;
    *pw = width;
    *ph = height;
}

static uint64_t ov_make_view(uint64_t clsUIView, uint64_t clearColor, double borderWidth,
                             uint64_t borderColor, OV_Rect frame, bool trace)
{
    uint64_t alloc = r_msg2_main(clsUIView, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) { if (trace) printf("(overlay)   alloc 失败 0x%llx\n", alloc); return 0; }
    uint64_t v = r_msg2_main(alloc, "init", 0, 0, 0, 0);
    if (!r_is_objc_ptr(v)) { if (trace) printf("(overlay)   init 失败 0x%llx\n", v); return 0; }
    if (trace) printf("(overlay)   view=0x%llx\n", v);
    if (r_is_objc_ptr(clearColor)) r_msg2_main(v, "setBackgroundColor:", clearColor, 0, 0, 0);
    if (borderWidth > 0.0) {
        uint64_t ly = r_msg2_main(v, "layer", 0, 0, 0, 0);
        if (trace) printf("(overlay)   layer=0x%llx border=0x%llx\n", ly, borderColor);
        if (r_is_objc_ptr(ly)) {
            ov_set_double(ly, "setBorderWidth:", borderWidth);
            /* borderColor 必须是 CGColorRef（CFTypeRef），传 UIColor 会让目标 trap */
            if (r_is_objc_ptr(borderColor)) r_msg2_main(ly, "setBorderColor:", borderColor, 0, 0, 0);
        }
    }
    /* 标量一律走对象形态（与 peace_esp 一致，真机验证过；raw 形态在部分调用上会崩） */
    r_msg2_main(v, "setHidden:", 1, 0, 0, 0);
    ov_set_rect(v, "setFrame:", frame);
    return v;
}

static uint64_t ov_make_label(uint64_t clsUILabel, uint64_t font, uint64_t textColor,
                              uint64_t clearColor, int align, OV_Rect frame, bool trace)
{
    uint64_t alloc = r_msg2_main(clsUILabel, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) { if (trace) printf("(overlay)   label alloc 失败 0x%llx\n", alloc); return 0; }
    uint64_t lb = r_msg2_main(alloc, "init", 0, 0, 0, 0);
    if (!r_is_objc_ptr(lb)) { if (trace) printf("(overlay)   label init 失败 0x%llx\n", lb); return 0; }
    if (trace) printf("(overlay)   label=0x%llx font=0x%llx color=0x%llx\n", lb, font, textColor);
    if (r_is_objc_ptr(font)) r_msg2_main(lb, "setFont:", font, 0, 0, 0);
    if (r_is_objc_ptr(textColor)) r_msg2_main(lb, "setTextColor:", textColor, 0, 0, 0);
    if (r_is_objc_ptr(clearColor)) r_msg2_main(lb, "setBackgroundColor:", clearColor, 0, 0, 0);
    r_msg2_main(lb, "setTextAlignment:", (uint64_t)align, 0, 0, 0);
    r_msg2_main(lb, "setNumberOfLines:", 1, 0, 0, 0);
    r_msg2_main(lb, "setHidden:", 1, 0, 0, 0);
    ov_set_rect(lb, "setFrame:", frame);
    return lb;
}

/* 建整层：窗口 + 方框/名字/距离格子 + 准星。 */
static bool ov_build(RemoteCall *proc)
{
    int step = 0;
    arc_use_existing_remote_call((__bridge void *)proc);
    r_settle_us(1500);
    usleep(120 * 1000);          /* 让上一次调用彻底收尾，避免参数缓冲区交错 */

    uint64_t clsApp   = r_class("UIApplication");
    uint64_t clsWin   = r_class("UIWindow");
    uint64_t clsColor = r_class("UIColor");
    uint64_t clsView  = r_class("UIView");
    uint64_t clsLabel = r_class("UILabel");
    uint64_t clsFont  = r_class("UIFont");
    step++;
    ov_status("[%d/6] 类: app=0x%llx win=0x%llx view=0x%llx label=0x%llx",
              step, clsApp, clsWin, clsView, clsLabel);
    if (!r_is_objc_ptr(clsApp) || !r_is_objc_ptr(clsWin) ||
        !r_is_objc_ptr(clsView) || !r_is_objc_ptr(clsLabel)) return false;

    uint64_t app = r_msg2_main(clsApp, "sharedApplication", 0, 0, 0, 0);
    step++;
    ov_status("[%d/6] sharedApplication=0x%llx", step, app);
    if (!r_is_objc_ptr(app)) return false;

    uint64_t scenes = r_msg2_main(app, "connectedScenes", 0, 0, 0, 0);
    uint64_t scene = r_is_objc_ptr(scenes) ? r_msg2_main(scenes, "anyObject", 0, 0, 0, 0) : 0;
    step++;
    ov_status("[%d/6] scene=0x%llx", step, scene);
    if (!r_is_objc_ptr(scene)) return false;

    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    OV_Rect full = {0, 0, pw + px * 2.0, ph + py * 2.0};   /* 覆盖整屏（按所选方向） */
    if (gOvFullscreen) { full.x = 0; full.y = 0; full.w = pw; full.h = ph; }

    uint64_t win = r_msg2_main(r_msg2_main(clsWin, "alloc", 0, 0, 0, 0), "initWithWindowScene:", scene, 0, 0, 0);
    if (!r_is_objc_ptr(win)) { step++; ov_status("[%d/6] 窗口创建失败", step); return false; }
    ov_set_double(win, "setWindowLevel:", OV_WINDOW_LEVEL);
    ov_set_bool(win, "setUserInteractionEnabled:", 0);      /* 触摸穿透第一道 */
    ov_set_bool(win, "setOpaque:", 0);
    ov_set_rect(win, "setFrame:", full);
    ov_set_int(win, "setTag:", (long long)OV_TAG);
    uint64_t clear = r_is_objc_ptr(clsColor) ? r_msg2_main(clsColor, "clearColor", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0, 0, 0);
    ov_set_bool(win, "setHidden:", 1);
    step++;
    ov_status("[%d/6] window=0x%llx 面板=%.0f,%.0f %.0fx%.0f 方向=%s%s",
              step, win, px, py, pw, ph, gOvLandscape ? "横屏" : "竖屏", gOvFullscreen ? " 全屏" : "");

    /* 字体/颜色 */
    uint64_t font = 0;
    if (r_is_objc_ptr(clsFont)) {
        double fs = 11.0, wt = 0.6;
        font = r_msg2_main_raw(clsFont, "systemFontOfSize:weight:",
                               &fs, sizeof(fs), &wt, sizeof(wt), NULL, 0, NULL, 0);
        if (!r_is_objc_ptr(font)) {
            font = r_msg2_main_raw(clsFont, "systemFontOfSize:", &fs, sizeof(fs), NULL, 0, NULL, 0, NULL, 0);
        }
    }
    uint64_t white = 0, red = 0, blue = 0, orange = 0;
    uint64_t whiteCG = 0, redCG = 0;
    if (r_is_objc_ptr(clsColor)) {
        white  = r_msg2_main(clsColor, "whiteColor", 0, 0, 0, 0);
        red    = r_msg2_main(clsColor, "systemRedColor", 0, 0, 0, 0);
        blue   = r_msg2_main(clsColor, "systemBlueColor", 0, 0, 0, 0);
        orange = r_msg2_main(clsColor, "systemOrangeColor", 0, 0, 0, 0);
        /* layer.borderColor 要的是 CGColor（CFTypeRef）：直接传 UIColor 会把目标弄崩 */
        if (r_is_objc_ptr(white)) whiteCG = r_msg2_main(white, "CGColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(red))   redCG   = r_msg2_main(red, "CGColor", 0, 0, 0, 0);
    }
    (void)blue; (void)orange;

    /* 方框 + 距离文字：改成「增量创建」。
       真机日志显示：连续密集远程调用到 ~19 次时目标进程就会崩，
       一次性建 24 对必崩。所以建窗时一个都不建，之后每帧只建一对，
       失败也只丢那一格，不会整体失败。字体/颜色缓存起来给后续帧用。 */
    int slots = gOvMaxSlots;
    if (slots < 1) slots = 1;
    if (slots > OV_MAX_SLOTS) slots = OV_MAX_SLOTS;
    gOvSlotTarget   = slots;
    gOvBuilderStep  = 0;
    gOvBuildFailed  = false;
    gOvCrossDone    = false;
    gOvFont         = font;
    gOvWhiteColor   = white;
    gOvRedCGColor   = redCG;
    gOvClearColor   = clear;
    gOvClsView      = clsView;
    gOvClsLabel     = clsLabel;
    gOvSlotsAllocated = 0;
    ov_status("[5/6] 窗口已就绪；方框改为增量创建（每帧 1 对，共 %d 对）", slots);

    ov_set_bool(win, "setHidden:", 0);
    if (r_responds(win, "resignKeyWindow")) r_msg2_main(win, "resignKeyWindow", 0, 0, 0, 0);

    uint64_t found = r_msg2_main(win, "viewWithTag:", (uint64_t)OV_TAG, 0, 0, 0);
    uint64_t winUI = r_msg2_main(win, "isUserInteractionEnabled", 0, 0, 0, 0);
    uint64_t winKey = r_msg2_main(win, "isKeyWindow", 0, 0, 0, 0);
    step++;
    ov_status("[%d/6] 就绪 tag=0x%llx(应为0x%llx) 格子=%d 窗口可交互=%u key=%u（都应是 0）",
              step, found, win, slots, (unsigned)(winUI & 0xff), (unsigned)(winKey & 0xff));

    gOvWindow = win;
    gOvPid = proc.pid;
    gOvCacheValid = false;          /* 新窗口：第一帧全部重发 */
    return r_is_objc_ptr(found) && found == win;
}

/* 增量建格子：每个 tick 只建一对（方框 + 距离文字），建完再建准星。
   这样每次只有 5~6 次远程调用，既避免把目标进程压崩，失败也只丢一格。 */
static void ov_build_slots_step(void)
{
    if (!r_is_objc_ptr(gOvWindow)) return;

    if (gOvBuilderStep < gOvSlotTarget) {
        int i = gOvBuilderStep;
        OV_Rect r0 = {0, 0, 0, 0};
        uint64_t box = ov_make_view(gOvClsView, gOvClearColor, 2.0, gOvRedCGColor, r0, i == 0);
        if (!r_is_objc_ptr(box)) {
            gOvBuildFailed = true;
            ov_status("[5/6] 第 %d 个方框创建失败（box=0x%llx，已用调用 %lu 次）", i, box, gOvCallCount);
            return;
        }
        r_msg2_main(gOvWindow, "addSubview:", box, 0, 0, 0);
        gOvBox[i] = box;

        OV_Rect r2 = {0, 0, 0, 0};
        uint64_t ds = ov_make_label(gOvClsLabel, gOvFont, gOvWhiteColor, gOvClearColor, 1, r2, i == 0);
        if (!r_is_objc_ptr(ds)) {
            gOvBuildFailed = true;
            ov_status("[5/6] 第 %d 个文字创建失败（label=0x%llx，已用调用 %lu 次）", i, ds, gOvCallCount);
            return;
        }
        r_msg2_main(gOvWindow, "addSubview:", ds, 0, 0, 0);
        gOvDist[i] = ds;
        gOvName[i] = 0;
        gOvCallCount += 6;

        gOvSlotsAllocated = i + 1;
        gOvBuilderStep = i + 1;
        if (gOvBuilderStep == 1 || gOvBuilderStep == gOvSlotTarget || gOvBuilderStep % 8 == 0) {
            ov_status("[5/6] 格子进度 %d/%d（累计远程调用约 %lu 次）",
                      gOvBuilderStep, gOvSlotTarget, gOvCallCount);
        }
        return;
    }

    if (!gOvCrossDone) {
        gOvCrossDone = true;
        double px = 0, py = 0, pw = 0, ph = 0;
        ov_panel_rect(&px, &py, &pw, &ph);
        double cx = pw / 2.0, cy = ph / 2.0;
        OV_Rect h = {cx - 9.0, cy - 0.75, 18.0, 1.5};
        OV_Rect v = {cx - 0.75, cy - 9.0, 1.5, 18.0};
        gOvCrossH = ov_make_view(gOvClsView, gOvWhiteColor, 0.0, 0, h, false);
        gOvCrossV = ov_make_view(gOvClsView, gOvWhiteColor, 0.0, 0, v, false);
        if (r_is_objc_ptr(gOvCrossH)) r_msg2_main(gOvWindow, "addSubview:", gOvCrossH, 0, 0, 0);
        if (r_is_objc_ptr(gOvCrossV)) r_msg2_main(gOvWindow, "addSubview:", gOvCrossV, 0, 0, 0);
        if (r_is_objc_ptr(gOvCrossH)) r_msg2_main(gOvCrossH, "setHidden:", gOvShowCross ? 0 : 1, 0, 0, 0);
        if (r_is_objc_ptr(gOvCrossV)) r_msg2_main(gOvCrossV, "setHidden:", gOvShowCross ? 0 : 1, 0, 0, 0);
        ov_status("[5/6] 全部 %d 格 + 准星就绪（累计远程调用约 %lu 次）", gOvSlotsAllocated, gOvCallCount);
    }
}

#pragma mark - 每帧绘制

/* 解析一行快照并更新方框。返回画出来的方框数。
   带脏检查：frame/隐藏状态/距离数字与上次相同就完全不发远程调用。 */
static int ov_draw_snapshot(void)
{
    if (!r_is_objc_ptr(gOvWindow) || !gOvSnapFresh || !gOvSnap[0]) {
        if (gOvCacheValid) {
            for (int i = 0; i < gOvSlotsAllocated; i++) {
                if (!gOvCache[i].hidden) {
                    if (r_is_objc_ptr(gOvBox[i])) ov_set_bool(gOvBox[i], "setHidden:", 1);
                    if (r_is_objc_ptr(gOvDist[i])) ov_set_bool(gOvDist[i], "setHidden:", 1);
                    gOvCache[i].hidden = true;
                }
            }
        }
        return 0;
    }

    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    if (pw < 8.0 || ph < 8.0) return 0;

    /* 自己 */
    char *p = gOvSnap;
    double sx = 0, sy = 0, sz = 0, yaw = 0, pitch = 0;
    if (sscanf(p, "%lf,%lf,%lf,%lf,%lf", &sx, &sy, &sz, &yaw, &pitch) != 5) return 0;
    OV_Vec3 cam = ov_ue_to_world(sx, sy, sz);
    cam.z += gOvEye;

    double yr = -yaw * M_PI / 180.0;
    double pr = pitch * M_PI / 180.0;
    if (pr > 1.55) pr = 1.55;
    if (pr < -1.55) pr = -1.55;
    OV_Vec3 fwd = {cos(yr) * cos(pr), sin(yr) * cos(pr), sin(pr)};
    OV_Vec3 up0 = {0, 0, 1};
    OV_Vec3 right = ov_norm(ov_cross(fwd, up0));
    OV_Vec3 up = ov_cross(right, fwd);

    double tanHalfY = tan(gOvFov * M_PI / 360.0);
    double aspect = pw / ph;

    char *semi = strchr(gOvSnap, ';');
    if (!semi) return 0;
    p = semi + 1;

    static bool used[OV_MAX_SLOTS];
    memset(used, 0, sizeof(used));

    int drawn = 0;
    char *save = NULL;
    for (char *tok = strtok_r(p, ";", &save); tok && drawn < gOvSlotsAllocated; tok = strtok_r(NULL, ";", &save)) {
        double ex = 0, ey = 0, ez = 0;
        int kind = 0;
        if (sscanf(tok, "%lf,%lf,%lf,%d", &ex, &ey, &ez, &kind) != 4) continue;
        OV_Vec3 w = ov_ue_to_world(ex, ey, ez);
        w.z += OV_PERSON_HEIGHT * 0.5;

        OV_Vec3 d = ov_sub(w, cam);
        double depth = ov_dot(d, fwd);
        if (depth < 0.5) continue;
        double rx = ov_dot(d, right) / depth;
        double ry = ov_dot(d, up) / depth;
        if (fabs(rx) > tanHalfY * aspect * 1.6 || fabs(ry) > tanHalfY * 1.6) continue;

        double cx = pw / 2.0 + rx * (pw / 2.0) / tanHalfY;
        double cy = ph / 2.0 - ry * (ph / 2.0) / tanHalfY;

        double boxH = OV_PERSON_HEIGHT / depth * (ph / 2.0) / tanHalfY;
        if (boxH < OV_MIN_BOX_PX) boxH = OV_MIN_BOX_PX;
        double boxW = boxH * 0.52;

        int i = drawn++;
        used[i] = true;
        OV_Rect box = {cx - boxW / 2.0, cy - boxH / 2.0, boxW, boxH};
        int distM = (int)(depth + 0.5);

        OV_SlotCache *c = &gOvCache[i];
        bool need = !gOvCacheValid || c->hidden || !c->used
                    || fabs(c->r.x - box.x) > 0.5 || fabs(c->r.y - box.y) > 0.5
                    || fabs(c->r.w - box.w) > 0.5 || fabs(c->r.h - box.h) > 0.5
                    || c->dist != distM;
        if (need) {
            if (!gOvCacheValid || c->hidden || !c->used || fabs(c->r.x - box.x) > 0.5
                || fabs(c->r.y - box.y) > 0.5 || fabs(c->r.w - box.w) > 0.5
                || fabs(c->r.h - box.h) > 0.5) {
                ov_set_rect(gOvBox[i], "setFrame:", box);
                ov_set_bool(gOvBox[i], "setHidden:", 0);
                if (r_is_objc_ptr(gOvDist[i])) {
                    OV_Rect dl = {cx - 40.0, cy + boxH / 2.0 + 2.0, 80.0, 14.0};
                    ov_set_rect(gOvDist[i], "setFrame:", dl);
                    ov_set_bool(gOvDist[i], "setHidden:", gOvShowDist ? 0 : 1);
                }
            }
            if (!gOvCacheValid || c->dist != distM) {
                char buf[OV_NAME_TEXT_MAX];
                snprintf(buf, sizeof(buf), "%dm", distM);
                ov_set_text(gOvDist[i], buf);
            }
            c->used = true; c->hidden = false; c->r = box; c->dist = distM;
        }
    }

    for (int i = drawn; i < gOvSlotsAllocated; i++) {
        OV_SlotCache *c = &gOvCache[i];
        if (gOvCacheValid && (c->hidden || !c->used)) continue;
        if (r_is_objc_ptr(gOvBox[i])) ov_set_bool(gOvBox[i], "setHidden:", 1);
        if (r_is_objc_ptr(gOvDist[i])) ov_set_bool(gOvDist[i], "setHidden:", 1);
        c->hidden = true; c->used = false;
    }
    gOvCacheValid = true;
    return drawn;
}

static void ov_tick(void)
{
    pthread_mutex_lock(&gOvLock);
    if (!gOvRunning) { pthread_mutex_unlock(&gOvLock); return; }

    ov_log_mute();                 /* 帧内静音，避免 (rc)/(pac) 刷爆日志 */
    /* 先增量把方框/准星建起来（每帧一对），再画这一帧 */
    if (!gOvBuildFailed && !(gOvBuilderStep >= gOvSlotTarget && gOvCrossDone)) {
        ov_log_unmute();           /* 建格子阶段要留日志，方便定位崩在哪 */
        ov_build_slots_step();
        ov_log_mute();
    }
    int drawn = ov_draw_snapshot();
    ov_log_unmute();

    static unsigned tick = 0;
    if (++tick % (OV_TICK_HZ * 5) == 0) {          /* 每 5 秒一行摘要 */
        printf("(overlay) 绘制中：方框 %d 个，快照%s，状态：%s\n",
               drawn, gOvSnapFresh ? "有" : "无", gOvStatus);
        fflush(stdout);
    }
    pthread_mutex_unlock(&gOvLock);
}

static void ov_start_timer(RemoteCall *proc)
{
    if (gOvTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!t) { printf("(overlay) 定时器创建失败\n"); fflush(stdout); return; }
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                              OV_TICK_MS * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ ov_tick(); });
    gOvTimer = t;
    dispatch_resume(gOvTimer);
    (void)proc;
}

#pragma mark - Public API

void clock_overlay_set_view(int maxSlots, double fovDeg, double eyeHeight,
                            int showNames, int showDist, int showCross)
{
    pthread_mutex_lock(&gOvLock);
    if (maxSlots > 0) gOvMaxSlots = (maxSlots > OV_MAX_SLOTS) ? OV_MAX_SLOTS : maxSlots;
    if (fovDeg >= 40.0 && fovDeg <= 130.0) gOvFov = fovDeg;
    if (eyeHeight >= 0.2 && eyeHeight <= 3.0) gOvEye = eyeHeight;
    gOvShowNames = showNames ? 1 : 0;
    gOvShowDist = showDist ? 1 : 0;
    gOvShowCross = showCross ? 1 : 0;
    gOvCacheValid = false;          /* 画面参数变了：下一帧重发 */
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_geometry(double widthRatio, double topMargin)
{
    pthread_mutex_lock(&gOvLock);
    gOvWidthRatio = (widthRatio >= 0.2 && widthRatio <= 1.0) ? widthRatio : 0.92;
    gOvTop = (topMargin >= 0.0 && topMargin <= 600.0) ? topMargin : 56.0;
    gOvCacheValid = false;
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_height_ratio(double heightRatio)
{
    pthread_mutex_lock(&gOvLock);
    gOvHeightRatio = (heightRatio >= 0.1 && heightRatio <= 1.0) ? heightRatio : 0.0;
    gOvCacheValid = false;
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_layout(int landscape, int fullscreen)
{
    pthread_mutex_lock(&gOvLock);
    gOvLandscape = landscape ? 1 : 0;
    gOvFullscreen = fullscreen ? 1 : 0;
    gOvCacheValid = false;
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_snapshot(const char *compact)
{
    pthread_mutex_lock(&gOvLock);
    if (!compact || !compact[0]) {
        gOvSnap[0] = '\0';
        gOvSnapFresh = false;
    } else {
        strncpy(gOvSnap, compact, sizeof(gOvSnap) - 1);
        gOvSnap[sizeof(gOvSnap) - 1] = '\0';
        gOvSnapFresh = true;
    }
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_set_url(const char *url)
{
    pthread_mutex_lock(&gOvLock);
    if (!url) gOvUrl[0] = '\0';
    else { strncpy(gOvUrl, url, sizeof(gOvUrl) - 1); gOvUrl[sizeof(gOvUrl) - 1] = '\0'; }
    pthread_mutex_unlock(&gOvLock);
}

const char *clock_overlay_url(void) { return gOvUrl; }
const char *clock_overlay_status(void) { return gOvStatus; }
bool clock_overlay_is_running(void) { return gOvRunning; }
bool clock_overlay_failed(void) { return gOvFailed; }

bool clock_overlay_start(RemoteCall *proc)
{
    if (!proc) { ov_status("RemoteCall 为空：请先在首页初始化远程调用"); return false; }

    pthread_mutex_lock(&gOvLock);
    if (gOvRunning) { pthread_mutex_unlock(&gOvLock); return true; }
    if (gOvFailed) { pthread_mutex_unlock(&gOvLock); return false; }   /* 失败闩锁，需自检解开 */
    if (gOvBuilding) { pthread_mutex_unlock(&gOvLock); return false; } /* 单飞 */
    gOvBuilding = true;
    pthread_mutex_unlock(&gOvLock);

    const char *why = "未知";
    if (!ov_session_healthy(proc, &why)) {
        pthread_mutex_lock(&gOvLock);
        gOvBuilding = false; gOvFailed = true;
        pthread_mutex_unlock(&gOvLock);
        ov_status("已放弃：远程会话不健康（%s）", why);
        return false;
    }

    /* 已有对象就直接显示回来 */
    if (gOvPid == proc.pid && r_is_objc_ptr(gOvWindow)) {
        uint64_t found = r_msg2_main(gOvWindow, "viewWithTag:", (uint64_t)OV_TAG, 0, 0, 0);
        if (found == gOvWindow) {
            pthread_mutex_lock(&gOvLock);
            ov_set_bool(gOvWindow, "setHidden:", 0);
            gOvRunning = true; gOvBuilding = false;
            ov_start_timer(proc);
            pthread_mutex_unlock(&gOvLock);
            ov_status("复用已有浮层：window=0x%llx", gOvWindow);
            return true;
        }
    }

    gOvWindow = 0;
    for (int i = 0; i < OV_MAX_SLOTS; i++) { gOvBox[i] = gOvName[i] = gOvDist[i] = 0; }
    gOvSlotsAllocated = 0;

    pthread_mutex_lock(&gOvLock);
    bool ok = ov_build(proc);
    gOvBuilding = false;
    if (!ok) gOvFailed = true;
    if (ok) { gOvRunning = true; ov_start_timer(proc); }
    pthread_mutex_unlock(&gOvLock);
    return ok;
}

bool clock_overlay_selftest(RemoteCall *proc)
{
    if (!proc) { ov_status("自检失败：RemoteCall 为空"); return false; }

    pthread_mutex_lock(&gOvLock);
    gOvRunning = false;
    gOvFailed = false;                       /* 用户显式重试：解开失败闩锁 */
    if (gOvTimer) { dispatch_source_cancel(gOvTimer); gOvTimer = nil; }
    if (r_is_objc_ptr(gOvWindow)) ov_set_bool(gOvWindow, "setHidden:", 1);
    gOvWindow = 0;
    for (int i = 0; i < OV_MAX_SLOTS; i++) { gOvBox[i] = gOvName[i] = gOvDist[i] = 0; }
    gOvCrossH = gOvCrossV = 0;
    gOvSlotsAllocated = 0;
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
    if (gOvTimer) { dispatch_source_cancel(gOvTimer); gOvTimer = nil; }
    if (r_is_objc_ptr(gOvWindow)) ov_set_bool(gOvWindow, "setHidden:", 1);
    ov_status("已隐藏（对象保留，可直接再次开启）");
    pthread_mutex_unlock(&gOvLock);
}

void clock_overlay_unbind(void)
{
    abandon_remote_call();
}
