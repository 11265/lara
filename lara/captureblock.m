//
//  captureblock.m
//  lara
//
//  Device-wide screenshot / screen-recording block (implements screenshotblock.h).
//
//  While lara has a live SpringBoard remote call, this finds SpringBoard's own
//  capture services and replaces their capture actions with a side-effect-free
//  implementation, so a screenshot or a recording start simply never happens.
//  The original IMPs are kept so the block can be lifted without a respring.
//
//  Discovery is deliberately cheap and safe: the candidate list is obtained by
//  *reading memory* (objc_copyClassNamesForImage + remote reads), not by calling
//  into the target for every name. Only the handful of methods that actually
//  match a capture action cost a remote call, because a plain objc_msgSend on
//  the hijacked thread is what killed the trojan thread in earlier attempts
//  (see clock_overlay.m). Every candidate and every decision is printed to
//  stdout, which lara's logger captures.
//

#import "screenshotblock.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Tunables

#define CAP_MAX_CLASS_SCAN      4096    /* class names to read from the image */
#define CAP_MAX_PATCHED         24      /* methods we remember for revert */
#define CAP_NAME_MAX            96
#define CAP_STATUS_MAX          512

/* Class-name fragments that mark a capture-related class. */
static const char *kCapClassKeywords[] = {
    "creenshot", "creencapture", "ScreenCapture",
    "ecording", "Recording", "creenrecord", "ScreenRecord",
};
#define CAP_CLASS_KEYWORD_COUNT (sizeof(kCapClassKeywords) / sizeof(kCapClassKeywords[0]))

/* Selector fragments that mark a capture action. */
static const char *kCapActionKeywords[] = {
    "creenshot", "creencapture", "ScreenCapture", "aptureScreen",
    "ecord", "Record", "irror",
};
#define CAP_ACTION_KEYWORD_COUNT (sizeof(kCapActionKeywords) / sizeof(kCapActionKeywords[0]))

/* Selector fragments that mean wiring/UI rather than the action itself. */
static const char *kCapSkipKeywords[] = {
    "set", "is", "has", "can", "should", "Observer", "Notification",
    "delegate", "Delegate", "will", "did", "Indicator", "View", "Window",
    "Assertion", "Scene", "Button", "Label", "Image",
};
#define CAP_SKIP_KEYWORD_COUNT (sizeof(kCapSkipKeywords) / sizeof(kCapSkipKeywords[0]))

#pragma mark - State

typedef struct {
    uint64_t method;            /* Method inside SpringBoard */
    uint64_t originalImp;
    char     selector[CAP_NAME_MAX];
} CapPatch;

static CapPatch gCapPatches[CAP_MAX_PATCHED];
static int      gCapPatchCount = 0;
static uint64_t gCapNoopImp = 0;
static char     gCapStatus[CAP_STATUS_MAX] = "not enabled";

static bool cap_ptr(uint64_t p)
{
    return p >= 0x100000000ULL;
}

static void cap_status(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gCapStatus, sizeof(gCapStatus), fmt, ap);
    va_end(ap);
    printf("(capblock) %s\n", gCapStatus);
    fflush(stdout);
}

static void cap_note(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char line[512];
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    printf("(capblock)   %s\n", line);
    fflush(stdout);
}

static bool cap_contains_any(const char *haystack, const char **needles, size_t count)
{
    if (!haystack) return false;
    for (size_t i = 0; i < count; i++) {
        if (strstr(haystack, needles[i]) != NULL) return true;
    }
    return false;
}

/* Reads a NUL terminated C string out of the target, with a printable-ASCII
   sanity check so a wrong address cannot be mistaken for a name. */
static bool cap_read_cstring(RemoteCall *proc, uint64_t addr, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    if (!cap_ptr(addr)) return false;
    if (![proc remoteRead:addr to:out size:outLen - 1]) return false;
    out[outLen - 1] = '\0';
    if (out[0] == '\0') return false;
    for (size_t i = 0; i < outLen - 1 && out[i]; i++) {
        unsigned char c = (unsigned char)out[i];
        if (c < 0x20 || c > 0x7e) { out[0] = '\0'; return false; }
    }
    return out[0] != '\0';
}

/* method_t is { SEL name; const char *types; IMP imp; } on absolute method
   lists, which is what the Apple runtime uses here; relative lists put small
   integers in the first slot, and then we fall back to the runtime accessors. */
static bool cap_method_is_absolute_layout(RemoteCall *proc, uint64_t method, uint64_t *nameAddr)
{
    uint64_t raw = 0;
    if (![proc remoteRead:method to:&raw size:sizeof(raw)]) return false;
    if (!cap_ptr(raw)) return false;                 /* looks like an offset, not a pointer */
    char probe[8] = {0};
    if (![proc remoteRead:raw to:probe size:sizeof(probe) - 1]) return false;
    if (probe[0] == '\0') return false;
    for (int i = 0; i < 7 && probe[i]; i++) {
        unsigned char c = (unsigned char)probe[i];
        if (c < 0x20 || c > 0x7e) return false;
    }
    if (nameAddr) *nameAddr = raw;
    return true;
}

/* Walks one class's methods and neutralises the capture actions. */
static int cap_process_class(RemoteCall *proc, uint64_t cls, const char *className)
{
    uint64_t countPtr = RemoteArbCall(proc, malloc, (uint64_t)sizeof(uint32_t));
    if (!countPtr) return 0;

    uint64_t list = RemoteArbCall(proc, class_copyMethodList, cls, countPtr);
    uint32_t count = 0;
    if (list) [proc remoteRead:countPtr to:&count size:sizeof(count)];
    RemoteArbCall(proc, free, countPtr);
    if (!list) return 0;

    cap_note("class %s: %u methods", className, count);

    int patched = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint64_t method = 0;
        if (![proc remoteRead:list + (uint64_t)i * 8 to:&method size:sizeof(method)] || !method) continue;

        char selector[CAP_NAME_MAX] = {0};
        uint64_t nameAddr = 0;
        if (cap_method_is_absolute_layout(proc, method, &nameAddr)) {
            cap_read_cstring(proc, nameAddr, selector, sizeof(selector));
        }
        if (selector[0] == '\0') {
            uint64_t sel = RemoteArbCall(proc, method_getName, method);
            uint64_t namePtr = sel ? RemoteArbCall(proc, sel_getName, sel) : 0;
            if (!namePtr) continue;
            if (![proc remoteRead:namePtr to:selector size:sizeof(selector) - 1]) continue;
            selector[sizeof(selector) - 1] = '\0';
        }
        if (selector[0] == '\0') continue;

        if (!cap_contains_any(selector, kCapActionKeywords, CAP_ACTION_KEYWORD_COUNT)) continue;

        cap_note("candidate %s", selector);

        if (cap_contains_any(selector, kCapSkipKeywords, CAP_SKIP_KEYWORD_COUNT)) {
            cap_note("  skip: wiring/UI, not the action");
            continue;
        }

        if (gCapPatchCount + patched >= CAP_MAX_PATCHED) {
            cap_note("  skip: patch limit %d reached", CAP_MAX_PATCHED);
            continue;
        }

        /* Type encoding: 'v' first means the method returns void, the only shape
           we can replace with a do-nothing implementation safely. */
        char encoding[32] = {0};
        if (nameAddr) {
            uint64_t encodingAddr = 0;
            if ([proc remoteRead:method + 8 to:&encodingAddr size:sizeof(encodingAddr)]) {
                cap_read_cstring(proc, encodingAddr, encoding, sizeof(encoding));
            }
        }
        if (encoding[0] == '\0') {
            uint64_t encPtr = RemoteArbCall(proc, method_getTypeEncoding, method);
            if (encPtr) [proc remoteRead:encPtr to:encoding size:sizeof(encoding) - 1];
        }
        if (encoding[0] != 'v') {
            cap_note("  skip: returns '%c', needs its own handling", encoding[0] ? encoding[0] : '?');
            continue;
        }

        /* Neutralise: remember the old IMP, then point the method at a function
           that only returns (-[NSObject class]). */
        uint64_t originalImp = RemoteArbCall(proc, method_getImplementation, method);
        int slot = gCapPatchCount + patched;
        gCapPatches[slot].method = method;
        gCapPatches[slot].originalImp = originalImp;
        strncpy(gCapPatches[slot].selector, selector, sizeof(gCapPatches[slot].selector) - 1);
        gCapPatches[slot].selector[sizeof(gCapPatches[slot].selector) - 1] = '\0';

        bool wrote = false;
        if (nameAddr) {
            /* Absolute layout: the IMP is the third field, so a plain write. */
            wrote = [proc remote_write64:method + 16 value:gCapNoopImp];
        }
        if (!wrote) {
            RemoteArbCall(proc, method_setImplementation, method, gCapNoopImp);
        }

        patched++;
        cap_note("  -> neutralised (screenshot/recording will be swallowed)");
    }

    RemoteArbCall(proc, free, list);
    gCapPatchCount += patched;
    return patched;
}

#pragma mark - Public API

int sb_capture_block_apply(RemoteCall *proc)
{
    if (!proc) {
        cap_status("failed: no RemoteCall");
        return 0;
    }

    /* The do-nothing implementation: -[NSObject class]. */
    gCapNoopImp = 0;
    uint64_t clsNSObject = remote_getClass(proc, "NSObject");
    if (cap_ptr(clsNSObject)) {
        uint64_t m = RemoteArbCall(proc, class_getInstanceMethod, clsNSObject, remote_sel(proc, "class"));
        if (m) gCapNoopImp = RemoteArbCall(proc, method_getImplementation, m);
    }
    if (!gCapNoopImp) {
        cap_status("failed: no neutral implementation available");
        return 0;
    }

    printf("(capblock) === blocking screenshots and screen recording ===\n");
    fflush(stdout);

    /* Class names of the SpringBoard image, read out of the target. */
    const char *image = "/System/Library/CoreServices/SpringBoard.app/SpringBoard";
    uint64_t imageBuf = remote_alloc_str(proc, image);
    uint64_t countPtr = imageBuf ? RemoteArbCall(proc, malloc, (uint64_t)sizeof(uint32_t)) : 0;
    uint32_t classCount = 0;
    uint64_t names = 0;
    if (imageBuf && countPtr) {
        names = RemoteArbCall(proc, objc_copyClassNamesForImage, imageBuf, countPtr);
        if (names) [proc remoteRead:countPtr to:&classCount size:sizeof(classCount)];
    }
    cap_note("SpringBoard classes: %u (names=0x%llx)", classCount, names);

    if (!names) {
        cap_status("failed: could not read SpringBoard's class list");
        if (countPtr) RemoteArbCall(proc, free, countPtr);
        if (imageBuf) RemoteArbCall(proc, free, imageBuf);
        return 0;
    }

    uint32_t limit = classCount > CAP_MAX_CLASS_SCAN ? CAP_MAX_CLASS_SCAN : classCount;
    int classesMatched = 0;
    for (uint32_t i = 0; i < limit; i++) {
        uint64_t namePtr = 0;
        if (![proc remoteRead:names + (uint64_t)i * 8 to:&namePtr size:sizeof(namePtr)] || !namePtr) continue;
        char className[CAP_NAME_MAX] = {0};
        if (!cap_read_cstring(proc, namePtr, className, sizeof(className))) continue;
        if (!cap_contains_any(className, kCapClassKeywords, CAP_CLASS_KEYWORD_COUNT)) continue;

        uint64_t cls = RemoteArbCall(proc, objc_getClass, namePtr);
        if (!cap_ptr(cls)) continue;

        classesMatched++;
        cap_process_class(proc, cls, className);
    }

    RemoteArbCall(proc, free, names);
    if (countPtr) RemoteArbCall(proc, free, countPtr);
    if (imageBuf) RemoteArbCall(proc, free, imageBuf);

    cap_status("matched %d capture classes, neutralised %d action methods (originals kept, revertible)",
               classesMatched, gCapPatchCount);
    return gCapPatchCount;
}

void sb_capture_block_revert(RemoteCall *proc)
{
    if (!proc) return;

    int restored = 0;
    for (int i = 0; i < gCapPatchCount; i++) {
        if (!gCapPatches[i].method) continue;
        RemoteArbCall(proc, method_setImplementation, gCapPatches[i].method, gCapPatches[i].originalImp);
        cap_note("restored %s", gCapPatches[i].selector);
        restored++;
    }
    memset(gCapPatches, 0, sizeof(gCapPatches));
    gCapPatchCount = 0;
    cap_status("restored %d methods, capture works again", restored);
}

bool sb_capture_block_active(void)
{
    return gCapPatchCount > 0;
}

const char *sb_capture_block_status(void)
{
    return gCapStatus;
}
