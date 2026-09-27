// Agent socket: line-delimited JSON over TCP on 127.0.0.1:$MACFIX_AGENT_PORT,
// the protocol of the bedrock-mc mcpelauncher fork's --agent-socket. Input is
// injected through the game's own GameController and pointer handlers on the
// main thread; frames are copied from the drawable right before present.
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/socket.h>

extern int macfixFpsCap;  // main thread only
void macfixApplyFrameRate(void);

static double mouseX, mouseY;  // last absolute position, in screenshot pixels; main thread only

#pragma mark - Game objects

static UIViewController *gameViewController(void) {
    id delegate = UIApplication.sharedApplication.delegate;
    SEL sel = sel_registerName("viewController");
    return [delegate respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(delegate, sel) : nil;
}

static UIView *findFirstResponder(UIView *view) {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = findFirstResponder(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

// The focused text input (chat, sign, text fields), if any.
static UIView<UIKeyInput> *focusedTextInput(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *view = findFirstResponder(window);
            if ([view conformsToProtocol:@protocol(UIKeyInput)]) {
                return (UIView<UIKeyInput> *)view;
            }
        }
    }
    return nil;
}

#pragma mark - Frames

static atomic_bool captureRequested;
static atomic_bool readbackEnabled;
static CAMetalLayer *gameLayer;  // set from the render thread, read on main
static dispatch_semaphore_t captureDone;
static id<MTLTexture> captureTexture;  // written by the render thread before captureDone signals
static atomic_int frameWidth, frameHeight;
static atomic_int presentsInWindow;
static _Atomic double windowStart, lastPresent, measuredFps;
static IMP origPresentDrawable;

static double now(void) {
    return CACurrentMediaTime();
}

static void countPresent(void) {
    double t = now();
    lastPresent = t;
    int n = atomic_fetch_add(&presentsInWindow, 1) + 1;
    double start = windowStart;
    if (t - start >= 1.0) {
        measuredFps = n / (t - start);
        presentsInWindow = 0;
        windowStart = t;
    }
}

static double currentFps(void) {
    return now() - lastPresent > 1.0 ? 0 : measuredFps;
}

#pragma mark - Frame timing

// Timestamps for frame_stats; each series has a single writer thread.
enum { kRing = 1 << 15 };
typedef struct {
    double t[kRing];
    atomic_uint n;
} Series;
static Series submits, presents, drawStarts;
static atomic_uint dropped;
static double drawCost[kRing];  // drawFrame duration, indexed like drawStarts

static void record(Series *s, double t) {
    unsigned i = atomic_load_explicit(&s->n, memory_order_relaxed);
    s->t[i % kRing] = t;
    atomic_store_explicit(&s->n, i + 1, memory_order_release);
}

static int cmpDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

// Percentiles of values in ms; sorts in place.
static NSDictionary *percentiles(double *v, unsigned n, double span) {
    if (n < 2) {
        return @{@"n": @(n)};
    }
    qsort(v, n, sizeof(double), cmpDouble);
    double sum = 0;
    unsigned over = 0;
    for (unsigned i = 0; i < n; i++) {
        sum += v[i];
    }
    double p50 = v[n / 2];
    for (unsigned i = 0; i < n; i++) {
        over += v[i] > p50 * 1.5;
    }
#define R(x) @(round((x) * 100) / 100)
    NSMutableDictionary *d = [@{@"n": @(n), @"mean": R(sum / n), @"p50": R(p50), @"p90": R(v[n * 90 / 100]),
                                @"p95": R(v[n * 95 / 100]), @"p99": R(v[n * 99 / 100]), @"max": R(v[n - 1]),
                                @"over_1_5x_p50": @(over)} mutableCopy];
    if (span > 0) {
        d[@"fps"] = R(n / span);
    }
#undef R
    return d;
}

static NSDictionary *intervalStats(Series *s, unsigned from) {
    unsigned to = atomic_load_explicit(&s->n, memory_order_acquire);
    if (to - from > kRing) {
        from = to - kRing;
    }
    if (to - from < 3) {
        return @{@"n": @0};
    }
    unsigned n = to - from - 1;
    double *v = malloc(n * sizeof(double));
    for (unsigned i = 0; i < n; i++) {
        v[i] = (s->t[(from + i + 1) % kRing] - s->t[(from + i) % kRing]) * 1000;
    }
    double span = s->t[(to - 1) % kRing] - s->t[from % kRing];
    NSDictionary *d = percentiles(v, n, span);
    free(v);
    return d;
}

static NSDictionary *costStats(unsigned from) {
    unsigned to = atomic_load_explicit(&drawStarts.n, memory_order_acquire);
    if (to - from > kRing) {
        from = to - kRing;
    }
    if (to - from < 3) {
        return @{@"n": @0};
    }
    unsigned n = to - from - 1;  // the newest entry may still be running
    double *v = malloc(n * sizeof(double));
    for (unsigned i = 0; i < n; i++) {
        v[i] = drawCost[(from + i) % kRing] * 1000;
    }
    NSDictionary *d = percentiles(v, n, 0);
    free(v);
    return d;
}

static unsigned submitsFrom, presentsFrom, drawsFrom, droppedFrom;
static double statsFrom;

// CPU time per thread (µs), keyed by thread id, with its pool name ("Streaming Pool(3)" -> "Streaming Pool").
static NSDictionary<NSNumber *, NSArray *> *threadTimes(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    thread_act_array_t list;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) {
        return out;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_extended_info_data_t ext;
        thread_identifier_info_data_t ident;
        mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT, in = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(list[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &n) == KERN_SUCCESS &&
            thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &in) == KERN_SUCCESS) {
            NSString *name = @(ext.pth_name);
            NSRange paren = [name rangeOfString:@"("];
            if (paren.location != NSNotFound) {
                name = [name substringToIndex:paren.location];
            }
            out[@(ident.thread_id)] = @[name.length ? name : @"(unnamed)", @(ext.pth_user_time / 1000), @(ext.pth_system_time / 1000)];
        }
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
    return out;
}

static NSDictionary *cpuFrom;

// CPU % (100 = one core) by thread group since the last reset, split into user and system.
static NSDictionary *cpuStats(double span) {
    NSDictionary *nowTimes = threadTimes();
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
    double totalUser = 0, totalSys = 0;
    for (NSNumber *tid in nowTimes) {
        NSArray *cur = nowTimes[tid], *old = cpuFrom[tid];
        double user = [cur[1] doubleValue] - [old[1] doubleValue], sys = [cur[2] doubleValue] - [old[2] doubleValue];
        NSMutableArray *g = groups[cur[0]] ?: (groups[cur[0]] = [@[@0.0, @0.0, @0] mutableCopy]);
        g[0] = @([g[0] doubleValue] + user);
        g[1] = @([g[1] doubleValue] + sys);
        g[2] = @([g[2] intValue] + 1);
        totalUser += user;
        totalSys += sys;
    }
    double scale = span > 0 ? 100 / (span * 1e6) : 0;
    NSMutableDictionary *byGroup = [NSMutableDictionary dictionary];
    for (NSString *name in groups) {
        NSArray *g = groups[name];
        double total = ([g[0] doubleValue] + [g[1] doubleValue]) * scale;
        if (total >= 1) {
            byGroup[name] = @{@"user": @(round([g[0] doubleValue] * scale)), @"sys": @(round([g[1] doubleValue] * scale)),
                              @"threads": g[2]};
        }
    }
    return @{@"total": @(round((totalUser + totalSys) * scale)), @"user": @(round(totalUser * scale)),
             @"sys": @(round(totalSys * scale)), @"groups": byGroup};
}

static id syncOnMain(id (^block)(void));

// macOS drops every present (presentedTime 0) while no part of the app is visible, e.g. under the screen saver.
static NSNumber *onScreen(void) {
    return syncOnMain(^id {
        id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
        NSUInteger occlusion = ((NSUInteger (*)(id, SEL))objc_msgSend)(app, sel_registerName("occlusionState"));
        return @((occlusion & (1 << 1)) != 0);  // NSApplicationOcclusionStateVisible
    });
}

// Intervals between submitted and on-screen presents, and main-thread drawFrame cost, since the last reset.
static NSDictionary *frameStats(NSDictionary *req) {
    NSDictionary *d = @{@"ok": @YES, @"on_screen": onScreen(), @"submit_interval_ms": intervalStats(&submits, submitsFrom),
                        @"present_interval_ms": intervalStats(&presents, presentsFrom),
                        @"drawframe_interval_ms": intervalStats(&drawStarts, drawsFrom),
                        @"drawframe_cost_ms": costStats(drawsFrom), @"dropped": @(atomic_load(&dropped) - droppedFrom),
                        @"cpu_percent": cpuStats(now() - statsFrom)};
    if ([req[@"reset"] boolValue]) {
        submitsFrom = atomic_load(&submits.n);
        presentsFrom = atomic_load(&presents.n);
        drawsFrom = atomic_load(&drawStarts.n);
        droppedFrom = atomic_load(&dropped);
        cpuFrom = threadTimes();
        statsFrom = now();
    }
    if (req[@"label"]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:NULL];
        NSLog(@"[macfix] frame_stats %@: %@", req[@"label"], [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    }
    return d;
}

static IMP origDrawFrame;

static void drawFrame(id self, SEL _cmd) {
    double t = now();
    unsigned i = atomic_load_explicit(&drawStarts.n, memory_order_relaxed);
    record(&drawStarts, t);
    ((void (*)(id, SEL))origDrawFrame)(self, _cmd);
    drawCost[i % kRing] = now() - t;
}

static void installDrawFrameHook(void) {
    Class cls = objc_lookUpClass("minecraftpeViewControllerImpl") ?: objc_lookUpClass("minecraftpeViewControllerBase");
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName("drawFrame")) : NULL;
    if (m) {
        origDrawFrame = method_setImplementation(m, (IMP)drawFrame);
    }
}

static void presentDrawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    countPresent();
    record(&submits, now());
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
        if (d.presentedTime > 0) {  // 0 when the frame was dropped
            record(&presents, d.presentedTime);
        } else {
            atomic_fetch_add(&dropped, 1);
        }
    }];
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<CAMetalDrawable> metal = (id<CAMetalDrawable>)drawable;
        id<MTLTexture> src = metal.texture;
        frameWidth = (int)src.width;
        frameHeight = (int)src.height;
        if (gameLayer != metal.layer) {
            gameLayer = metal.layer;
        }
        if (src.framebufferOnly) {
            // Readback needs a blittable drawable; enabled per screenshot since it costs frame time.
            if (captureRequested && !atomic_exchange(&readbackEnabled, true)) {
                CAMetalLayer *layer = metal.layer;
                dispatch_async(dispatch_get_main_queue(), ^{ layer.framebufferOnly = NO; });
            }
        } else if (atomic_exchange(&captureRequested, false)) {
            id<MTLCommandBuffer> buffer = self;
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                            width:src.width
                                                                                           height:src.height
                                                                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;
            desc.storageMode = MTLStorageModePrivate;
            id<MTLTexture> copy = [buffer.device newTextureWithDescriptor:desc];
            id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
            [blit copyFromTexture:src toTexture:copy];
            [blit endEncoding];
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
                captureTexture = copy;
                dispatch_semaphore_signal(captureDone);
            }];
            CAMetalLayer *layer = metal.layer;
            dispatch_async(dispatch_get_main_queue(), ^{
                layer.framebufferOnly = YES;
                readbackEnabled = false;
            });
        }
    }
    ((void (*)(id, SEL, id))origPresentDrawable)(self, _cmd, drawable);
}

// The game's command buffers are a private driver class; hook the
// implementation that a buffer from the default device resolves to.
static void installPresentHook(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandBuffer> buffer = [[device newCommandQueue] commandBuffer];
    Method m = buffer ? class_getInstanceMethod([buffer class], @selector(presentDrawable:)) : NULL;
    if (!m) {
        NSLog(@"[macfix] agent: no presentDrawable: to hook, screenshots disabled");
        return;
    }
    origPresentDrawable = method_setImplementation(m, (IMP)presentDrawable);
    NSLog(@"[macfix] agent: present hook on %@", NSStringFromClass([buffer class]));
}

static NSData *encodePNG(CGImageRef image) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}

static NSDictionary *screenshot(NSDictionary *req) {
    captureRequested = true;
    if (dispatch_semaphore_wait(captureDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        captureRequested = false;
        return @{@"ok": @NO, @"error": @"no frame rendered within 3s"};
    }
    id<MTLTexture> texture = captureTexture;
    captureTexture = nil;
    int srcW = (int)texture.width, srcH = (int)texture.height;
    int w = [req[@"width"] intValue], h = [req[@"height"] intValue];
    if (w <= 0 && h <= 0) {
        w = srcW;
        h = srcH;
    } else if (w <= 0) {
        w = MAX(1, srcW * h / srcH);
    } else if (h <= 0) {
        h = MAX(1, srcH * w / srcW);
    }
    w = MIN(w, srcW);
    h = MIN(h, srcH);

    static CIContext *context;
    static CGColorSpaceRef srgb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithMTLDevice:texture.device];
        srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    // Metal textures are top-down; Core Image is bottom-up.
    CIImage *image = [[CIImage imageWithMTLTexture:texture options:@{kCIImageColorSpace: (__bridge id)srgb}]
        imageByApplyingOrientation:kCGImagePropertyOrientationDownMirrored];
    CGImageRef full = [context createCGImage:image fromRect:image.extent format:kCIFormatBGRA8 colorSpace:srgb];
    CGContextRef bitmap = CGBitmapContextCreate(NULL, w, h, 8, 0, srgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, w, h), full);
    CGImageRef scaled = CGBitmapContextCreateImage(bitmap);
    NSData *png = encodePNG(scaled);
    CGImageRelease(scaled);
    CGContextRelease(bitmap);
    CGImageRelease(full);
    if (!png) {
        return @{@"ok": @NO, @"error": @"PNG encoding failed"};
    }
    return @{@"ok": @YES, @"width": @(w), @"height": @(h), @"source_width": @(srcW), @"source_height": @(srcH),
             @"png_base64": [png base64EncodedStringWithOptions:0]};
}

#pragma mark - Input

static void onMain(double delayMs, dispatch_block_t block) {
    if (delayMs <= 0) {
        dispatch_async(dispatch_get_main_queue(), block);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), block);
    }
}

static id syncOnMain(id (^block)(void)) {
    __block id result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static GCKeyCode keyCodeFromName(NSString *name) {
    name = name.lowercaseString;
    if (name.length == 1) {
        unichar c = [name characterAtIndex:0];
        if (c >= 'a' && c <= 'z') {
            return GCKeyCodeKeyA + (c - 'a');
        }
        if (c >= '1' && c <= '9') {
            return GCKeyCodeOne + (c - '1');
        }
        if (c == '0') {
            return GCKeyCodeZero;
        }
        if (c == ' ') {
            return GCKeyCodeSpacebar;
        }
    }
    if (name.length >= 2 && [name characterAtIndex:0] == 'f') {
        int n = [name substringFromIndex:1].intValue;
        if (n >= 1 && n <= 12) {
            return GCKeyCodeF1 + (n - 1);
        }
    }
    static NSDictionary<NSString *, NSNumber *> *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{
            @"space": @(GCKeyCodeSpacebar), @"enter": @(GCKeyCodeReturnOrEnter), @"return": @(GCKeyCodeReturnOrEnter),
            @"escape": @(GCKeyCodeEscape), @"esc": @(GCKeyCodeEscape), @"tab": @(GCKeyCodeTab),
            @"backspace": @(GCKeyCodeDeleteOrBackspace), @"delete": @(GCKeyCodeDeleteForward), @"insert": @(GCKeyCodeInsert),
            @"shift": @(GCKeyCodeLeftShift), @"lshift": @(GCKeyCodeLeftShift), @"rshift": @(GCKeyCodeRightShift),
            @"ctrl": @(GCKeyCodeLeftControl), @"lctrl": @(GCKeyCodeLeftControl), @"rctrl": @(GCKeyCodeRightControl),
            @"alt": @(GCKeyCodeLeftAlt), @"lalt": @(GCKeyCodeLeftAlt), @"ralt": @(GCKeyCodeRightAlt),
            @"super": @(GCKeyCodeLeftGUI), @"cmd": @(GCKeyCodeLeftGUI), @"meta": @(GCKeyCodeLeftGUI),
            @"up": @(GCKeyCodeUpArrow), @"down": @(GCKeyCodeDownArrow), @"left": @(GCKeyCodeLeftArrow), @"right": @(GCKeyCodeRightArrow),
            @"home": @(GCKeyCodeHome), @"end": @(GCKeyCodeEnd), @"pageup": @(GCKeyCodePageUp), @"pagedown": @(GCKeyCodePageDown),
            @"capslock": @(GCKeyCodeCapsLock), @"pause": @(GCKeyCodePause),
            @"comma": @(GCKeyCodeComma), @"period": @(GCKeyCodePeriod), @"slash": @(GCKeyCodeSlash),
            @"semicolon": @(GCKeyCodeSemicolon), @"apostrophe": @(GCKeyCodeQuote), @"minus": @(GCKeyCodeHyphen),
            @"equal": @(GCKeyCodeEqualSign), @"grave": @(GCKeyCodeGraveAccentAndTilde), @"lbracket": @(GCKeyCodeOpenBracket),
            @"rbracket": @(GCKeyCodeCloseBracket), @"backslash": @(GCKeyCodeBackslash),
        };
    });
    return named[name].integerValue;
}

// Delivers a key the way GameController does; the game only listens to the handler.
static void sendKey(GCKeyCode code, BOOL pressed) {
    GCKeyboardInput *input = GCKeyboard.coalescedKeyboard.keyboardInput;
    GCKeyboardValueChangedHandler handler = input.keyChangedHandler;
    if (handler) {
        handler(input, [input buttonForKeyCode:code], code, pressed);
    }
}

// With a text field focused, Return and Backspace edit or submit through UIKit, not GameController.
static void sendTextKey(GCKeyCode code) {
    UIView<UIKeyInput> *input = focusedTextInput();
    if (!input) {
        return;
    }
    if (code == GCKeyCodeDeleteOrBackspace) {
        [input deleteBackward];
    } else if (code == GCKeyCodeReturnOrEnter) {
        SEL setPhysical = sel_registerName("setPhysicalReturnPressed:");
        BOOL physical = [input respondsToSelector:setPhysical];
        if (physical) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(input, setPhysical, YES);
        }
        [input insertText:@"\n"];
        if (physical) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(input, setPhysical, NO);
        }
    }
}

static NSDictionary *handleKey(NSDictionary *req) {
    GCKeyCode code = keyCodeFromName(req[@"key"] ?: @"");
    if (code == 0) {
        return @{@"ok": @NO, @"error": @"unknown key"};
    }
    NSNumber *ready = syncOnMain(^id { return @(GCKeyboard.coalescedKeyboard.keyboardInput.keyChangedHandler != nil); });
    if (!ready.boolValue) {
        return @{@"ok": @NO, @"error": @"the game has no keyboard handler yet"};
    }
    NSMutableArray<NSNumber *> *mods = [NSMutableArray array];
    for (NSString *m in [req[@"mods"] isKindOfClass:[NSArray class]] ? req[@"mods"] : @[]) {
        GCKeyCode mc = [m isEqual:@"super"] ? GCKeyCodeLeftGUI : keyCodeFromName(m);
        if (mc) {
            [mods addObject:@(mc)];
        }
    }
    NSString *action = req[@"action"] ?: @"tap";
    double hold = req[@"hold_ms"] ? [req[@"hold_ms"] doubleValue] : 60;
    BOOL tap = [action isEqual:@"tap"];
    if (tap || [action isEqual:@"press"]) {
        onMain(0, ^{
            for (NSNumber *m in mods) {
                sendKey(m.integerValue, YES);
            }
            sendKey(code, YES);
            sendTextKey(code);
        });
    }
    if (tap || [action isEqual:@"release"]) {
        onMain(tap ? hold : 0, ^{
            sendKey(code, NO);
            for (NSNumber *m in mods.reverseObjectEnumerator) {
                sendKey(m.integerValue, NO);
            }
        });
    }
    return @{@"ok": @YES};
}

static NSDictionary *handleText(NSDictionary *req) {
    NSString *text = req[@"text"] ?: @"";
    return syncOnMain(^id {
        UIView<UIKeyInput> *input = focusedTextInput();
        if (!input) {
            return @{@"ok": @NO, @"error": @"no text field is focused (open chat or click a text box first)"};
        }
        [input insertText:text];
        return @{@"ok": @YES};
    });
}

// Stands in for the UIPointerRegionRequest the game's hover handler reads.
@interface MacfixPointerRequest : NSObject
@property(nonatomic) CGPoint location;
@end
@implementation MacfixPointerRequest
@end

static CGPoint pixelsToPoints(UIView *view, double x, double y) {
    int w = frameWidth;
    double scale = w > 0 ? view.bounds.size.width / w : 1;
    return CGPointMake(x * scale, y * scale);
}

static NSString *movePointer(double x, double y) {
    UIViewController *vc = gameViewController();
    SEL sel = sel_registerName("pointerInteraction:regionForRequest:defaultRegion:");
    if (![vc respondsToSelector:sel]) {
        return @"the game view is not ready";
    }
    mouseX = x;
    mouseY = y;
    MacfixPointerRequest *request = [MacfixPointerRequest new];
    request.location = pixelsToPoints(vc.view, x, y);
    ((id (*)(id, SEL, id, id, id))objc_msgSend)(vc, sel, nil, request, nil);
    return nil;
}

static GCControllerButtonInput *mouseButton(int button) {
    GCMouseInput *input = GCMouse.current.mouseInput;
    switch (button) {
        case 2: return input.rightButton;
        case 3: return input.middleButton;
        default: return input.leftButton;
    }
}

static void sendButton(int button, BOOL pressed) {
    GCControllerButtonInput *b = mouseButton(button);
    GCControllerButtonValueChangedHandler handler = b.valueChangedHandler;
    if (handler) {
        handler(b, pressed ? 1 : 0, pressed);
    }
}

static int buttonFromRequest(NSDictionary *req) {
    id b = req[@"button"];
    if ([b isKindOfClass:[NSNumber class]]) {
        return [b intValue];
    }
    if ([b isEqual:@"right"]) {
        return 2;
    }
    if ([b isEqual:@"middle"]) {
        return 3;
    }
    return 1;
}

static NSDictionary *handleClick(NSDictionary *req) {
    int button = buttonFromRequest(req);
    NSString *error = syncOnMain(^id {
        if (!mouseButton(button).valueChangedHandler) {
            return GCMouse.current ? @"the game has no handler for that mouse button" : @"no mouse connected";
        }
        if (req[@"x"] && req[@"y"]) {
            return movePointer([req[@"x"] doubleValue], [req[@"y"] doubleValue]);
        }
        return nil;
    });
    if (error) {
        return @{@"ok": @NO, @"error": error};
    }
    // The UI hit-tests against the pointer position it saw last frame; let the move land first.
    double settle = req[@"x"] && req[@"y"] ? (req[@"settle_ms"] ? [req[@"settle_ms"] doubleValue] : 300) : 0;
    NSString *action = req[@"action"] ?: @"tap";
    double hold = req[@"hold_ms"] ? [req[@"hold_ms"] doubleValue] : 60;
    BOOL tap = [action isEqual:@"tap"];
    if (tap || [action isEqual:@"press"]) {
        onMain(settle, ^{ sendButton(button, YES); });
    }
    if (tap || [action isEqual:@"release"]) {
        onMain(tap ? settle + hold : 0, ^{ sendButton(button, NO); });
    }
    return @{@"ok": @YES};
}

static NSDictionary *handleMouseMove(NSDictionary *req) {
    float dx = [req[@"dx"] floatValue], dy = [req[@"dy"] floatValue];
    return syncOnMain(^id {
        GCMouseInput *input = GCMouse.current.mouseInput;
        GCMouseMoved handler = input.mouseMovedHandler;
        if (!handler) {
            return @{@"ok": @NO, @"error": input ? @"the game has no mouse-move handler" : @"no mouse connected"};
        }
        // GameController deltas are y-up; the protocol's are screen-space. "split" delivers the
        // move as several events, like a high-rate mouse between two frames.
        int split = MAX([req[@"split"] intValue], 1);
        for (int i = 0; i < split; i++) {
            handler(input, dx / split, -dy / split);
        }
        return @{@"ok": @YES};
    });
}

static NSDictionary *handleScroll(NSDictionary *req) {
    float dy = [req[@"dy"] floatValue];
    return syncOnMain(^id {
        GCDeviceCursor *scroll = GCMouse.current.mouseInput.scroll;
        GCControllerDirectionPadValueChangedHandler handler = scroll.valueChangedHandler;
        if (!handler) {
            return @{@"ok": @NO, @"error": @"the game has no scroll handler"};
        }
        // The game reads the wheel from the first value only (one notch per event, by sign); no horizontal scroll.
        handler(scroll, dy, 0);
        return @{@"ok": @YES};
    });
}

#pragma mark - Commands

static void applyFrameCap(int cap) {
    macfixFpsCap = MAX(cap, 0);
    macfixApplyFrameRate();
}

static NSDictionary *layerInfo(CAMetalLayer *l) {
    return @{@"maximumDrawableCount": @(l.maximumDrawableCount), @"displaySyncEnabled": @(l.displaySyncEnabled),
             @"presentsWithTransaction": @(l.presentsWithTransaction), @"framebufferOnly": @(l.framebufferOnly),
             @"allowsNextDrawableTimeout": @(l.allowsNextDrawableTimeout), @"pixelFormat": @(l.pixelFormat),
             @"drawableSize": NSStringFromCGSize(l.drawableSize), @"contentsScale": @(l.contentsScale),
             @"bounds": NSStringFromCGRect(l.bounds), @"opaque": @(l.opaque),
             @"wantsExtendedDynamicRangeContent": [l valueForKey:@"wantsExtendedDynamicRangeContent"],
             @"colorspace": l.colorspace ? CFBridgingRelease(CGColorSpaceCopyName(l.colorspace)) ?: @"?" : @"none",
             @"superlayers": @([l.superlayer.sublayers count])};
}

// Reads the game's CAMetalLayer and applies "set" (KVC keys) for A/B experiments.
static NSDictionary *handleLayer(NSDictionary *req) {
    return syncOnMain(^id {
        CAMetalLayer *l = gameLayer;
        if (!l) {
            return @{@"ok": @NO, @"error": @"no frame presented yet"};
        }
        NSDictionary *set = req[@"set"];
        if ([set isKindOfClass:[NSDictionary class]]) {
            @try {
                [set enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) { [l setValue:v forKey:k]; }];
            } @catch (NSException *e) {  // a wrongly typed value; uncaught, it would crash the game
                return @{@"ok": @NO, @"error": e.reason ?: e.name};
            }
        }
        return @{@"ok": @YES, @"layer": layerInfo(l)};
    });
}

// Scheduling state of every thread in the game, for tuning priorities.
static NSDictionary *handleThreads(NSDictionary *req) {
    thread_act_array_t list;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) {
        return @{@"ok": @NO, @"error": @"task_threads failed"};
    }
    NSMutableArray *out = [NSMutableArray array];
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_extended_info_data_t ext;
        mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(list[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &n) == KERN_SUCCESS) {
            thread_precedence_policy_data_t prec = {0};
            mach_msg_type_number_t pn = THREAD_PRECEDENCE_POLICY_COUNT;
            boolean_t def = 0;
            thread_policy_get(list[i], THREAD_PRECEDENCE_POLICY, (thread_policy_t)&prec, &pn, &def);
            [out addObject:@{@"name": @(ext.pth_name), @"cur": @(ext.pth_curpri), @"base": @(ext.pth_priority),
                             @"max": @(ext.pth_maxpriority), @"policy": @(ext.pth_policy), @"importance": @(prec.importance),
                             @"cpu_ms": @((ext.pth_user_time + ext.pth_system_time) / 1000000)}];
        }
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
    return @{@"ok": @YES, @"threads": out};
}

static NSDictionary *state(void) {
    return syncOnMain(^id {
        UIViewController *vc = gameViewController();
        UIWindow *window = vc.view.window;
        BOOL focused = UIApplication.sharedApplication.applicationState == UIApplicationStateActive && window.isKeyWindow;
        // True only while macOS actually captures the pointer (full screen); the game asks for it in-world.
        BOOL locked = window.windowScene.pointerLockState.isLocked;
        BOOL wantsLock = [vc respondsToSelector:@selector(prefersPointerLocked)] && vc.prefersPointerLocked;
        BOOL typing = focusedTextInput() != nil;
        return @{@"ok": @YES, @"width": @(frameWidth), @"height": @(frameHeight), @"focused": @(focused),
                 @"fps": @(round(currentFps() * 10) / 10), @"fps_cap": @(macfixFpsCap), @"cursor_locked": @(locked),
                 @"pointer_lock_requested": @(wantsLock), @"text_input": @(typing),
                 @"mouse_x": @(mouseX), @"mouse_y": @(mouseY)};
    });
}

static NSDictionary *handleURI(NSDictionary *req) {
    NSString *uri = req[@"uri"] ?: @"";
    if (![uri hasPrefix:@"minecraft:"]) {
        return @{@"ok": @NO, @"error": @"uri must start with minecraft:"};
    }
    NSURL *url;
    if (@available(macCatalyst 17.0, *)) {
        url = [NSURL URLWithString:uri encodingInvalidCharacters:YES];  // add_server links carry a raw '|'
    } else {
        url = [NSURL URLWithString:uri];
    }
    if (!url) {
        return @{@"ok": @NO, @"error": @"invalid uri"};
    }
    return syncOnMain(^id {
        UIApplication *app = UIApplication.sharedApplication;
        id<UIApplicationDelegate> delegate = app.delegate;
        if (![delegate respondsToSelector:@selector(application:openURL:options:)]) {
            return @{@"ok": @NO, @"error": @"the game does not handle URLs"};
        }
        BOOL handled = [delegate application:app openURL:url options:@{}];
        return @{@"ok": @YES, @"handled": @(handled)};
    });
}

static NSDictionary *handle(NSDictionary *req) {
    NSString *cmd = req[@"cmd"];
    if ([cmd isEqual:@"ping"]) {
        return @{@"ok": @YES};
    }
    if ([cmd isEqual:@"state"]) {
        return state();
    }
    if ([cmd isEqual:@"screenshot"]) {
        return screenshot(req);
    }
    if ([cmd isEqual:@"key"]) {
        return handleKey(req);
    }
    if ([cmd isEqual:@"text"]) {
        return handleText(req);
    }
    if ([cmd isEqual:@"mouse_move"]) {
        return handleMouseMove(req);
    }
    if ([cmd isEqual:@"mouse_pos"]) {
        double x = [req[@"x"] doubleValue], y = [req[@"y"] doubleValue];
        NSString *error = syncOnMain(^id { return movePointer(x, y); });
        return error ? @{@"ok": @NO, @"error": error} : @{@"ok": @YES};
    }
    if ([cmd isEqual:@"click"]) {
        return handleClick(req);
    }
    if ([cmd isEqual:@"scroll"]) {
        return handleScroll(req);
    }
    if ([cmd isEqual:@"uri"]) {
        return handleURI(req);
    }
    if ([cmd isEqual:@"fps"]) {
        int cap = [req[@"cap"] intValue];
        return syncOnMain(^id {
            applyFrameCap(cap);
            return @{@"ok": @YES, @"fps_cap": @(macfixFpsCap)};
        });
    }
    if ([cmd isEqual:@"threads"]) {
        return handleThreads(req);
    }
    if ([cmd isEqual:@"layer"]) {
        return handleLayer(req);
    }
    if ([cmd isEqual:@"frame_stats"]) {
        return frameStats(req);
    }
    if ([cmd isEqual:@"quit"]) {
        // The app menu's Quit path, so the game saves and shuts down normally.
        onMain(0, ^{
            id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
            ((void (*)(id, SEL, id))objc_msgSend)(app, sel_registerName("terminate:"), nil);
        });
        return @{@"ok": @YES};
    }
    return @{@"ok": @NO, @"error": @"unknown cmd"};
}

#pragma mark - Server

static BOOL sendAll(int fd, NSData *data) {
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n <= 0) {
            return NO;
        }
        p += n;
        left -= (size_t)n;
    }
    return YES;
}

static NSData *replyLine(NSDictionary *res) {
    NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:res options:0 error:NULL] mutableCopy];
    [out appendBytes:"\n" length:1];
    return out;
}

static void serveClient(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) {
            break;
        }
        [buf appendBytes:chunk length:(NSUInteger)n];
        for (;;) {
            NSRange nl = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
            if (nl.location == NSNotFound) {
                break;
            }
            NSData *line = [buf subdataWithRange:NSMakeRange(0, nl.location)];
            [buf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            if (line.length == 0) {
                continue;
            }
            @autoreleasepool {
                NSDictionary *res;
                id req = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if (![req isKindOfClass:[NSDictionary class]]) {
                    res = @{@"ok": @NO, @"error": @"invalid JSON"};
                } else {
                    @try {
                        res = handle(req);
                    } @catch (NSException *e) {
                        res = @{@"ok": @NO, @"error": e.reason ?: e.name};
                    }
                    if (req[@"id"]) {
                        NSMutableDictionary *withId = [res mutableCopy];
                        withId[@"id"] = req[@"id"];
                        res = withId;
                    }
                }
                if (!sendAll(fd, replyLine(res))) {
                    close(fd);
                    return;
                }
            }
        }
    }
    close(fd);
}

// MACFIX_AGENT_HIDDEN=1 keeps the window ordered out while the game keeps rendering, taking input and
// giving screenshots. Ordering out can still send the app to the background, where the game stops its
// display link, so its background callbacks and -stopAnimation are swallowed; it still saves on quit.
static void swallowAppCallback(id self, SEL _cmd, id application) {}
static void swallowStopAnimation(id self, SEL _cmd) {}

static void replaceMethod(Class cls, const char *selector, IMP replacement) {
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName(selector)) : NULL;
    if (m) {
        method_setImplementation(m, replacement);
    } else {
        NSLog(@"[macfix] agent: %s not found, hidden mode may pause", selector);
    }
}

static void hideGameWindow(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    for (id window in ((NSArray * (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"))) {
        BOOL gameWindow = [window respondsToSelector:sel_registerName("uiWindows")] && [[window valueForKey:@"uiWindows"] count];
        if (gameWindow && ((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isVisible"))) {
            ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("orderOut:"), nil);
            NSLog(@"[macfix] agent: window hidden");
        }
    }
}

static void installHidden(void) {
    Class delegate = objc_lookUpClass("minecraftpeAppDelegate");
    replaceMethod(delegate, "applicationWillResignActive:", (IMP)swallowAppCallback);
    replaceMethod(delegate, "applicationDidEnterBackground:", (IMP)swallowAppCallback);
    Class controller = objc_lookUpClass("minecraftpeViewControllerImpl") ?: objc_lookUpClass("minecraftpeViewControllerBase");
    replaceMethod(controller, "stopAnimation", (IMP)swallowStopAnimation);
    // The window appears after launch and UIKit may order it back in; keep it out.
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ hideGameWindow(); });
    dispatch_resume(timer);
    NSLog(@"[macfix] agent: hidden mode");
}

void agentStart(void) {
    const char *portEnv = getenv("MACFIX_AGENT_PORT");
    int port = portEnv ? atoi(portEnv) : 0;
    if (port <= 0 || port > 65535) {
        return;
    }
    captureDone = dispatch_semaphore_create(0);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(port),
                               .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 4) < 0) {
        NSLog(@"[macfix] agent: cannot listen on 127.0.0.1:%d: %s", port, strerror(errno));
        if (fd >= 0) {
            close(fd);
        }
        return;
    }
    NSLog(@"[macfix] agent: listening on 127.0.0.1:%d", port);
    dispatch_async(dispatch_get_main_queue(), ^{ installPresentHook(); });
    installDrawFrameHook();
    const char *hidden = getenv("MACFIX_AGENT_HIDDEN");
    if (hidden && strcmp(hidden, "1") == 0) {
        installHidden();
    }
    [NSThread detachNewThreadWithBlock:^{
        for (;;) {
            int client = accept(fd, NULL, NULL);
            if (client >= 0) {
                [NSThread detachNewThreadWithBlock:^{ serveClient(client); }];
            }
        }
    }];
}
