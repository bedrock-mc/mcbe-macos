// Mac fixes for the iOS Minecraft client under PlayCover.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <netdb.h>
#import <notify.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <unistd.h>

// AppKit beeps for key events the game reads via GameController but never
// consumes through the responder chain. Text input is unaffected.
static IMP origNoResponderFor;

static void noResponderFor(id self, SEL _cmd, SEL eventSelector) {
    if (eventSelector == @selector(keyDown:)) {
        return;
    }
    ((void (*)(id, SEL, SEL))origNoResponderFor)(self, _cmd, eventSelector);
}

static void installNoBeep(void) {
    Class responder = objc_getClass("NSResponder");
    Method m = responder ? class_getInstanceMethod(responder, @selector(noResponderFor:)) : NULL;
    if (m) {
        origNoResponderFor = method_setImplementation(m, (IMP)noResponderFor);
        NSLog(@"[macfix] beep hook installed");
    } else {
        NSLog(@"[macfix] NSResponder -noResponderFor: not found");
    }
}

// Clicks and keys arrive through GameController handlers, which the game
// installs in -onConnectMouse: / -onConnectKeyboard: on whatever device is
// current at that moment. On the Mac the devices can connect before the game
// registers its observers (so the callbacks never run) or before they become
// current, and input is silently dead for the session: hover still works, but
// clicks or keys do nothing. The game also only sets up the current mouse, so
// with a trackpad and an external mouse, clicks from the other one are dead.
// Re-run the game's own setup for every mouse that has no handler, presenting
// it as the current one; handlers that are already installed are left alone.
static __weak id inputHandler;
static IMP origOnConnectMouse;
static IMP origOnConnectKeyboard;
static IMP origCurrentMouse;
static GCMouse *mouseBeingSetUp;

static GCMouse *currentMouse(id self, SEL _cmd) {
    return mouseBeingSetUp ?: ((GCMouse * (*)(id, SEL))origCurrentMouse)(self, _cmd);
}

static BOOL mouseHasHandler(GCMouse *mouse) {
    return mouse.mouseInput.leftButton.valueChangedHandler != nil;
}

static BOOL mouseReady(void) {
    for (GCMouse *mouse in GCMouse.mice) {
        if (!mouseHasHandler(mouse)) {
            return NO;
        }
    }
    return YES;
}

static BOOL keyboardReady(void) {
    GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
    return !keyboard || keyboard.keyboardInput.keyChangedHandler != nil;
}

static void onConnectMouse(id self, SEL _cmd, NSNotification *note) {
    inputHandler = self;
    ((void (*)(id, SEL, NSNotification *))origOnConnectMouse)(self, _cmd, note);
    NSLog(@"[macfix] game mouse setup: ready=%d", mouseReady());
}

static void onConnectKeyboard(id self, SEL _cmd, NSNotification *note) {
    inputHandler = self;
    ((void (*)(id, SEL, NSNotification *))origOnConnectKeyboard)(self, _cmd, note);
    NSLog(@"[macfix] game keyboard setup: ready=%d", keyboardReady());
}

static void repairInput(NSString *reason) {
    id handler = inputHandler;
    if (!handler) {
        return;
    }
    for (GCMouse *mouse in GCMouse.mice) {
        if (mouseHasHandler(mouse)) {
            continue;
        }
        NSNotification *note = [NSNotification notificationWithName:GCMouseDidConnectNotification object:mouse];
        mouseBeingSetUp = origCurrentMouse ? mouse : nil;
        ((void (*)(id, SEL, NSNotification *))origOnConnectMouse)(handler, sel_registerName("onConnectMouse:"), note);
        mouseBeingSetUp = nil;
        NSLog(@"[macfix] repaired mouse '%@' (%@): ready=%d", mouse.vendorName, reason, mouseHasHandler(mouse));
    }
    if (!keyboardReady()) {
        NSNotification *note = [NSNotification notificationWithName:GCKeyboardDidConnectNotification object:GCKeyboard.coalescedKeyboard];
        ((void (*)(id, SEL, NSNotification *))origOnConnectKeyboard)(handler, sel_registerName("onConnectKeyboard:"), note);
        NSLog(@"[macfix] repaired keyboard (%@): ready=%d", reason, keyboardReady());
    }
}

// Capture the handler when it registers, in case the connect callbacks never run.
static IMP origAddObserver;

static void addObserver(id self, SEL _cmd, id observer, SEL selector, NSNotificationName name, id object) {
    if (selector == sel_registerName("onConnectMouse:") || selector == sel_registerName("onConnectKeyboard:")) {
        // Registration can happen on any thread; inputHandler is only touched on main.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!inputHandler) {
                inputHandler = observer;
                NSLog(@"[macfix] captured game input handler");
            }
            repairInput(@"observer registered");
        });
    }
    ((void (*)(id, SEL, id, SEL, NSNotificationName, id))origAddObserver)(self, _cmd, observer, selector, name, object);
}

static IMP hook(Class cls, const char *selector, IMP replacement) {
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName(selector)) : NULL;
    return m ? method_setImplementation(m, replacement) : NULL;
}

static void installInputRepair(void) {
    Class cls = objc_lookUpClass("KeyboardAndMouseHandler_apple");
    origOnConnectMouse = hook(cls, "onConnectMouse:", (IMP)onConnectMouse);
    origOnConnectKeyboard = hook(cls, "onConnectKeyboard:", (IMP)onConnectKeyboard);
    if (!origOnConnectMouse || !origOnConnectKeyboard) {
        NSLog(@"[macfix] KeyboardAndMouseHandler_apple connect methods not found");
        return;
    }
    origAddObserver = hook([NSNotificationCenter class], "addObserver:selector:name:object:", (IMP)addObserver);
    origCurrentMouse = hook(object_getClass([GCMouse class]), "current", (IMP)currentMouse);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[GCMouseDidBecomeCurrentNotification, GCMouseDidConnectNotification,
                              GCKeyboardDidConnectNotification, @"UIApplicationDidBecomeActiveNotification"]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            // Let the game's own observers run first.
            dispatch_async(dispatch_get_main_queue(), ^{ repairInput(name); });
        }];
    }
    for (NSNumber *delay in @[@2, @5, @10]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ repairInput([NSString stringWithFormat:@"%@s", delay]); });
    }
    NSLog(@"[macfix] input repair installed");
}

// The game renders from its own display link, created in -startAnimation with
// the legacy setFrameInterval:, which pins it to 60 Hz on ProMotion displays.
// Set the range after the game has configured the link; other links (PlayTools
// uses one to deliver input) are left alone. MACFIX_FPS fixes the rate on AC;
// on battery or in Low Power Mode it is MACFIX_BATTERY_FPS (default 60, 0 = as on AC).
static IMP origStartAnimation;
static __weak id gameController;  // main thread only
static int acFps, batteryFps;  // 0 = 80-120 Hz
static BOOL onBattery, useUIDevice;
int macfixFpsCap;  // the agent's fps command; 0 = power-aware rate

void macfixApplyFrameRate(void) {
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    int fps = macfixFpsCap ?: ((onBattery || lowPower) && batteryFps ? batteryFps : acFps);
    CAFrameRateRange range = fps > 0 ? CAFrameRateRangeMake(fps, fps, fps) : CAFrameRateRangeMake(80, 120, 120);
    CADisplayLink *link = gameController ? ((id (*)(id, SEL))objc_msgSend)(gameController, sel_registerName("displayLink")) : nil;
    if ([link isKindOfClass:[CADisplayLink class]]) {
        link.preferredFrameRateRange = range;
        NSLog(@"[macfix] game display link at %.0f Hz (battery=%d low power=%d cap=%d)", range.preferred, onBattery,
              lowPower, macfixFpsCap);
    }
}

static void startAnimation(id self, SEL _cmd) {
    ((void (*)(id, SEL))origStartAnimation)(self, _cmd);
    gameController = self;
    macfixApplyFrameRate();
}

// NO when IOKit cannot read the power source (e.g. denied by the sandbox).
static BOOL readIOKitPowerSource(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFStringRef type = info ? IOPSGetProvidingPowerSourceType(info) : NULL;
    if (type) {
        onBattery = CFEqual(type, CFSTR(kIOPSBatteryPowerValue));
    }
    if (info) {
        CFRelease(info);
    }
    return type != NULL;
}

static void updatePowerSource(void) {
    if (useUIDevice) {
        onBattery = UIDevice.currentDevice.batteryState == UIDeviceBatteryStateUnplugged;
    } else {
        readIOKitPowerSource();
    }
}

static void powerChanged(void) {
    updatePowerSource();
    macfixApplyFrameRate();
}

static void installPowerAwareRate(void) {
    const char *ac = getenv("MACFIX_FPS"), *battery = getenv("MACFIX_BATTERY_FPS");
    acFps = ac ? MAX(atoi(ac), 0) : 0;
    batteryFps = battery ? MAX(atoi(battery), 0) : 60;
    useUIDevice = !readIOKitPowerSource();
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        if (useUIDevice) {
            // UIDevice reports unknown until monitoring is on.
            UIDevice.currentDevice.batteryMonitoringEnabled = YES;
            updatePowerSource();
            [nc addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *n) { powerChanged(); }];
        } else {
            int token;
            notify_register_dispatch(kIOPSNotifyPowerSource, &token, dispatch_get_main_queue(), ^(int t) { powerChanged(); });
        }
        [nc addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) { powerChanged(); }];
        NSLog(@"[macfix] power source via %s: battery=%d, battery rate %d FPS", useUIDevice ? "UIDevice" : "IOKit",
              onBattery, batteryFps);
        macfixApplyFrameRate();
    });
}

static void installFrameRate(void) {
    // The runtime object is the Impl subclass; hook whichever method it resolves to.
    Class cls = objc_lookUpClass("minecraftpeViewControllerImpl") ?: objc_lookUpClass("minecraftpeViewControllerBase");
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName("startAnimation")) : NULL;
    if (!m) {
        NSLog(@"[macfix] -startAnimation not found");
        return;
    }
    origStartAnimation = method_setImplementation(m, (IMP)startAnimation);
    NSLog(@"[macfix] frame rate hook installed");
    installPowerAwareRate();
}

// The game requests a pointer-lock update on every mouse move, and UIKit
// re-resolves the scene's lock state each time (~0.1 ms of main thread per
// event). Forward changes plus a 0.5 s refresh. MACFIX_POINTER_LOCK=every disables.
static IMP origSetNeedsPointerLock;
static int lastPointerLock = -1;
static double lastPointerLockUpdate;

static void setNeedsPointerLock(UIViewController *self, SEL _cmd) {
    int wanted = self.prefersPointerLocked;
    double t = CACurrentMediaTime();
    if (wanted == lastPointerLock && t - lastPointerLockUpdate < 0.5) {
        return;
    }
    lastPointerLock = wanted;
    lastPointerLockUpdate = t;
    ((void (*)(id, SEL))origSetNeedsPointerLock)(self, _cmd);
}

static void installPointerLockThrottle(void) {
    const char *mode = getenv("MACFIX_POINTER_LOCK");
    if (mode && !strcmp(mode, "every")) {
        return;
    }
    Class cls = objc_lookUpClass("minecraftpeViewControllerImpl") ?: objc_lookUpClass("minecraftpeViewControllerBase");
    SEL sel = sel_registerName("setNeedsUpdateOfPrefersPointerLocked");
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) {
        NSLog(@"[macfix] -setNeedsUpdateOfPrefersPointerLocked not found");
        return;
    }
    // Add an override on the game's class so other view controllers keep UIKit's implementation.
    origSetNeedsPointerLock = method_getImplementation(m);
    if (!class_addMethod(cls, sel, (IMP)setNeedsPointerLock, method_getTypeEncoding(m))) {
        origSetNeedsPointerLock = method_setImplementation(m, (IMP)setNeedsPointerLock);
    }
}

// UIKit ends the app with exit(), whose static destructors crash under the
// game's still-running threads and hang in its crash handler, leaving a
// windowless process that PlayCover can only reactivate. Once UIKit has
// delivered the termination callbacks (so the game has saved), skip them.
static atomic_bool terminating;
static IMP origTerminateWithStatus;

static void exitNow(int status) {
    NSLog(@"[macfix] termination callbacks done, exiting");
    _exit(status);
}

static void terminateWithStatus(id self, SEL _cmd, int status) {
    terminating = true;
    ((void (*)(id, SEL, int))origTerminateWithStatus)(self, _cmd, status);
    // Closing the last window leaves AppKit waiting inside -terminate: instead of exiting.
    exitNow(status);
}

// Catches AppKit's own exit and UIKit's termination watchdog.
static void safeExit(int status) {
    if (terminating) {
        exitNow(status);
    }
    exit(status);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} interposeExit = {(const void *)safeExit, (const void *)exit};

static void installCleanExit(void) {
    origTerminateWithStatus = hook(objc_getClass("UIApplication"), "_terminateWithStatus:", (IMP)terminateWithStatus);
    if (!origTerminateWithStatus) {
        NSLog(@"[macfix] -[UIApplication _terminateWithStatus:] not found");
    }
}

// When the game can't format a network interface's address (seen with a
// WireGuard utun interface), it resolves the placeholder "Error" as a hostname
// on the main thread every frame. macOS takes 5 s to fail a dotless name, so
// the game freezes after the loading screen. Fail that lookup immediately.
static atomic_bool loggedErrorLookup;

static int fastGetaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (node && strcmp(node, "Error") == 0) {
        if (!atomic_exchange(&loggedErrorLookup, true)) {
            NSLog(@"[macfix] failing lookup of placeholder host \"Error\"");
        }
        return EAI_NONAME;
    }
    return getaddrinfo(node, service, hints, res);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} interposeGetaddrinfo = {(const void *)fastGetaddrinfo, (const void *)getaddrinfo};

// The game's streaming workers spin on sched_yield between chunk jobs and
// rarely block: ~1.1M yields/s, over two cores of mostly kernel time. Once a
// thread is clearly spinning, sleep briefly instead. MACFIX_YIELD=spin disables.
static bool yieldBackoff = true;
static uint64_t spinGapTicks;

static int backoffYield(void) {
    static __thread struct {
        bool named, eligible;
        uint32_t streak;
        uint64_t last;
    } y;
    if (!y.named) {  // pools name their threads after they start
        char name[64] = "";
        pthread_getname_np(pthread_self(), name, sizeof(name));
        y.named = name[0] != 0;
        y.eligible = strncmp(name, "Streaming Pool", 14) == 0;
    }
    if (yieldBackoff && y.eligible) {
        uint64_t t = mach_absolute_time();
        y.streak = t - y.last < spinGapTicks ? y.streak + 1 : 0;
        y.last = t;
        if (y.streak >= 16) {
            // Long enough to free the core, short enough not to delay new jobs.
            nanosleep(&(struct timespec){0, 50000}, NULL);
            y.last = mach_absolute_time();
            return 0;
        }
    }
    return sched_yield();
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} interposeYield = {(const void *)backoffYield, (const void *)sched_yield};

static void installYieldBackoff(void) {
    const char *mode = getenv("MACFIX_YIELD");
    yieldBackoff = !(mode && !strcmp(mode, "spin"));
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    spinGapTicks = 20000ULL * tb.denom / tb.numer;  // yields under 20 µs apart
    NSLog(@"[macfix] spin backoff %s", yieldBackoff ? "on" : "off");
}

void agentStart(void);

__attribute__((constructor)) static void init(void) {
    installYieldBackoff();
    installFrameRate();
    installPointerLockThrottle();
    agentStart();
    installInputRepair();
    installCleanExit();
    // AppKit may not be loaded yet when this image initialises.
    if (objc_getClass("NSResponder")) {
        installNoBeep();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ installNoBeep(); });
    }
}
