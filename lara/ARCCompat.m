//
//  ARCCompat.m
//  lara
//
//  Created by 娇dkxocc2012 李uxuf on 2026/8/4.
//

#import <Foundation/Foundation.h>
//
//  ARCCompat.m
//  lara
//
//  适配层实现：全部调用 lara 的 RemoteCall 类。
//

#import "ARCCompat.h"
#import "TaskRop/RemoteCall.h"
#import <stdarg.h>
#import <stdio.h>
#import <dlfcn.h>

static RemoteCall *gARC = nil;
static BOOL gARCInjected = NO;

void arc_use_existing_remote_call(void *rc) {
    if (!rc || gARC) return;
    gARC = (__bridge RemoteCall *)rc;
    gARCInjected = YES;
}

void log_user(const char *fmt, ...) {
    if (!fmt) return;
    va_list ap; va_start(ap, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"%s", buf);
}

int init_remote_call(const char *process, bool useMigFilterBypass) {
    if (gARC) return 0;
    if (!process) return -1;
    gARC = [[RemoteCall alloc] initWithProcess:[NSString stringWithUTF8String:process] useMigFilterBypass:useMigFilterBypass];
    gARCInjected = NO;
    return gARC ? 0 : -1;
}

int init_remote_call_with_first_exception_timeout(const char *process, bool mig, int timeoutMS) {
    return init_remote_call(process, mig);
}

int init_remote_call_original_thread_only_with_first_exception_timeout(const char *process, bool mig, int timeoutMS) {
    return init_remote_call(process, mig);
}

static uint64_t arc_call_timeout(int timeout, const char *name, uint64_t pcAddr, const uint64_t *a) {
    if (!gARC || !name) return 0;
    void *fp = pcAddr ? (void *)(uintptr_t)pcAddr : dlsym(RTLD_DEFAULT, name);
    if (!fp) return 0;
    uint64_t args[8];
    for (int i = 0; i < 8; i++) args[i] = a ? a[i] : 0;
    return (uint64_t)[gARC doRemoteCallStableWithTimeout:timeout functionName:(char *)name functionPointer:fp args:args argCount:8];
}

uint64_t do_remote_call_stable(int timeout, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7) {
    uint64_t a[8] = {x0, x1, x2, x3, x4, x5, x6, x7};
    return arc_call_timeout(timeout, name, 0, a);
}

uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7) {
    uint64_t a[8] = {x0, x1, x2, x3, x4, x5, x6, x7};
    return arc_call_timeout(timeout, name, pcAddr, a);
}

bool remote_read(uint64_t src, void *dst, uint64_t size) {
    if (!gARC) return false;
    return [gARC remoteRead:src to:dst size:size];
}

uint64_t remote_read64(uint64_t src) {
    if (!gARC) return 0;
    return [gARC remoteRead64From:src];
}

bool remote_write(uint64_t dst, const void *src, uint64_t size) {
    if (!gARC) return false;
    return [gARC remote_write:dst from:src size:size];
}

bool remote_write64(uint64_t dst, uint64_t val) {
    if (!gARC) return false;
    return [gARC remote_write64:dst value:val];
}

bool remote_writeStr(uint64_t dst, const char *str) {
    if (!gARC) return false;
    return [gARC remote_write:dst string:str];
}

uint64_t remote_call_trojan_mem(void) {
    if (!gARC) return 0;
    return (uint64_t)gARC.trojanMem;
}

int destroy_remote_call(void) {
    if (gARC && !gARCInjected) {
        [gARC destroyRemoteCall];
    }
    gARC = nil;
    gARCInjected = NO;
    return 0;
}

void abandon_remote_call(void) {
    gARC = nil;
    gARCInjected = NO;
}

bool remote_call_has_local_state(void) { return gARC != nil; }
bool remote_call_current_success(void) { return gARC != nil; }
int  remote_call_current_pid(void) { return gARC ? (int)gARC.pid : 0; }
bool remote_call_uses_vphone_bridge(void) { return false; }
int  remote_call_set_stable_timeout_floor_ms(int timeoutMS) { return 0; }
RemoteCallInitFailure remote_call_last_init_failure(void) { return RemoteCallInitFailureNone; }
uint32_t remote_call_last_init_failure_pid(void) { return 0; }
const char *remote_call_init_failure_description(RemoteCallInitFailure failure) { return ""; }
