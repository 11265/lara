//
//  clock_overlay.h
//  lara
//
//  Global floating overlay, drawn by the target process (SpringBoard) so it
//  floats above everything.
//
//  现在的内容是「第一视角（FPS）雷达」：浮层里放一个 WKWebView，加载局域网
//  服务（rr/fpv）提供的页面，数据由那台电脑的解析核心经局域网送到手机上。
//  若目标进程里没有 WKWebView（或建不出来），会自动退回原来的时间胶囊，
//  保证浮层永远不会因为缺类而不可用。
//
//  Data source: 局域网 http://<电脑IP>:<端口>/ —— 不读内存、不读其它进程。
//

#ifndef clock_overlay_h
#define clock_overlay_h

#include <stdbool.h>

#ifdef __OBJC__

#import "TaskRop/RemoteCall.h"

/// 第一视角页面的地址，例如 "http://192.168.137.1:18099/"。
/// 传 NULL 或空串则用内置默认值。必须在 clock_overlay_start() 之前调用。
void clock_overlay_set_url(const char *url);

/// 浮层几何：widthRatio 为宽度占屏比（0.2~1.0，<=0 用默认 0.92），
/// topMargin 为距屏幕顶部点数（<=0 用默认值）。高度按 16:9 计算。
void clock_overlay_set_geometry(double widthRatio, double topMargin);

/// 当前浮层内容的地址（只读，永不返回 NULL）。
const char *clock_overlay_url(void);

/// Creates (or re-shows) the floating overlay in `proc` — expected to be a live
/// SpringBoard RemoteCall — and keeps it alive afterwards.
/// Returns true when the overlay was attached and made visible.
bool clock_overlay_start(RemoteCall *proc);

/// Tears the overlay down and rebuilds it from scratch, printing a numbered
/// line for every step into stdout (which lara's logger captures). Meant for
/// the "自检" button: if a step kills the remote call, the last line in the log
/// says exactly which one it was.
bool clock_overlay_selftest(RemoteCall *proc);

/// Hides the overlay. The objects are kept (not destroyed), so starting it
/// again is instant; a respring clears it for good.
/// Safe to call when the overlay is not running.
void clock_overlay_stop(RemoteCall *proc);

/// True while the overlay is up.
bool clock_overlay_is_running(void);

/// Human readable one-line state of the last start attempt (never NULL).
const char *clock_overlay_status(void);

/// Drops the binding to the RemoteCall session (call it when lara destroys the
/// remote call, so a later start cannot use a destroyed session).
void clock_overlay_unbind(void);

#endif /* __OBJC__ */

#endif /* clock_overlay_h */
