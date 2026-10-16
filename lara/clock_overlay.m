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
#import <time.h>
#import <unistd.h>

#pragma mark - Tunables

#define OV_TAG                0x1A2B3C4DULL
#define OV_WINDOW_LEVEL       999999.0
#define OV_STATUS_MAX         512
#define OV_URL_MAX            256
#define OV_SNAP_MAX           4096
#define OV_MAX_SLOTS          48
#define OV_DEFAULT_SLOTS      24
#define OV_TICK_HZ            10                      /* 绘制帧率（每次远程调用都较贵，10Hz 足够顺滑） */
#define OV_TICK_MS            (1000 / OV_TICK_HZ)
#define OV_DEFAULT_FOV        90.0
#define OV_DEFAULT_EYE        1.60
#define OV_PERSON_HEIGHT      1.80                    /* 米 */
#define OV_MIN_BOX_PX         24.0
#define OV_PANEL_MIN_VISIBLE  60.0                    /* 裁剪区至少留这么多高度在屏内 */
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
static uint64_t gOvClip = 0;                     /* 裁剪容器：方框/文字画在里面（限制可见区域） */
static uint64_t gOvBox[OV_MAX_SLOTS];
static uint64_t gOvName[OV_MAX_SLOTS];
static uint64_t gOvDist[OV_MAX_SLOTS];
static uint64_t gOvCrossH = 0, gOvCrossV = 0;    /* 准星：直接挂在窗口上，钉在屏幕正中，不裁剪 */
static int gOvSlotsAllocated = 0;
static double gOvClipX = -1, gOvClipY = -1, gOvClipW = -1, gOvClipH = -1;   /* 裁剪容器当前位置 */
static double gOvCrossCx = -1, gOvCrossCy = -1;                             /* 准星当前位置 */

/* 增量建方框用的状态（建窗时只建窗口，方框每帧建一对，见 ov_build_slots_step） */
static int gOvSlotTarget = 0;
static int gOvBuilderStep = 0;
static bool gOvBuildFailed = false;
static bool gOvCrossDone = false;
static uint64_t gOvFont = 0, gOvWhiteColor = 0, gOvRedCGColor = 0, gOvClearColor = 0;
static uint64_t gOvClsView = 0, gOvClsLabel = 0;
static unsigned long gOvCallCount = 0;

/* 诊断样本：最近一次投影结果（只用于 5 秒一次的日志，方便定位"位置不对"） */
static double gOvLastCx = 0, gOvLastCy = 0, gOvLastDepth = 0;
static double gOvLastSelf[3] = {0, 0, 0};
static double gOvLastYaw = 0, gOvLastPitch = 0;

/* 前置声明：ov_build 里会带节奏地循环调用它，定义在文件后半部分 */
static void ov_build_slots_step(void);

/* 每格的上一次下发值：只有真的变了才发远程调用。
   远程调用很贵（每次还打印十几行调试），静止画面下应该几乎不发。 */
typedef struct { bool used; bool hidden; bool distHidden; OV_Rect r; int dist; } OV_SlotCache;
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

/* 静音期间保留的真实日志 fd：ov_log_mute 期间 ov_status 仍能写出去，
   保证建层进度可见（被静音的只是远程调用那堆 (rc)/(pac) 刷屏）。 */
static int gOvLogFd = -1;

static void ov_status(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gOvStatus, sizeof(gOvStatus), fmt, ap);
    va_end(ap);
    if (gOvLogFd >= 0) {
        dprintf(gOvLogFd, "(overlay) %s\n", gOvStatus);
    } else {
        printf("(overlay) %s\n", gOvStatus);
        fflush(stdout);
    }
}

/* 帧内更新期间把 stdout 静音：远程调用每次都打印十几行 (rc)/(pac)，
   30Hz × 几十次调用会把日志刷爆（Logger 逐块 fsync，管道写满后 printf 会直接阻塞）。
   dup2 到 /dev/null，更新完恢复；期间保留一个真实 fd 给 ov_status。 */
static int gOvSavedStdout = -1;
static int gOvSavedStderr = -1;
static void ov_log_mute(void)
{
    fflush(stdout);
    fflush(stderr);
    if (gOvSavedStdout >= 0) return;
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) return;
    gOvSavedStdout = dup(STDOUT_FILENO);
    gOvSavedStderr = dup(STDERR_FILENO);
    if (gOvLogFd < 0) gOvLogFd = dup(STDOUT_FILENO);
    dup2(devnull, STDOUT_FILENO);
    dup2(devnull, STDERR_FILENO);       /* NSLog 走 stderr，同样要静音 */
    close(devnull);
}
static void ov_log_unmute(void)
{
    if (gOvSavedStdout < 0) return;
    fflush(stdout);
    fflush(stderr);
    dup2(gOvSavedStdout, STDOUT_FILENO);
    close(gOvSavedStdout);
    gOvSavedStdout = -1;
    if (gOvSavedStderr >= 0) {
        dup2(gOvSavedStderr, STDERR_FILENO);
        close(gOvSavedStderr);
        gOvSavedStderr = -1;
    }
    if (gOvLogFd >= 0) { close(gOvLogFd); gOvLogFd = -1; }
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

/* 所选方向下的整屏尺寸（点）。投影 1:1 用整屏，裁剪区才用 ov_panel_rect。 */
static void ov_screen_wh(double *W, double *H)
{
    double L = 0, S = 0;
    ov_screen_sides(&L, &S);
    *W = gOvLandscape ? L : S;
    *H = gOvLandscape ? S : L;
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
    /* 顶边必须留在屏内（至少留 OV_PANEL_MIN_VISIBLE 可见）：
       否则把「顶部距离」拉到屏幕高度以外，整层会被裁到屏幕外，什么都看不到。 */
    double top = gOvTop;
    double maxTop = H - OV_PANEL_MIN_VISIBLE;
    if (maxTop < 0) maxTop = 0;
    if (top > maxTop) top = maxTop;
    if (top < 0) top = 0;
    double height = (gOvHeightRatio > 0.0) ? H * gOvHeightRatio : width * 9.0 / 16.0;
    double maxH = H - top - 20.0;
    if (height > maxH) height = maxH;
    if (height < OV_PANEL_MIN_VISIBLE) height = OV_PANEL_MIN_VISIBLE;
    *px = (W - width) / 2.0;
    *py = top;
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

    double sw = 0, sh = 0;
    ov_screen_wh(&sw, &sh);
    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    if (gOvFullscreen) { px = 0; py = 0; pw = sw; ph = sh; }
    OV_Rect full = {0, 0, sw, sh};    /* 窗口铺满整屏：投影按整屏 1:1，方框可落在任意处 */

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

    /* 裁剪容器：方框/文字画在里面，用「宽度/顶部/高度」限制可见区域；
       投影和准星不受它影响（都锚定屏幕正中，和游戏 1:1）。 */
    gOvClipX = px; gOvClipY = py; gOvClipW = pw; gOvClipH = ph;
    gOvClip = ov_make_view(clsView, clear, 0.0, 0, (OV_Rect){px, py, pw, ph}, false);
    if (r_is_objc_ptr(gOvClip)) {
        ov_set_bool(gOvClip, "setClipsToBounds:", 1);
        r_msg2_main(win, "addSubview:", gOvClip, 0, 0, 0);
    }

    step++;
    ov_status("[%d/6] window=0x%llx 投影=整屏%.0fx%.0f 裁剪区=%.0f,%.0f %.0fx%.0f 方向=%s%s",
              step, win, sw, sh, px, py, pw, ph, gOvLandscape ? "横屏" : "竖屏", gOvFullscreen ? " 全屏" : "");

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
    ov_status("[5/6] 窗口已就绪；先建准星，再建 %d 个方框（每步之间 20ms，避免压崩目标）", slots);

    /* 每步只有 5~6 次远程调用（连续密集调用到 ~19 次目标就会崩）。
       第一步建准星（立刻可见），其后 %d 步每步建一对（方框+距离文字）。
       带节奏地建，约 0.5~0.8 秒就在前台期间全部建好。 */
    for (int i = 0; i <= slots && !gOvBuildFailed; i++) {
        ov_build_slots_step();
        if (!gOvBuildFailed) usleep(20 * 1000);
    }

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

/* 增量建层：**先建准星**，再一格一格建方框+文字。
   准星钉在屏幕正中、不裁剪，所以哪怕建方框的过程被打断（切到游戏后 lara 被挂起），
   画面上也一定先有一个准星可见；方框按 20ms 一格慢慢补，避免把目标进程压崩。 */
static void ov_build_slots_step(void)
{
    if (!r_is_objc_ptr(gOvWindow)) return;

    if (!gOvCrossDone) {
        double sw = 0, sh = 0;
        ov_screen_wh(&sw, &sh);
        double cx = sw / 2.0, cy = sh / 2.0;               /* 准星钉在屏幕正中（和游戏准星重合） */
        OV_Rect h = {cx - 9.0, cy - 0.75, 18.0, 1.5};
        OV_Rect v = {cx - 0.75, cy - 9.0, 1.5, 18.0};
        gOvCrossH = ov_make_view(gOvClsView, gOvWhiteColor, 0.0, 0, h, false);
        gOvCrossV = ov_make_view(gOvClsView, gOvWhiteColor, 0.0, 0, v, false);
        if (!r_is_objc_ptr(gOvCrossH) || !r_is_objc_ptr(gOvCrossV)) {
            gOvBuildFailed = true;
            ov_status("[5/6] 准星创建失败（h=0x%llx v=0x%llx，已用调用 %lu 次）",
                      gOvCrossH, gOvCrossV, gOvCallCount);
            return;
        }
        r_msg2_main(gOvWindow, "addSubview:", gOvCrossH, 0, 0, 0);
        r_msg2_main(gOvWindow, "addSubview:", gOvCrossV, 0, 0, 0);
        r_msg2_main(gOvCrossH, "setHidden:", gOvShowCross ? 0 : 1, 0, 0, 0);
        r_msg2_main(gOvCrossV, "setHidden:", gOvShowCross ? 0 : 1, 0, 0, 0);
        gOvCrossCx = cx; gOvCrossCy = cy;
        gOvCrossDone = true;
        ov_status("[5/6] 准星就绪：屏幕正中 %.0f,%.0f（累计远程调用约 %lu 次）", cx, cy, gOvCallCount);
        return;
    }

    if (gOvBuilderStep < gOvSlotTarget) {
        int i = gOvBuilderStep;
        uint64_t host = r_is_objc_ptr(gOvClip) ? gOvClip : gOvWindow;
        OV_Rect r0 = {0, 0, 0, 0};
        uint64_t box = ov_make_view(gOvClsView, gOvClearColor, 2.0, gOvRedCGColor, r0, i == 0);
        if (!r_is_objc_ptr(box)) {
            gOvBuildFailed = true;
            ov_status("[5/6] 第 %d 个方框创建失败（box=0x%llx，已用调用 %lu 次）", i, box, gOvCallCount);
            return;
        }
        r_msg2_main(host, "addSubview:", box, 0, 0, 0);
        gOvBox[i] = box;

        OV_Rect r2 = {0, 0, 0, 0};
        uint64_t ds = ov_make_label(gOvClsLabel, gOvFont, gOvWhiteColor, gOvClearColor, 1, r2, i == 0);
        if (!r_is_objc_ptr(ds)) {
            gOvBuildFailed = true;
            ov_status("[5/6] 第 %d 个文字创建失败（label=0x%llx，已用调用 %lu 次）", i, ds, gOvCallCount);
            return;
        }
        r_msg2_main(host, "addSubview:", ds, 0, 0, 0);
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
}

#pragma mark - 每帧绘制

/* 把裁剪容器摆到当前面板矩形，并把准星重新钉到屏幕正中。
   只在几何真正变化时发远程调用，所以拖滑块/切方向才会重排，平时零开销。 */
static void ov_sync_geometry(void)
{
    double sw = 0, sh = 0;
    ov_screen_wh(&sw, &sh);
    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    if (gOvFullscreen) { px = 0; py = 0; pw = sw; ph = sh; }

    if (r_is_objc_ptr(gOvClip) &&
        (gOvClipX != px || gOvClipY != py || gOvClipW != pw || gOvClipH != ph)) {
        OV_Rect clip = {px, py, pw, ph};
        ov_set_rect(gOvClip, "setFrame:", clip);
        gOvClipX = px; gOvClipY = py; gOvClipW = pw; gOvClipH = ph;
    }

    /* 准星钉在屏幕正中（和游戏准星重合），与面板/裁剪区无关 */
    double cx = sw / 2.0, cy = sh / 2.0;
    if (gOvCrossCx != cx || gOvCrossCy != cy) {
        if (r_is_objc_ptr(gOvCrossH)) {
            OV_Rect h = {cx - 9.0, cy - 0.75, 18.0, 1.5};
            ov_set_rect(gOvCrossH, "setFrame:", h);
        }
        if (r_is_objc_ptr(gOvCrossV)) {
            OV_Rect v = {cx - 0.75, cy - 9.0, 1.5, 18.0};
            ov_set_rect(gOvCrossV, "setFrame:", v);
        }
        gOvCrossCx = cx; gOvCrossCy = cy;
    }
}

/* 解析一行快照并更新方框。返回画出来的方框数。
   带脏检查：frame/隐藏状态/距离数字与上次相同就完全不发远程调用。

   坐标约定（重要）：
     · 投影锚定**屏幕正中**（和游戏准星 1:1），算出来的是全屏坐标；
       方框/文字画在裁剪容器里，所以 setFrame 时要减掉裁剪区原点 (gOvClipX,gOvClipY)。
     · UE 传来的 z 是胶囊中心（脚底上方约 0.9m），所以相机取 self_z + (眼高 - 0.9)，
       人物直接用自身 z，不再额外加身高。 */
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

    double sw = 0, sh = 0;
    ov_screen_wh(&sw, &sh);
    if (sw < 8.0 || sh < 8.0) return 0;
    ov_sync_geometry();
    /* 裁剪容器原点：全屏坐标减掉它才是容器内坐标 */
    double ox = gOvClipX, oy = gOvClipY;

    /* 自己 */
    char *p = gOvSnap;
    double sx = 0, sy = 0, sz = 0, yaw = 0, pitch = 0;
    if (sscanf(p, "%lf,%lf,%lf,%lf,%lf", &sx, &sy, &sz, &yaw, &pitch) != 5) return 0;
    gOvLastSelf[0] = sx; gOvLastSelf[1] = sy; gOvLastSelf[2] = sz;
    gOvLastYaw = yaw; gOvLastPitch = pitch;
    OV_Vec3 cam = ov_ue_to_world(sx, sy, sz);
    /* 眼高是"脚底往上"的量，而 z 是胶囊中心（脚底上方 0.9m），所以减去 0.9 */
    cam.z += (gOvEye - 0.9);

    double yr = -yaw * M_PI / 180.0;
    double pr = pitch * M_PI / 180.0;
    if (pr > 1.55) pr = 1.55;
    if (pr < -1.55) pr = -1.55;
    OV_Vec3 fwd = {cos(yr) * cos(pr), sin(yr) * cos(pr), sin(pr)};
    OV_Vec3 up0 = {0, 0, 1};
    OV_Vec3 right = ov_norm(ov_cross(fwd, up0));
    OV_Vec3 up = ov_cross(right, fwd);

    double tanHalfY = tan(gOvFov * M_PI / 360.0);
    double aspect = sw / sh;

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
        OV_Vec3 w = ov_ue_to_world(ex, ey, ez);       /* z 本身就是胶囊中心，不要再加身高 */

        OV_Vec3 d = ov_sub(w, cam);
        double depth = ov_dot(d, fwd);
        if (depth < 0.5) continue;
        double rx = ov_dot(d, right) / depth;
        double ry = ov_dot(d, up) / depth;
        if (fabs(rx) > tanHalfY * aspect * 1.6 || fabs(ry) > tanHalfY * 1.6) continue;

        /* 投影锚定屏幕正中：fov 是竖直视场角（与网页版 three.js 一致），
           横竖两个方向都用 sh/2——横向若用 sw/2 会漏掉 aspect，画面被横向拉伸。
           得到的是全屏坐标，setFrame 时再减掉裁剪容器原点 (ox,oy)。 */
        double cx = sw / 2.0 + rx * (sh / 2.0) / tanHalfY;
        double cy = sh / 2.0 - ry * (sh / 2.0) / tanHalfY;

        double boxH = OV_PERSON_HEIGHT / depth * (sh / 2.0) / tanHalfY;
        if (boxH < OV_MIN_BOX_PX) boxH = OV_MIN_BOX_PX;
        double boxW = boxH * 0.52;
        if (drawn == 0) { gOvLastCx = cx; gOvLastCy = cy; gOvLastDepth = depth; }

        int i = drawn++;
        used[i] = true;
        OV_Rect box = {cx - ox - boxW / 2.0, cy - oy - boxH / 2.0, boxW, boxH};
        int distM = (int)(depth + 0.5);

        OV_SlotCache *c = &gOvCache[i];
        /* 每格的上一次下发值：只有真的变了才发远程调用。远程调用极贵——标量 setter
           在非 vphone 通道下走 NSInvocation，每次 13 个远程调用、每个调用还会 spawn
           一个 pac 线程 + 异常端口。所以能省则省：
             - 位置没变就不发 setFrame:；
             - 已经可见就不再发 setHidden:0（重复发等于白跑 13 次远程调用）。 */
        bool geomChanged = !gOvCacheValid || !c->used
                           || fabs(c->r.x - box.x) > 0.5 || fabs(c->r.y - box.y) > 0.5
                           || fabs(c->r.w - box.w) > 0.5 || fabs(c->r.h - box.h) > 0.5;
        bool needShow = !gOvCacheValid || c->hidden || !c->used;
        if (geomChanged) {
            ov_set_rect(gOvBox[i], "setFrame:", box);
            if (needShow) ov_set_bool(gOvBox[i], "setHidden:", 0);
            if (r_is_objc_ptr(gOvDist[i])) {
                OV_Rect dl = {cx - ox - 40.0, cy - oy + boxH / 2.0 + 2.0, 80.0, 14.0};
                ov_set_rect(gOvDist[i], "setFrame:", dl);
                bool wantDistHidden = gOvShowDist ? false : true;
                bool distChangedVis = !gOvCacheValid || c->distHidden || !c->used;
                if (distChangedVis || c->distHidden != wantDistHidden) {
                    ov_set_bool(gOvDist[i], "setHidden:", wantDistHidden ? 1 : 0);
                    c->distHidden = wantDistHidden;
                }
            }
        }
        if (!gOvCacheValid || c->dist != distM) {
            char buf[OV_NAME_TEXT_MAX];
            snprintf(buf, sizeof(buf), "%dm", distM);
            ov_set_text(gOvDist[i], buf);
        }
        c->used = true; c->hidden = false; c->r = box; c->dist = distM;
    }

    for (int i = drawn; i < gOvSlotsAllocated; i++) {
        OV_SlotCache *c = &gOvCache[i];
        if (gOvCacheValid && (c->hidden || !c->used)) continue;
        if (r_is_objc_ptr(gOvBox[i])) ov_set_bool(gOvBox[i], "setHidden:", 1);
        if (r_is_objc_ptr(gOvDist[i])) ov_set_bool(gOvDist[i], "setHidden:", 1);
        c->hidden = true; c->used = false; c->distHidden = true;
    }
    gOvCacheValid = true;
    return drawn;
}

static void ov_tick(void)
{
    pthread_mutex_lock(&gOvLock);
    if (!gOvRunning) { pthread_mutex_unlock(&gOvLock); return; }

    ov_log_mute();                 /* 帧内静音，避免 (rc)/(pac) 刷爆日志 */
    /* 兜底：万一建格子循环没走完（例如前面崩过），这里继续把剩下的补上 */
    if (!gOvBuildFailed && !(gOvBuilderStep >= gOvSlotTarget && gOvCrossDone)) {
        ov_log_unmute();
        ov_build_slots_step();
        ov_log_mute();
    }
    int drawn = ov_draw_snapshot();
    ov_log_unmute();

    /* 挂起检测：tick 间隔明显变大说明 lara 被系统挂起了，画面会停住 */
    {
        static double last = 0;
        double now = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
        if (last > 0.0 && now - last > 1.0) {
            printf("(overlay) 注意：lara 被挂起了 %.1f 秒（悬浮层在挂起期间不会更新）\n", now - last);
            fflush(stdout);
        }
        last = now;
    }

    static unsigned tick = 0;
    if (++tick % (OV_TICK_HZ * 5) == 0) {          /* 每 5 秒一行摘要 */
        double px = 0, py = 0, pw = 0, ph = 0;
        ov_panel_rect(&px, &py, &pw, &ph);
        printf("(overlay) 绘制中：方框 %d 个，快照%s，面板=%.0f,%.0f %.0fx%.0f，"
               "样本 depth=%.1fm → 屏(%.0f,%.0f) 自己UE=(%.0f,%.0f,%.0f) 朝向=%.0f°/%.0f°\n",
               drawn, gOvSnapFresh ? "有" : "无", px, py, pw, ph,
               gOvLastDepth, gOvLastCx, gOvLastCy,
               gOvLastSelf[0], gOvLastSelf[1], gOvLastSelf[2], gOvLastYaw, gOvLastPitch);
        fflush(stdout);
    }
    pthread_mutex_unlock(&gOvLock);
}

static void ov_start_timer(RemoteCall *proc)
{
    if (gOvTimer) return;
    /* 必须用**串行队列**：一帧里每个标量 setter 在非 vphone 通道下要走 NSInvocation，
       十几个远程调用、还各自 sleep，整帧可能几百毫秒。挂在并发全局队列上时，10Hz 的
       定时器会把好几帧同时排进来并发去跑，远程调用瞬间扎堆——真机日志里"连续密集远程
       调用到 ~19 次目标就崩"，扎堆正是 SpringBoard 裸崩（PC=0x401）的直接来源。
       串行队列保证同一时刻只有一帧在跑，错过的帧自动合并。 */
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("lara.overlay.tick", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!t) { printf("(overlay) 定时器创建失败\n"); fflush(stdout); return; }
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                              OV_TICK_MS * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ ov_tick(); });
    gOvTimer = t;
    dispatch_resume(gOvTimer);
    (void)proc;
}

#pragma mark - Public API

/* 下面这些 set_* 都由**主线程**的 SwiftUI 调用，一律不加锁：
   它们只是写几个独立标量，绘图线程下一帧顺手读走即可。
   一旦加锁，只要绘图线程/建层线程那一刻正持锁，主线程就会卡住 → watchdog。 */
void clock_overlay_set_view(int maxSlots, double fovDeg, double eyeHeight,
                            int showNames, int showDist, int showCross)
{
    if (maxSlots > 0) gOvMaxSlots = (maxSlots > OV_MAX_SLOTS) ? OV_MAX_SLOTS : maxSlots;
    if (fovDeg >= 40.0 && fovDeg <= 130.0) gOvFov = fovDeg;
    if (eyeHeight >= 0.2 && eyeHeight <= 3.0) gOvEye = eyeHeight;
    gOvShowNames = showNames ? 1 : 0;
    gOvShowDist = showDist ? 1 : 0;
    gOvShowCross = showCross ? 1 : 0;
    gOvCacheValid = false;          /* 画面参数变了：下一帧重发 */
}

void clock_overlay_set_geometry(double widthRatio, double topMargin)
{
    gOvWidthRatio = (widthRatio >= 0.2 && widthRatio <= 1.0) ? widthRatio : 0.92;
    gOvTop = (topMargin >= 0.0 && topMargin <= 600.0) ? topMargin : 56.0;
    gOvCacheValid = false;
}

void clock_overlay_set_height_ratio(double heightRatio)
{
    gOvHeightRatio = (heightRatio >= 0.1 && heightRatio <= 1.0) ? heightRatio : 0.0;
    gOvCacheValid = false;
}

void clock_overlay_set_layout(int landscape, int fullscreen)
{
    gOvLandscape = landscape ? 1 : 0;
    gOvFullscreen = fullscreen ? 1 : 0;
    gOvCacheValid = false;
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
    if (!url) gOvUrl[0] = '\0';
    else { strncpy(gOvUrl, url, sizeof(gOvUrl) - 1); gOvUrl[sizeof(gOvUrl) - 1] = '\0'; }
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

    pthread_mutex_lock(&gOvLock);
    gOvWindow = 0;
    gOvClip = 0;
    gOvClipX = gOvClipY = gOvClipW = gOvClipH = -1;
    gOvCrossCx = gOvCrossCy = -1;
    for (int i = 0; i < OV_MAX_SLOTS; i++) { gOvBox[i] = gOvName[i] = gOvDist[i] = 0; }
    gOvSlotsAllocated = 0;
    pthread_mutex_unlock(&gOvLock);

    /* 建层：**不持锁**。ov_build 要做几十次跨进程调用（单次最长 R_TIMEOUT=5s），
       每次还会往 stdout 打十几行；如果持锁，主线程任一 set_* 调用都会被拖住，
       超过 ~10s 就被系统 watchdog 杀掉（crashes 里就是 EXC_CRASH/SIGKILL、
       scene-update 10s / 0x8BADF00D，主线程卡在 gOvLock）。
       同时把 stdout 静音：那波刷屏会把 Logger 的管道写满，之后 printf 直接阻塞。 */
    ov_log_mute();
    bool ok = ov_build(proc);
    ov_log_unmute();

    pthread_mutex_lock(&gOvLock);
    gOvBuilding = false;
    if (!ok) gOvFailed = true;
    if (ok) { gOvRunning = true; ov_start_timer(proc); }
    pthread_mutex_unlock(&gOvLock);
    return ok;
}

bool clock_overlay_selftest(RemoteCall *proc)
{
    if (!proc) { ov_status("自检失败：RemoteCall 为空"); return false; }

    gOvRunning = false;
    gOvFailed = false;                       /* 用户显式重试：解开失败闩锁 */
    if (gOvTimer) { dispatch_source_cancel(gOvTimer); gOvTimer = nil; }
    uint64_t win = gOvWindow;
    if (r_is_objc_ptr(win)) ov_set_bool(win, "setHidden:", 1);   /* 远程调用放在锁外 */

    pthread_mutex_lock(&gOvLock);
    gOvWindow = 0;
    gOvClip = 0;
    gOvClipX = gOvClipY = gOvClipW = gOvClipH = -1;
    gOvCrossCx = gOvCrossCy = -1;
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
    gOvRunning = false;                       /* 先落标志：绘图线程下一帧就停 */
    uint64_t win = gOvWindow;
    if (gOvTimer) { dispatch_source_cancel(gOvTimer); gOvTimer = nil; }
    if (r_is_objc_ptr(win)) ov_set_bool(win, "setHidden:", 1);
    ov_status("已隐藏（对象保留，可直接再次开启）");
}

void clock_overlay_unbind(void)
{
    abandon_remote_call();
}
