//
// ReynardGramDebug.m
//
// Diagnostic dylib: catches uncaught exceptions and fatal signals,
// and logs UIApplication lifecycle events to a file, so you can see
// exactly how far the app gets before it dies (login step, etc).
//
// The log is written to:
//   <AppContainer>/Documents/ReynardGramDebug.log
// which you can pull with the Files app (if "enable_icloud"/file sharing
// is on) or by re-opening the IPA/container with ESign/Filza-style tools.
// It's also mirrored to the system log via NSLog / os_log, visible in
// Console.app if you connect the device to a Mac.
//
// BUILD (needs a Mac + Xcode command line tools, or theos):
//
//   clang -dynamiclib -arch arm64 \
//     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//     -framework Foundation -framework UIKit \
//     ReynardGramDebug.m -o ReynardGramDebug.dylib
//
// Then ad-hoc sign it (needs to match the app's signing identity/team,
// or be signed with ldid for a jailbroken/TrollStore-style install):
//
//   ldid -S ReynardGramDebug.dylib
//
// INJECT into the IPA:
//   - ESign: when importing the .ipa, use its "Add dylib" option and
//     select ReynardGramDebug.dylib before signing/installing.
//   - AltStore/SideStore: use a dylib injection helper (e.g. a
//     zsign/insert_dylib based tool) to add
//     @executable_path/Frameworks/ReynardGramDebug.dylib
//     to the main binary's LC_LOAD_DYLIB commands, then resign.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <signal.h>
#import <pthread.h>

static NSString *LogFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"ReynardGramDebug.log"];
}

// Whole log kept in memory too, so we can shove the full text onto the
// clipboard after every single line — if the process dies a moment later,
// whatever was already copied stays on the clipboard for you to paste.
static NSMutableString *RGAccumulatedLog(void) {
    static NSMutableString *log = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = [NSMutableString string];
    });
    return log;
}

static void RGCopyToClipboard(void) {
    // UIPasteboard IPC from a signal handler is not strictly safe, but in
    // practice it's the only way to grab something when the app dies
    // before you can pull files off the device — good enough for debugging.
    [UIPasteboard generalPasteboard].string = RGAccumulatedLog();
}

static void RGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                           dateStyle:NSDateFormatterShortStyle
                                                           timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];

    // Mirror to system log (visible in Console.app over USB).
    NSLog(@"[ReynardGramDebug] %@", msg);

    // Append to a plain file so it survives even if the process dies
    // right after this call.
    NSString *path = LogFilePath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];

    // Keep the in-memory copy in sync and push it to the clipboard
    // immediately, every time — so whatever was logged last is always
    // what's sitting in the clipboard.
    [RGAccumulatedLog() appendString:line];
    RGCopyToClipboard();
}

static void RGLogBacktrace(void) {
    void *callstack[64];
    int frames = backtrace(callstack, 64);
    char **strs = backtrace_symbols(callstack, frames);
    for (int i = 0; i < frames; i++) {
        RGLog(@"  %s", strs[i]);
    }
    free(strs);
}

#pragma mark - Uncaught NSException handler

static void RGUncaughtExceptionHandler(NSException *exception) {
    RGLog(@"=== UNCAUGHT EXCEPTION ===");
    RGLog(@"Name: %@", exception.name);
    RGLog(@"Reason: %@", exception.reason);
    RGLog(@"UserInfo: %@", exception.userInfo);
    RGLog(@"Call stack:");
    for (NSString *frame in exception.callStackSymbols) {
        RGLog(@"  %@", frame);
    }
}

#pragma mark - Fatal signal handler

static void RGSignalHandler(int signal) {
    RGLog(@"=== FATAL SIGNAL %d ===", signal);
    RGLogBacktrace();
    // Restore default handler and re-raise so the OS still produces
    // its own .ips crash report as usual.
    struct sigaction action;
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(signal, &action, NULL);
    raise(signal);
}

static void RGInstallSignalHandler(int sig) {
    struct sigaction action;
    action.sa_handler = &RGSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(sig, &action, NULL);
}

#pragma mark - Lifecycle logging

@interface RGLifecycleObserver : NSObject
@end

@implementation RGLifecycleObserver

+ (void)load {
    // +load runs at dylib load time, before main() / applicationDidFinishLaunching.
    RGLog(@"=== dylib loaded, process starting ===");

    NSSetUncaughtExceptionHandler(&RGUncaughtExceptionHandler);
    RGInstallSignalHandler(SIGABRT);
    RGInstallSignalHandler(SIGSEGV);
    RGInstallSignalHandler(SIGBUS);
    RGInstallSignalHandler(SIGILL);
    RGInstallSignalHandler(SIGTRAP);
    RGInstallSignalHandler(SIGFPE);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self installNotificationObservers];
    });
}

+ (void)installNotificationObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray *names = @[
        UIApplicationDidFinishLaunchingNotification,
        UIApplicationDidBecomeActiveNotification,
        UIApplicationWillResignActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationWillEnterForegroundNotification,
        UIApplicationWillTerminateNotification,
        UIApplicationDidReceiveMemoryWarningNotification,
    ];
    for (NSString *name in names) {
        [nc addObserverForName:name
                         object:nil
                          queue:nil
                     usingBlock:^(NSNotification * _Nonnull note) {
            RGLog(@"lifecycle event: %@", note.name);
        }];
    }
    RGLog(@"lifecycle observers installed");
}

@end
