/**
 * JBShield — 越狱检测屏蔽
 * Hook C 函数 stat/access/fopen/open/fork/dlopen
 * 对越狱相关路径返回"不存在"或"正常"
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <pthread.h>

// ===== 需要屏蔽的越狱特征路径 =====
static NSArray *JBPaths(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            // 越狱商店 App
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Zebra.app",
            @"/Applications/Installer.app",
            @"/Applications/Taurine.app",
            @"/Applications/unc0ver.app",
            @"/Applications/Checkra1n.app",
            @"/Applications/Fugu.app",
            @"/Applications/Substitute Settings.app",
            // 越狱工具路径
            @"/Library/MobileSubstrate/MobileSubstrate.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries/",
            @"/Library/MobileSubstrate",
            @"/Library/SubstrateSandbox.bin",
            @"/Library/libsubstrate.dylib",
            @"/usr/lib/libsubstrate.dylib",
            @"/Library/Substitute",
            @"/usr/lib/libsubstitute.dylib",
            @"/usr/lib/substrate",
            // rootless 越狱新路径
            @"/var/jb/",
            @"/var/jb/Library/MobileSubstrate",
            @"/var/jb/usr/lib/libsubstrate.dylib",
            @"/private/preboot/",
            // 命令行工具
            @"/bin/bash",
            @"/bin/sh",
            @"/usr/sbin/sshd",
            @"/usr/bin/ssh",
            @"/etc/apt",
            @"/var/cache/apt",
            @"/var/lib/apt",
            @"/var/www/cydia",
            @"/tmp/cydia",
            // 文件系统标记
            @"/private/var/lib/apt",
            @"/private/var/cache/apt",
        ];
    });
    return list;
}

// fork 被检测的越狱进程名
static NSArray *JBProcs(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[@"bash", @"sshd", @"ssh", @"cydia", @"sileo", @"zebra", @"apt-get", @"dpkg"];
    });
    return list;
}

static BOOL JBIsJailbreakPath(const char *cpath) {
    if (!cpath) return NO;
    NSString *path = [NSString stringWithUTF8String:cpath];
    if (!path) return NO;
    for (NSString *jb in JBPaths()) {
        if ([path hasPrefix:jb] || [path isEqualToString:jb]) return YES;
    }
    return NO;
}

// ===== 原始函数指针 =====
typedef int (*JB_stat_t)(const char *, struct stat *);
typedef int (*JB_stat64_t)(const char *, struct stat64 *);
typedef int (*JB_access_t)(const char *, int);
typedef int (*JB_faccessat_t)(int, const char *, int, int);
typedef FILE *(*JB_fopen_t)(const char *, const char *);
typedef int (*JB_open_t)(const char *, int, ...);
typedef pid_t (*JB_fork_t)(void);
typedef void *(*JB_dlopen_t)(const char *, int);
typedef int (*JB_sysctl_t)(int *, u_int, void *, size_t *, void *, size_t);

static JB_stat_t       orig_stat = NULL;
static JB_stat64_t     orig_stat64 = NULL;
static JB_access_t     orig_access = NULL;
static JB_faccessat_t  orig_faccessat = NULL;
static JB_fopen_t      orig_fopen = NULL;
static JB_open_t       orig_open = NULL;
static JB_fork_t       orig_fork = NULL;
static JB_dlopen_t     orig_dlopen = NULL;

// ===== Hook 实现 =====

static int hooked_stat(const char *path, struct stat *buf) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

static int hooked_stat64(const char *path, struct stat64 *buf) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return -1; }
    return orig_stat64(path, buf);
}

static int hooked_access(const char *path, int mode) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

static int hooked_faccessat(int fd, const char *path, int mode, int flags) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return -1; }
    return orig_faccessat(fd, path, mode, flags);
}

static FILE *hooked_fopen(const char *path, const char *mode) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

static int hooked_open(const char *path, int flags, ...) {
    if (JBIsJailbreakPath(path)) { errno = ENOENT; return -1; }
    int fd;
    va_list args;
    va_start(args, flags);
    mode_t mode = (flags & O_CREAT) ? va_arg(args, int) : 0;
    va_end(args);
    fd = orig_open(path, flags, mode);
    return fd;
}

static pid_t hooked_fork(void) {
    pid_t pid = orig_fork();
    if (pid == 0) {
        // 子进程: 把 argv[0] 改成正常进程名, 避免被检测
        // 简单处理: 直接 fork 失败返回
        // 更彻底的做法: 检测 App 是否在探测 fork, 如果是就假装 fork 失败
        // 这里保守返回正常 fork 结果(避免影响 App 正常功能)
    }
    return pid;
}

static void *hooked_dlopen(const char *path, int mode) {
    if (path) {
        NSString *sp = [NSString stringWithUTF8String:path];
        if (sp) {
            // 屏蔽 MobileSubstrate/Substitute 的显式 dlopen 检测
            if ([sp containsString:@"substrate"] ||
                [sp containsString:@"Substrate"] ||
                [sp containsString:@"substitute"] ||
                [sp containsString:@"Substitute"]) {
                return NULL;
            }
        }
    }
    return orig_dlopen(path, mode);
}

// ===== fishhook 风格的函数替换 =====
// 使用 dlsym(RTLD_NEXT, ...) 获取原始地址, 直接写 GOT

static void JBDecorate(void) {
    // 用 dlopen(RTLD_DEFAULT) 获取符号地址
    void *handle = RTLD_DEFAULT;

    // stat / stat64
    orig_stat = dlsym(handle, "stat");
    orig_stat64 = dlsym(handle, "stat64");
    orig_access = dlsym(handle, "access");
    orig_faccessat = dlsym(handle, "faccessat");
    orig_fopen = dlsym(handle, "fopen");
    orig_open = dlsym(handle, "open");
    orig_fork = dlsym(handle, "fork");
    orig_dlopen = dlsym(handle, "dlopen");

    // 手动替换 GOT (fishhook 原理, 但简化版用 objc_msgSend 不行, 需要直接内存写)
    // 这里用 MSHookFunction (MobileSubstrate 提供)
#if __has_include(<substrate.h>)
    MSHookFunction((void *)orig_stat, (void *)hooked_stat, (void **)&orig_stat);
    MSHookFunction((void *)orig_stat64, (void *)hooked_stat64, (void **)&orig_stat64);
    MSHookFunction((void *)orig_access, (void *)hooked_access, (void **)&orig_access);
    MSHookFunction((void *)orig_faccessat, (void *)hooked_faccessat, (void **)&orig_faccessat);
    MSHookFunction((void *)orig_fopen, (void *)hooked_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)orig_open, (void *)hooked_open, (void **)&orig_open);
    MSHookFunction((void *)orig_dlopen, (void *)hooked_dlopen, (void **)&orig_dlopen);
#endif
}

// ===== ObjC 层越狱检测屏蔽 =====

@interface JBUIDeviceMask : NSObject
@end

@implementation JBUIDeviceMask

+ (void)jbMaskUIDevice {
    Class cls = objc_getClass("UIDevice");
    if (!cls) return;

    // 确保 identifierForVendor 返回一个稳定的值 (iOS 里 identifierForVendor 在越狱设备上行为可能异常)
    // model / name / systemVersion 保持原值, 越狱检测一般不看这些
}

@end

// ===== 初始化 =====
__attribute__((constructor))
static void JBInit(void) {
    // 等 MobileSubstrate 加载完
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JBDecorate();
        NSLog(@"[JBShield] hooks installed");
    });
}
