//
// ReynardGramDebug.m
//
// Diagnostic dylib: catches uncaught exceptions and fatal signals,
// logs UIApplication lifecycle events + window/rootVC state to a file
// so you can see exactly how far the app gets before the "black screen".
//
// The log is written to:
//   <AppContainer>/Documents/ReynardGramDebug.log
// Pull it via the Files app (if iTunes file sharing is on) or by
// re-opening the container with ESign/Filza/SSH. It's mirrored to
// NSLog/os_log (visible in Console.app over USB) and pushed onto the
// clipboard after every line, so the very last thing logged is always
// what's sitting on the clipboard even if the process dies instantly.
//
// BUILD (one-liner on macOS, or via GitHub Actions build-dylib.yml):
//
//   ./scripts/build_dylib.sh
//
// or raw:
//
//   clang -dynamiclib -arch arm64 -arch arm64e \
//     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//     -miphoneos-version-min=15.0 -fobjc-arc -fmodules -Os \
//     -framework Foundation -framework UIKit \
//     tools/ReynardGramDebug.m -o build/ReynardGramDebug.dylib
//   ldid -S build/ReynardGramDebug.dylib
//
// INJECT:
//   - ESign: "Add dylib" on import, point at ReynardGramDebug.dylib.
//   - Manual: insert_dylib @executable_path/Frameworks/ReynardGramDebug.dylib
//             into the main binary's LC_LOAD_DYLIB and resign.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <execinfo.h>
#include <signal.h>
#include <stdbool.h>
#include <sys/sysctl.h>

#pragma mark - Logging primitives

static NSString *LogFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"ReynardGramDebug.log"];
}

static NSString *LogAltFilePath(void) {
    // A fallback location that is *always* writable, just in case.
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReynardGramDebug.log"];
}

static NSMutableString *RGAccumulatedLog(void) {
    static NSMutableString *log = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [NSMutableString string]; });
    return log;
}

static void RGFlush(NSString *line) {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *p in @[LogFilePath(), LogAltFilePath()]) {
        @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
            [h seekToEndOfFile];
            [h writeData:data];
            [h closeFile];
        } @catch (__unused NSException *e) {}
    }
}

static void RGCopyToClipboard(void) {
    @try {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        if (pb) pb.string = RGAccumulatedLog();
    } @catch (__unused NSException *e) {}
}

static NSString *RGNow(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    return [fmt stringFromDate:[NSDate date]];
}

// RGLog is (carefully) safe to call from signal handlers *and* regular code.
// From regular ObjC code it uses the ObjC path; from a signal handler it
// does a minimal write(2) to the log fd and falls through.
static volatile sig_atomic_t RGInSignal = 0;
static int RGLogFd = -1;

static void RGLogSigSafe(const char *msg) {
    if (RGLogFd < 0) {
        // Best-effort open from the signal handler.
        NSString *p = LogAltFilePath();
        RGLogFd = open(p.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (RGLogFd >= 0) {
        size_t n = strlen(msg);
        (void)write(RGLogFd, msg, n);
        if (msg[n - 1] != '\n') (void)write(RGLogFd, "\n", 1);
    }
}

static void RGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", RGNow(), msg];
    NSLog(@"[ReynardGramDebug] %@", msg);
    RGFlush(line);
    [RGAccumulatedLog() appendString:line];
    RGCopyToClipboard();
}

static void RGLogBacktrace(void) {
    void *frames[64];
    int n = backtrace(frames, 64);
    char **syms = backtrace_symbols(frames, n);
    if (syms) {
        for (int i = 0; i < n; i++) RGLog(@"  %s", syms[i]);
        free(syms);
    }
}

#pragma mark - Uncaught exception + signal handlers

static void RGUncaughtExceptionHandler(NSException *ex) {
    RGInSignal = 1;
    RGLog(@"=== UNCAUGHT EXCEPTION ===");
    RGLog(@"name=%@ reason=%@", ex.name, ex.reason);
    RGLog(@"userInfo=%@", ex.userInfo);
    RGLog(@"callStack:");
    for (NSString *f in ex.callStackSymbols) RGLog(@"  %@", f);
    RGCopyToClipboard();
}

static void RGSignalHandler(int sig) {
    RGInSignal = 1;
    char buf[96];
    snprintf(buf, sizeof(buf), "=== FATAL SIGNAL %d (see log/clipboard) ===", sig);
    RGLogSigSafe(buf);
    // Flush ObjC-side buffer best-effort
    @try { RGLog(@"\n=== FATAL SIGNAL %d ===", sig); RGLogBacktrace(); } @catch (...) {}
    RGCopyToClipboard();
    // Restore default and re-raise
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL; sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    raise(sig);
}

static void RGInstallSignalHandler(int sig) {
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = RGSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
}

#pragma mark - Environment dump

static void RGDumpEnvironment(void) {
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    UIDevice *d = UIDevice.currentDevice;
    NSBundle *mb = NSBundle.mainBundle;
    RGLog(@"--- env ---");
    RGLog(@"process:  %@ (pid=%d)", pi.processName, getpid());
    RGLog(@"bundle:   id=%@ ver=%@ build=%@ path=%@",
          mb.bundleIdentifier,
          mb.infoDictionary[@"CFBundleShortVersionString"],
          mb.infoDictionary[@"CFBundleVersion"],
          mb.bundlePath);
    RGLog(@"device:   %@ %@ %@ (model=%@, name=%@)",
          d.systemName, d.systemVersion,
          d.identifierForVendor.UUIDString ?: @"-",
          d.model, d.name);
    RGLog(@"args:     %@", pi.arguments);
    RGLog(@"locale:   %@ tz=%@", NSLocale.currentLocale.localeIdentifier,
          [NSTimeZone localTimeZone].name);
    RGLog(@"screen:   bounds=%@ scale=%.1f",
          NSStringFromCGRect(UIScreen.mainScreen.bounds),
          UIScreen.mainScreen.scale);
    RGLog(@"dirs:     docs=%@ tmp=%@",
          NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject,
          NSTemporaryDirectory());
    @try {
        NSDictionary *info = mb.infoDictionary;
        for (NSString *k in @[@"MinimumOSVersion",
                              @"DTPlatformVersion",
                              @"DTSDKName",
                              @"UIRequiredDeviceCapabilities",
                              @"UILaunchStoryboardName",
                              @"UIMainStoryboardFile",
                              @"NSMainNibFile"]) {
            RGLog(@"info[%@] = %@", k, info[k] ?: @"(null)");
        }
    } @catch (NSException *e) { RGLog(@"info dict read failed: %@", e); }
    RGLog(@"--- /env ---");
}

#pragma mark - Window / rootVC diagnostics (the usual cause of black screens)

static NSString *RGDescView(UIView *v, int depth) {
    if (!v) return @"(null)";
    NSMutableString *out = [NSMutableString string];
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    [out appendFormat:@"%@- <%@:%p> frame=%@ hidden=%d alpha=%.2f bg=%@ subviews=%lu\n",
         pad, v.class, v,
         NSStringFromCGRect(v.frame),
         v.hidden ? 1 : 0, v.alpha,
         v.backgroundColor, (unsigned long)v.subviews.count];
    if (depth < 4) {
        for (UIView *sv in v.subviews) [out appendString:RGDescView(sv, depth+1)];
    }
    return out;
}

static void RGDumpUIState(NSString *tag) {
    @try {
        RGLog(@"=== UI state [%@] ===", tag);
        UIApplication *app = UIApplication.sharedApplication;
        NSArray<UIScene *> *scenes = app.connectedScenes.allObjects;
        RGLog(@"applicationState=%ld connectedScenes=%lu",
              (long)app.applicationState, (unsigned long)scenes.count);
        int wi = 0;
        for (UIScene *sc in scenes) {
            RGLog(@"scene[%d]: %@ activationState=%ld delegate=%@",
                  wi, sc.class, (long)sc.activationState, sc.delegate);
            if ([sc isKindOfClass:UIWindowScene.class]) {
                UIWindowScene *ws = (UIWindowScene *)sc;
                NSArray<UIWindow *> *windows = ws.windows;
                RGLog(@"  windows=%lu keyWindow=%@",
                      (unsigned long)windows.count, app.keyWindow);
                for (UIWindow *w in windows) {
                    RGLog(@"  window %p: key=%d visible=%d level=%.1f rootVC=%@ frame=%@",
                          w, w.isKeyWindow ? 1 : 0,
                          !w.hidden && w.alpha > 0.01 ? 1 : 0,
                          w.windowLevel,
                          w.rootViewController.class,
                          NSStringFromCGRect(w.frame));
                    if (w.rootViewController) {
                        UIViewController *vc = w.rootViewController;
                        NSMutableArray<NSString *> *stack = [NSMutableArray array];
                        UIViewController *cur = vc;
                        for (int d = 0; d < 10 && cur; d++) {
                            [stack addObject:[NSString stringWithFormat:@"%@%@%@",
                                              cur.class,
                                              cur.presentedViewController
                                                ? [NSString stringWithFormat:@" -> %@", cur.presentedViewController.class]
                                                : @"",
                                              [cur isViewLoaded] && cur.view.window
                                                ? @"(view-in-window)"
                                                : ([cur isViewLoaded] ? @"(view-loaded-no-window)" : @"(view-NOT-loaded)")]];
                            if ([cur isKindOfClass:UINavigationController.class]) {
                                UIViewController *top = ((UINavigationController *)cur).topViewController;
                                if (!top || top == cur) break;
                                cur = top;
                            } else if ([cur isKindOfClass:UITabBarController.class]) {
                                UIViewController *sel = ((UITabBarController *)cur).selectedViewController;
                                if (!sel) break;
                                cur = sel;
                            } else {
                                // Don't recurse arbitrarily.
                                break;
                            }
                        }
                        RGLog(@"    VC stack: %@", [stack componentsJoinedByString:@" > "]);
                        if ([vc isViewLoaded]) {
                            RGLog(@"    rootVC.view tree:\n%@",
                                  RGDescView(vc.view, 2));
                        }
                    }
                    RGLog(@"    window view tree:\n%@", RGDescView(w, 2));
                }
            }
            wi++;
        }
    } @catch (NSException *e) {
        RGLog(@"UI dump threw: %@ -> %@", e.name, e.reason);
    }
}

#pragma mark - Lifecycle / root-VC tracking

static void RGOnMain(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static void RGInstallPeriodicUIDump(void) {
    // Snapshot the UI at useful moments (and periodically for the first 15s)
    // so we can see *when* a root VC is set / why it stays black.
    dispatch_source_t t = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    __block int ticks = 0;
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
        2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        RGDumpUIState([NSString stringWithFormat:@"tick-%d", ticks]);
        ticks++;
        if (ticks > 10) {   // ~ 20s of life
            dispatch_source_cancel(t);
            RGLog(@"periodic UI dump ended");
        }
    });
    dispatch_resume(t);
}

static void RGHookRootVC(void) {
    // Swizzle -[UIWindow setRootViewController:] so we log exactly
    // which VC becomes the root and when.  We do the swizzle the
    // simple +class-exchange way.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = UIWindow.class;
        SEL origSel = @selector(setRootViewController:);
        SEL newSel  = NSSelectorFromString(@"_rg_setRootViewController:");
        Method orig = class_getInstanceMethod(c, origSel);
        IMP origImp = method_getImplementation(orig);
        id __block (^block)(id, UIViewController *) = ^id(id _self, UIViewController *vc) {
            RGLog(@">>> -[UIWindow setRootViewController:] called: window=%p newRootVC=%@(%p)",
                  _self, vc.class, vc);
            ((id(*)(id, SEL, UIViewController*))origImp)(_self, origSel, vc);
            // Give it a tick to layout, then dump the tree.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                RGDumpUIState(@"after-setRootVC");
            });
            return nil;
        };
        IMP newImp = imp_implementationWithBlock(block);
        class_replaceMethod(c, newSel, newImp, method_getTypeEncoding(orig));
        Method new = class_getInstanceMethod(c, newSel);
        method_exchangeImplementations(orig, new);
    });
}

#pragma mark - +load entry point

@interface RGLifecycleObserver : NSObject
@end

@implementation RGLifecycleObserver

+ (void)load {
    @autoreleasepool {
        // Open log fd early so signal handlers have something to write to.
        NSString *p = LogFilePath();
        [NSFileManager.defaultManager createFileAtPath:p contents:nil attributes:nil];
        RGLogFd = open(p.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);

        RGLog(@"========================================");
        RGLog(@"=== ReynardGramDebug dylib loaded  ===");
        RGLog(@"========================================");
        RGDumpEnvironment();

        NSSetUncaughtExceptionHandler(&RGUncaughtExceptionHandler);
        RGInstallSignalHandler(SIGABRT);
        RGInstallSignalHandler(SIGSEGV);
        RGInstallSignalHandler(SIGBUS);
        RGInstallSignalHandler(SIGILL);
        RGInstallSignalHandler(SIGTRAP);
        RGInstallSignalHandler(SIGFPE);
        RGInstallSignalHandler(SIGQUIT);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self installObservers];
            RGHookRootVC();
            RGDumpUIState(@"pre-launch");
            RGInstallPeriodicUIDump();
        });
    }
}

+ (void)installObservers {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSArray *pairs = @[
        UIApplicationDidFinishLaunchingNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationWillResignActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationWillEnterForegroundNotification,
        UIApplicationWillTerminateNotification,
        UIApplicationDidReceiveMemoryWarningNotification,
        @"UIWindowDidBecomeVisibleNotification",
        @"UIWindowDidBecomeHiddenNotification",
        @"UIWindowDidBecomeKeyNotification",
    ];
    for (NSString *name in pairs) {
        [nc addObserverForName:name object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            RGLog(@"lifecycle: %@ (object=%@ userInfo=%@)",
                  note.name, note.object, note.userInfo);
            if ([NSThread isMainThread]) {
                RGDumpUIState([@"after-" stringByAppendingString:note.name]);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    RGDumpUIState([@"after-" stringByAppendingString:note.name]);
                });
            }
        }];
    }
    RGLog(@"lifecycle observers installed");
}

@end
