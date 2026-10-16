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

/* ── 崩溃面包屑 ──────────────────────────────────────────────────────────
   真机上 lara 崩得太频繁时内核尸体槽会满（Corpse failure, too many），
   崩溃报告写不出来，日志只会戛然而止，永远看不到死在哪一步。
   所以自己落一个文件：每个关键步骤写一行并 fsync；信号处理器再把
   "最后一步"补写一遍（处理器里不做格式化，只 write 预先存好的那一行）。 */
static int gOvCrumbFd = -1;
static char gOvCrumbPath[512];
static volatile char gOvCrumbLast[192] = "启动前";

static void ov_crumb_open(void)
{
    if (gOvCrumbFd >= 0) return;
    const char *home = getenv("HOME");
    snprintf(gOvCrumbPath, sizeof(gOvCrumbPath), "%s/Documents/fpv-crumb.log",
             home ? home : "/tmp");
    gOvCrumbFd = open(gOvCrumbPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}

static void ov_crumb(const char *fmt, ...)
{
    ov_crumb_open();
    if (gOvCrumbFd < 0) return;
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    size_t n = strlen(buf);
    if (n > sizeof(gOvCrumbLast) - 1) n = sizeof(gOvCrumbLast) - 1;
    memcpy((void *)gOvCrumbLast, buf, n);
    ((char *)gOvCrumbLast)[n] = '\0';
    write(gOvCrumbFd, buf, n);
    fsync(gOvCrumbFd);
}

static void ov_crumb_signal(int sig)
{
    if (gOvCrumbFd >= 0) {
        char num[4];
        int k = 0;
        if (sig >= 10) num[k++] = (char)('0' + (sig / 10) % 10);
        num[k++] = (char)('0' + sig % 10);
        write(gOvCrumbFd, "*** 信号 ", 11);
        write(gOvCrumbFd, num, (size_t)k);
        write(gOvCrumbFd, " 死前最后一步：", 21);
        write(gOvCrumbFd, (const char *)gOvCrumbLast, strlen((const char *)gOvCrumbLast));
        write(gOvCrumbFd, "\n", 1);
        fsync(gOvCrumbFd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void ov_crumb_install(void)
{
    ov_crumb_open();
    ov_crumb("== 浮层启动，面包屑已开启 ==\n");
    signal(SIGSEGV, ov_crumb_signal);
    signal(SIGBUS, ov_crumb_signal);
    signal(SIGABRT, ov_crumb_signal);
    signal(SIGILL, ov_crumb_signal);
    signal(SIGFPE, ov_crumb_signal);
    ov_crumb("面包屑路径: %s\n", gOvCrumbPath);
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
    /* 只读探测：以前这里会往线程结构地址写回同一个值来验证写通道，但真机日志显示
       那个内核地址常常不可映射（vmmapfindentry failed），对不可映射的内核地址写
       很可能把远程会话弄坏 —— 得不偿失，改成只读。 */
    for (int attempt = 0; attempt < 3; attempt++) {
        r_settle_us(30000);
        usleep(80 * 1000);

        uint64_t addr = proc.trojanThreadAddr ? proc.trojanThreadAddr : proc.callThreadAddr;
        if (addr < 0x1000ULL) { *why = "拿不到目标线程结构地址"; continue; }

        uint64_t a = [proc remoteRead64From:addr];
        uint64_t b = [proc remoteRead64From:addr];
        if (a == 0 && b == 0) { *why = "远程读取返回 0（地址不可映射）"; continue; }

        printf("(overlay) 健康检查 OK（只读 addr=0x%llx 读回=0x%llx/0x%llx）\n", addr, a, b);
        fflush(stdout);
        return true;
    }
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
    uint64_t clsImageView = r_class("UIImageView");   /* 位图绘制：目标侧唯一的视图 */
    uint64_t clsImage     = r_class("UIImage");
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

    /* 裁剪容器不再需要：位图本身就是面板大小，天然裁剪。 */
    (void)clear;

    step++;
    ov_status("[%d/6] window=0x%llx 投影=整屏%.0fx%.0f 面板=%.0f,%.0f %.0fx%.0f 方向=%s%s",
              step, win, sw, sh, px, py, pw, ph, gOvLandscape ? "横屏" : "竖屏", gOvFullscreen ? " 全屏" : "");

    /* 位图绘制：建目标侧的像素内存 + 位图上下文 + 唯一那个 UIImageView */
    int slots = gOvMaxSlots;
    if (slots < 1) slots = 1;
    if (slots > OV_MAX_SLOTS) slots = OV_MAX_SLOTS;
    gOvSlotTarget = slots;
    gOvBuilderStep = slots;
    gOvCrossDone = true;
    gOvBuildFailed = false;
    if (!ov_bitmap_setup(clsImageView, clsImage, clear, (OV_Rect){px, py, pw, ph}, win)) {
        gOvBuildFailed = true;
    }

    /* 字体/颜色已经不需要（画面在 lara 侧画成像素） —— 保留对象解析只为兼容日志 */
    uint64_t font = 0;
    if (r_is_objc_ptr(clsFont)) {
        double fs = 11.0, wt = 0.6;
        font = r_msg2_main_raw(clsFont, "systemFontOfSize:weight:",
                               &fs, sizeof(fs), &wt, sizeof(wt), NULL, 0, NULL, 0);
    }
    uint64_t white = 0, red = 0, blue = 0, orange = 0;
    uint64_t whiteCG = 0, redCG = 0;
    if (r_is_objc_ptr(clsColor)) {
        white  = r_msg2_main(clsColor, "whiteColor", 0, 0, 0, 0);
        red    = r_msg2_main(clsColor, "systemRedColor", 0, 0, 0, 0);
        blue   = r_msg2_main(clsColor, "systemBlueColor", 0, 0, 0, 0);
        orange = r_msg2_main(clsColor, "systemOrangeColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(white)) whiteCG = r_msg2_main(white, "CGColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(red))   redCG   = r_msg2_main(red, "CGColor", 0, 0, 0, 0);
    }
    (void)blue; (void)orange; (void)whiteCG; (void)redCG; (void)font;
    gOvFont = font;
    gOvWhiteColor = white;
    gOvClsView = clsView;
    gOvClsLabel = clsLabel;
    gOvSlotsAllocated = slots;

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
/* ── 位图绘制（方案 A）──────────────────────────────────────────────────
   目标侧只放**一个 UIImageView**，画面由 lara 这边画进一块 RGBA 位图后整块提交。

   为什么换：旧方案每格要 setFrame/setHidden/setText 等标量 setter，而真机上
   **每个标量 setter 内部约 13 次远程调用**（NSInvocation + pac 线程），8 格一帧
   就是几百次远程调用 —— 这正是把 lara 拖死、SpringBoard 跟着崩的根源。
   换成位图后每帧只要：
     remote_write(整块像素) → CGBitmapContextCreateImage → setImage: → CGImageRelease
   共 4 次远程调用，而且像素没变时一次都不发。

   位图尺寸 = 面板尺寸（点为单位 1:1），方框按「屏幕坐标 − 面板原点」直接画进去，
   所以天然被面板裁剪（不再需要裁剪容器），也不会再有位置偏移。 */

static uint8_t *gOvFB = NULL;          /* lara 侧像素：RGBA8888，预乘 alpha */
static uint8_t *gOvFBPrev = NULL;      /* 上一帧，用于判断内容是否变化 */
static size_t   gOvFBCap = 0, gOvFBPrevCap = 0;
static int      gOvFBW = 0, gOvFBH = 0;
static bool     gOvFBForce = true;

static uint64_t gOvFBView = 0;         /* 目标侧 UIImageView（唯一的视图） */
static uint64_t gOvFBPixels = 0;       /* 目标侧的像素内存 */
static uint64_t gOvFBContext = 0;      /* 目标侧 CGBitmapContext */
static uint64_t gOvFBImage = 0;        /* 目标侧当前 CGImage（每帧替换，旧的释放） */
static uint64_t gOvClsUIImage = 0;

/* 面板里那个 UIImageView 当前 frame + 会话对象（提交像素要用） */
static double gOvFBViewX = -1, gOvFBViewY = -1, gOvFBViewW = -1, gOvFBViewH = -1;
static RemoteCall *gOvProc = nil;

/* 目标侧像素内存 + 位图上下文（首次或尺寸变化时创建） */
static bool ov_bitmap_ensure_target(void)
{
    if (gOvFBW <= 0 || gOvFBH <= 0) return false;
    if (r_is_objc_ptr(gOvFBPixels) && r_is_objc_ptr(gOvFBContext)) return true;

    gOvFBPixels = r_dlsym_call(R_TIMEOUT, "malloc",
                               (uint64_t)((size_t)gOvFBW * (size_t)gOvFBH * 4),
                               0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(gOvFBPixels)) {
        ov_status("目标侧像素内存分配失败（%dx%d）", gOvFBW, gOvFBH);
        return false;
    }
    uint64_t space = r_dlsym_call(R_TIMEOUT, "CGColorSpaceCreateDeviceRGB", 0, 0, 0, 0, 0, 0, 0, 0);
    gOvFBContext = r_dlsym_call(R_TIMEOUT, "CGBitmapContextCreate",
                                gOvFBPixels, (uint64_t)gOvFBW, (uint64_t)gOvFBH, 8,
                                (uint64_t)(gOvFBW * 4), space, 1 /* premultipliedLast */, 0);
    if (!r_is_objc_ptr(gOvFBContext)) {
        ov_status("CGBitmapContextCreate 失败（%dx%d）", gOvFBW, gOvFBH);
        return false;
    }
    if (r_is_objc_ptr(gOvFBImage)) {
        r_dlsym_call(R_TIMEOUT, "CGImageRelease", gOvFBImage, 0, 0, 0, 0, 0, 0, 0);
        gOvFBImage = 0;
    }
    gOvFBForce = true;
    return true;
}

/* 3x5 点阵：0-9 + 'm'（每行 3 bit，够显示"12m"这种） */
static const uint8_t kOvFont3x5[11][5] = {
    {7, 5, 5, 5, 7}, {2, 6, 2, 2, 7}, {7, 1, 7, 4, 7}, {7, 1, 7, 1, 7}, {5, 5, 7, 1, 1},
    {7, 4, 7, 1, 7}, {7, 4, 7, 5, 7}, {7, 1, 1, 1, 1}, {7, 5, 7, 5, 7}, {7, 5, 7, 1, 7},
    {5, 7, 5, 5, 5}   /* 'm' */
};

static inline void ov_fb_px(int x, int y, uint8_t r, uint8_t g, uint8_t b)
{
    if (!gOvFB || x < 0 || y < 0 || x >= gOvFBW || y >= gOvFBH) return;
    uint8_t *q = gOvFB + ((size_t)y * (size_t)gOvFBW + (size_t)x) * 4;
    q[0] = r; q[1] = g; q[2] = b; q[3] = 255;    /* 预乘 alpha：不透明 */
}

static void ov_fb_rect(double x, double y, double w, double h, uint8_t r, uint8_t g, uint8_t b)
{
    int x0 = (int)floor(x), y0 = (int)floor(y);
    int x1 = (int)ceil(x + w), y1 = (int)ceil(y + h);
    if (x1 <= x0 || y1 <= y0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > gOvFBW) x1 = gOvFBW;
    if (y1 > gOvFBH) y1 = gOvFBH;
    for (int yy = y0; yy < y1; yy++) {
        uint8_t *row = gOvFB + ((size_t)yy * (size_t)gOvFBW + (size_t)x0) * 4;
        for (int xx = x0; xx < x1; xx++) {
            row[0] = r; row[1] = g; row[2] = b; row[3] = 255;
            row += 4;
        }
    }
}

static void ov_fb_glyph(int idx, int x, int y, int scale, uint8_t r, uint8_t g, uint8_t b)
{
    if (idx < 0 || idx > 10) return;
    for (int row = 0; row < 5; row++) {
        uint8_t bits = kOvFont3x5[idx][row];
        for (int col = 0; col < 3; col++) {
            if (bits & (1 << (2 - col))) {
                ov_fb_rect(x + col * scale, y + row * scale, scale, scale, r, g, b);
            }
        }
    }
}

static void ov_fb_text_m(int value, int x, int y, int scale, uint8_t r, uint8_t g, uint8_t b)
{
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", value);
    int cx = x;
    for (const char *p = buf; *p; p++) {
        if (*p >= '0' && *p <= '9') ov_fb_glyph(*p - '0', cx, y, scale, r, g, b);
        cx += 4 * scale;
    }
    ov_fb_glyph(10, cx, y, scale, r, g, b);      /* 'm' */
}

static bool ov_fb_reserve(int w, int h)
{
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return false;
    size_t need = (size_t)w * (size_t)h * 4;
    if (gOvFB && gOvFBW == w && gOvFBH == h && gOvFBCap >= need) return true;
    uint8_t *buf = (uint8_t *)malloc(need);
    if (!buf) return false;
    free(gOvFB);
    gOvFB = buf;
    gOvFBCap = need;
    gOvFBW = w;
    gOvFBH = h;
    if (gOvFBPrevCap < need) {
        free(gOvFBPrev);
        gOvFBPrev = (uint8_t *)malloc(need);
        gOvFBPrevCap = gOvFBPrev ? need : 0;
    }
    gOvFBForce = true;
    return true;
}

/* 目标侧：像素内存 + 位图上下文 + 唯一那个 UIImageView */
static bool ov_bitmap_setup(uint64_t clsUIImageView, uint64_t clsUIImage, uint64_t clearColor,
                            OV_Rect panel, uint64_t host)
{
    gOvClsUIImage = clsUIImage;
    int w = (int)(panel.w + 0.5), h = (int)(panel.h + 0.5);
    if (!ov_fb_reserve(w, h)) {
        ov_status("[5/6] 位图分配失败 %dx%d", w, h);
        return false;
    }
    gOvFBPixels = 0; gOvFBContext = 0; gOvFBImage = 0;   /* 尺寸可能变了：强制重建 */
    if (!ov_bitmap_ensure_target()) return false;

    uint64_t alloc = r_msg2_main(clsUIImageView, "alloc", 0, 0, 0, 0);
    OV_Rect fr = panel;
    uint64_t iv = r_is_objc_ptr(alloc)
        ? r_msg2_main_raw(alloc, "initWithFrame:", &fr, sizeof(fr), NULL, 0, NULL, 0, NULL, 0)
        : 0;
    if (!r_is_objc_ptr(iv)) {
        ov_status("[5/6] UIImageView 创建失败");
        return false;
    }
    if (r_is_objc_ptr(clearColor)) r_msg2_main(iv, "setBackgroundColor:", clearColor, 0, 0, 0);
    r_msg2_main(iv, "setOpaque:", 0, 0, 0, 0);
    r_msg2_main(iv, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(host, "addSubview:", iv, 0, 0, 0);
    gOvFBView = iv;
    gOvFBForce = true;
    ov_status("[5/6] 位图绘制就绪：%dx%d，目标侧只有 1 个 UIImageView", w, h);
    return true;
}

/* 每帧提交：像素没变就一次远程调用都不发 */
static void ov_bitmap_upload(RemoteCall *proc)
{
    if (!r_is_objc_ptr(gOvFBView) || !gOvFB || !r_is_objc_ptr(gOvFBContext) || !r_is_objc_ptr(gOvFBPixels)) return;
    size_t len = (size_t)gOvFBW * (size_t)gOvFBH * 4;
    if (!gOvFBForce && gOvFBPrev && memcmp(gOvFB, gOvFBPrev, len) == 0) return;
    if (gOvFBPrev) memcpy(gOvFBPrev, gOvFB, len);
    gOvFBForce = false;

    if (![proc remote_write:gOvFBPixels from:gOvFB size:(uint64_t)len]) {
        ov_crumb("bitmap upload failed (remote_write)\n");
        return;
    }
    uint64_t img = r_dlsym_call(R_TIMEOUT, "CGBitmapContextCreateImage", gOvFBContext, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(img)) return;
    uint64_t ui = r_is_objc_ptr(gOvClsUIImage) ? r_msg2_main(gOvClsUIImage, "imageWithCGImage:", img, 0, 0, 0) : 0;
    if (r_is_objc_ptr(ui)) r_msg2_main(gOvFBView, "setImage:", ui, 0, 0, 0);
    if (r_is_objc_ptr(gOvFBImage)) {
        r_dlsym_call(R_TIMEOUT, "CGImageRelease", gOvFBImage, 0, 0, 0, 0, 0, 0, 0);
    }
    gOvFBImage = img;
}

/* 位图方案下没有"逐格建视图"这回事：视图在 ov_build 里一次建好。 */
static void ov_build_slots_step(void)
{
    if (r_is_objc_ptr(gOvFBView)) {
        gOvBuilderStep = gOvSlotTarget;
        gOvCrossDone = true;
    }
}

#pragma mark - 每帧绘制

/* 面板/屏幕几何变化时：重算位图尺寸、重定位那个 UIImageView。
   只在真正变化时发远程调用，所以拖滑块/切方向才动，平时零开销。 */
static void ov_sync_geometry(void)
{
    double sw = 0, sh = 0;
    ov_screen_wh(&sw, &sh);
    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    if (gOvFullscreen) { px = 0; py = 0; pw = sw; ph = sh; }

    int w = (int)(pw + 0.5), h = (int)(ph + 0.5);
    if (w > 0 && h > 0 && (w != gOvFBW || h != gOvFBH || !gOvFB)) {
        if (ov_fb_reserve(w, h)) {
            gOvFBPixels = 0; gOvFBContext = 0; gOvFBImage = 0;   /* 让 ensure 重建 */
        }
    }
    if (r_is_objc_ptr(gOvFBView) &&
        (gOvFBViewX != px || gOvFBViewY != py || gOvFBViewW != pw || gOvFBViewH != ph)) {
        OV_Rect fr = {px, py, pw, ph};
        ov_set_rect(gOvFBView, "setFrame:", fr);
        gOvFBViewX = px; gOvFBViewY = py; gOvFBViewW = pw; gOvFBViewH = ph;
    }
    gOvCrossCx = sw / 2.0; gOvCrossCy = sh / 2.0;
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
    if (!r_is_objc_ptr(gOvWindow) || !r_is_objc_ptr(gOvFBView) || !gOvFB) return 0;

    double sw = 0, sh = 0;
    ov_screen_wh(&sw, &sh);
    if (sw < 8.0 || sh < 8.0) return 0;
    ov_sync_geometry();
    if (!ov_bitmap_ensure_target()) return 0;

    double px = 0, py = 0, pw = 0, ph = 0;
    ov_panel_rect(&px, &py, &pw, &ph);
    if (gOvFullscreen) { px = 0; py = 0; pw = sw; ph = sh; }

    /* 整块清成透明（预乘 alpha：全 0 即透明） */
    memset(gOvFB, 0, (size_t)gOvFBW * (size_t)gOvFBH * 4);

    /* 准星：屏幕正中（也就是面板正中），画进位图 */
    if (gOvShowCross) {
        double cx = sw / 2.0 - px, cy = sh / 2.0 - py;
        ov_fb_rect(cx - 9.0, cy - 0.75, 18.0, 1.5, 0, 255, 0);
        ov_fb_rect(cx - 0.75, cy - 9.0, 1.5, 18.0, 0, 255, 0);
    }

    int drawn = 0;
    if (gOvSnapFresh && gOvSnap[0]) {
        double sx = 0, sy = 0, sz = 0, yaw = 0, pitch = 0;
        if (sscanf(gOvSnap, "%lf,%lf,%lf,%lf,%lf", &sx, &sy, &sz, &yaw, &pitch) == 5) {
            gOvLastSelf[0] = sx; gOvLastSelf[1] = sy; gOvLastSelf[2] = sz;
            gOvLastYaw = yaw; gOvLastPitch = pitch;
            OV_Vec3 cam = ov_ue_to_world(sx, sy, sz);
            cam.z += (gOvEye - 0.9);            /* z 是胶囊中心，眼高从脚底算 */

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
            char *body = semi ? semi + 1 : NULL;
            char *save = NULL;
            for (char *tok = body ? strtok_r(body, ";", &save) : NULL;
                 tok && drawn < gOvSlotsAllocated;
                 tok = strtok_r(NULL, ";", &save)) {
                double ex = 0, ey = 0, ez = 0;
                int kind = 0;
                if (sscanf(tok, "%lf,%lf,%lf,%d", &ex, &ey, &ez, &kind) != 4) continue;
                OV_Vec3 w3 = ov_ue_to_world(ex, ey, ez);

                OV_Vec3 d = ov_sub(w3, cam);
                double depth = ov_dot(d, fwd);
                if (depth < 0.5) continue;
                double rx = ov_dot(d, right) / depth;
                double ry = ov_dot(d, up) / depth;
                if (fabs(rx) > tanHalfY * aspect * 1.6 || fabs(ry) > tanHalfY * 1.6) continue;

                /* 全屏坐标 → 位图坐标（减面板原点） */
                double cx = sw / 2.0 + rx * (sh / 2.0) / tanHalfY - px;
                double cy = sh / 2.0 - ry * (sh / 2.0) / tanHalfY - py;
                double boxH = OV_PERSON_HEIGHT / depth * (sh / 2.0) / tanHalfY;
                if (boxH < OV_MIN_BOX_PX) boxH = OV_MIN_BOX_PX;
                double boxW = boxH * 0.52;
                if (drawn == 0) { gOvLastCx = cx; gOvLastCy = cy; gOvLastDepth = depth; }
                drawn++;

                uint8_t r = 255, g = 64, b = 64;                 /* 敌人=红 */
                if (kind == 1) { r = 64; g = 160; b = 255; }     /* 队友=蓝 */
                else if (kind == 2) { r = 255; g = 176; b = 64; }/* AI=橙 */

                double x0 = cx - boxW / 2.0, y0 = cy - boxH / 2.0, t = 2.0;
                ov_fb_rect(x0, y0, boxW, t, r, g, b);
                ov_fb_rect(x0, y0 + boxH - t, boxW, t, r, g, b);
                ov_fb_rect(x0, y0, t, boxH, r, g, b);
                ov_fb_rect(x0 + boxW - t, y0, t, boxH, r, g, b);
                if (gOvShowDist) {
                    ov_fb_text_m((int)(depth + 0.5), (int)(cx - 12), (int)(y0 + boxH + 2), 1,
                                 255, 255, 255);
                }
            }
        }
    }

    ov_bitmap_upload(gOvProc);
    return drawn;
}

static void ov_tick(void)
{
    pthread_mutex_lock(&gOvLock);
    if (!gOvRunning) { pthread_mutex_unlock(&gOvLock); return; }

    ov_crumb("tick draw slots=%d snap=%d\n", gOvSlotsAllocated, gOvSnapFresh ? 1 : 0);
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
    /* 永久静音：远程调用每次打印十几行 (rc)/(pac)，10Hz 下足以把 lara 的 Logger 压爆。
       真机证据链是「日志暴量 → lara 被系统杀（SIGKILL，无尸体）→ 木马线程来不及做
       pthread_exit 清理 → SpringBoard 留在坏状态跟着崩」。所以启动定时器后就一直静音，
       诊断改走 ov_status（内部写保留的 gOvLogFd，不受静音影响）与崩溃面包屑。 */
    ov_log_mute();
    ov_status("已永久静音远程调用日志（诊断改走状态行与 %s）", gOvCrumbPath[0] ? gOvCrumbPath : "面包屑");
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
    gOvProc = proc;                 /* 提交像素要用它（remote_write） */
    ov_crumb_install();

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
