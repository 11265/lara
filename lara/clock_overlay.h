//
//  clock_overlay.h
//  lara
//
//  Global floating overlay = 第一视角（FPS）雷达，原生绘制。
//
//  绘制方式参考 peace_esp（准猫/沐辞 的开源绘制版）：在目标进程里建一个高层级
//  UIWindow，往上面放**原生 UIView**（layer 边框画方框）+ UILabel（名字/距离）
//  + 中心准星（两条细 UIView）。刻意不用 WKWebView —— 它的内部视图与手势识别器
//  正是"覆盖区域吃触摸"与崩溃的来源。
//
//  数据不读内存：由 lara 通过局域网从电脑上的 rr/fpv 服务取 /api/state，压成一行
//  紧凑文本交给这里（clock_overlay_set_snapshot）。
//

#ifndef clock_overlay_h
#define clock_overlay_h

#include <stdbool.h>

#ifdef __OBJC__

#import "TaskRop/RemoteCall.h"

/// 配置：方框格数上限、视野角（度）、眼高（米）、是否画名字/距离/准星。
void clock_overlay_set_view(int maxSlots, double fovDeg, double eyeHeight,
                            int showNames, int showDist, int showCross);

/// 几何：宽度占屏比（0.2~1.0，<=0 用默认）+ 距顶距离。
void clock_overlay_set_geometry(double widthRatio, double topMargin);

/// 面板高度占屏比：0（默认）= 按 16:9 算；0.1~1.0 = 直接按屏高比例。
void clock_overlay_set_height_ratio(double heightRatio);

/// 方向（用户手选）：landscape=1 横屏 / 0 竖屏；fullscreen=1 铺满整屏。
void clock_overlay_set_layout(int landscape, int fullscreen);

/// 一帧快照（由 lara 从局域网数据压成的一行）：
///   "self_x,self_y,self_z,yaw,pitch;x,y,z,kind;x,y,z,kind;..."
/// 坐标是 UE 厘米；kind: 0=敌人 1=队友 2=AI 3=其它。NULL/空串 = 暂无数据。
void clock_overlay_set_snapshot(const char *compact);

/// 数据服务地址（只用于状态显示与诊断）。
void clock_overlay_set_url(const char *url);

const char *clock_overlay_status(void);
const char *clock_overlay_url(void);

bool clock_overlay_start(RemoteCall *proc);
bool clock_overlay_selftest(RemoteCall *proc);
void clock_overlay_stop(RemoteCall *proc);
bool clock_overlay_is_running(void);
bool clock_overlay_failed(void);
void clock_overlay_unbind(void);

#endif /* __OBJC__ */

#endif /* clock_overlay_h */
