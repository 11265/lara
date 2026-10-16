//
//  ARCCompat.h
//  lara
//
//  Created by 娇dkxocc2012 李uxuf on 2026/8/4.
//
//
//  ARCCompat.h
//  lara
//
//  把 lara 的 RemoteCall 类包装成 remote_objc / statbar 需要的全局函数。
//

#ifndef ARCCompat_h
#define ARCCompat_h

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 注入 lara 已初始化的 SpringBoard RemoteCall（避免双会话冲突）
void arc_use_existing_remote_call(void *rc);

// statbar 依赖的日志函数
void log_user(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

typedef enum {
    RemoteCallInitFailureNone = 0,
    RemoteCallInitFailureOther = 1
} RemoteCallInitFailure;

int  init_remote_call(const char *process, bool useMigFilterBypass);
int  init_remote_call_with_first_exception_timeout(const char *process, bool mig, int timeoutMS);
int  init_remote_call_original_thread_only_with_first_exception_timeout(const char *process, bool mig, int timeoutMS);
uint64_t do_remote_call_stable(int timeout, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
bool remote_read(uint64_t src, void *dst, uint64_t size);
uint64_t remote_read64(uint64_t src);
bool remote_write(uint64_t dst, const void *src, uint64_t size);
bool remote_write64(uint64_t dst, uint64_t val);
bool remote_writeStr(uint64_t dst, const char *str);
uint64_t remote_call_trojan_mem(void);
int  destroy_remote_call(void);
void abandon_remote_call(void);
bool remote_call_has_local_state(void);
bool remote_call_current_success(void);
int  remote_call_current_pid(void);
bool remote_call_uses_vphone_bridge(void);
int  remote_call_set_stable_timeout_floor_ms(int timeoutMS);
RemoteCallInitFailure remote_call_last_init_failure(void);
uint32_t remote_call_last_init_failure_pid(void);
const char *remote_call_init_failure_description(RemoteCallInitFailure failure);

#ifdef __cplusplus
}
#endif

#endif /* ARCCompat_h */
