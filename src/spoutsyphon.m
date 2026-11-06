// libSpoutSyphon.dylib — publishes a guest's D3D11 "Spout" shared texture as a Syphon source on macOS.
//
// Why this works (see docs/ARCHITECTURE.md): FX Steam Launcher runs the SteamOS guest's D3D11 on the
// host through DXMT's winemetal layer inside the steamac-vm process (wmtr). A D3D11 texture created with
// D3D11_RESOURCE_MISC_SHARED is realized there as an IOSurface-backed MTLSharedTexture via
// -[MTLDevice newSharedTextureWithDescriptor:] (dxmt src/winemetal/unix/winemetal_unix.c:2721-2729).
// Spout senders (VRChat's KlakSpout) use exactly that flag, so the texture is already in this process:
// no VM hop, no readback. We hook that one Metal entry point and republish the texture through
// SyphonMetalServer, which OBS's bundled mac-syphon source lists system-wide.
//
// It is inert unless SPOUTSYPHON_ENABLE=1. Nothing in the guest, in VRChat, or in the launcher bundle is
// modified; removing the DYLD_INSERT_LIBRARIES variable restores the stock launcher.
//
// Environment:
//   SPOUTSYPHON_ENABLE=1          required, otherwise the library does nothing
//   SPOUTSYPHON_NAME=<name>       Syphon server name (default "VRChat Spout Camera")
//   SPOUTSYPHON_FPS=<n>           publish rate cap (default 30)
//   SPOUTSYPHON_WIDTH/HEIGHT      only accept a shared texture of this size (0/absent = any)
//   SPOUTSYPHON_FORMAT=rgba|bgra  only accept this pixel format (absent = any)
//   SPOUTSYPHON_INDEX=<n>         which accepted texture to publish: -1 newest (default), 0 first
//   SPOUTSYPHON_FLIP=0|1          pass `flipped:` = YES to Syphon (default 0)
//   SPOUTSYPHON_LOG=<path>        log file (default /tmp/spoutsyphon.log)
//   SPOUTSYPHON_SELFTEST=1        create and publish a synthetic shared texture (no VM needed)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <Syphon/SyphonMetalServer.h>

#include <pthread.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static FILE *g_log;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}
static void reload_conf(void);

static void logmsg(const char *fmt, ...) {
  if (!g_log) return;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  struct tm tm;
  localtime_r(&ts.tv_sec, &tm);
  char stamp[32];
  strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
  va_list ap;
  va_start(ap, fmt);
  pthread_mutex_lock(&g_log_lock);
  fprintf(g_log, "%s.%03ld [%d] ", stamp, ts.tv_nsec / 1000000, getpid());
  vfprintf(g_log, fmt, ap);
  fputc('\n', g_log);
  fflush(g_log);
  pthread_mutex_unlock(&g_log_lock);
  va_end(ap);
}

// ---------------------------------------------------------------- configuration
static int cfg_enabled, cfg_fps = 30, cfg_w = 0, cfg_h = 0, cfg_index = -1, cfg_flip = 1, cfg_selftest = 0;
static int cfg_largest = 1;      // pick the largest accepted texture (stable against small helper textures)
static char cfg_conf[256] = "/tmp/spoutsyphon.conf";
static int cfg_rgba = -1;  // -1 any, 0 bgra, 1 rgba
static char cfg_name[128] = "VRChat Spout Camera";

static void read_config(void) {
  const char *e = getenv("SPOUTSYPHON_ENABLE");
  cfg_enabled = e && *e && strcmp(e, "0");
  if ((e = getenv("SPOUTSYPHON_FPS"))) cfg_fps = atoi(e);
  if (cfg_fps < 1) cfg_fps = 1;
  if (cfg_fps > 120) cfg_fps = 120;
  if ((e = getenv("SPOUTSYPHON_WIDTH"))) cfg_w = atoi(e);
  if ((e = getenv("SPOUTSYPHON_HEIGHT"))) cfg_h = atoi(e);
  if ((e = getenv("SPOUTSYPHON_INDEX"))) cfg_index = atoi(e);
  if ((e = getenv("SPOUTSYPHON_FLIP"))) cfg_flip = atoi(e) != 0;
  if ((e = getenv("SPOUTSYPHON_SELFTEST"))) cfg_selftest = atoi(e) != 0;
  if ((e = getenv("SPOUTSYPHON_NAME"))) snprintf(cfg_name, sizeof cfg_name, "%s", e);
  if ((e = getenv("SPOUTSYPHON_CONF"))) snprintf(cfg_conf, sizeof cfg_conf, "%s", e);
  if ((e = getenv("SPOUTSYPHON_PICK"))) cfg_largest = !!strcmp(e, "newest");
  if ((e = getenv("SPOUTSYPHON_FORMAT"))) {
    if (!strcasecmp(e, "rgba")) cfg_rgba = 1;
    else if (!strcasecmp(e, "bgra")) cfg_rgba = 0;
  }
}

// Runtime knobs, re-read once a second so orientation/rate can be corrected without restarting the VM.
// File format: one `key=value` per line; keys: flip, fps, pick, name. Environment sets the initial values.
static struct timespec g_conf_mtime;
static void reload_conf(void) {
  struct stat st;
  if (stat(cfg_conf, &st) != 0) return;
  if (st.st_mtimespec.tv_sec == g_conf_mtime.tv_sec && st.st_mtimespec.tv_nsec == g_conf_mtime.tv_nsec) return;
  g_conf_mtime = st.st_mtimespec;
  FILE *f = fopen(cfg_conf, "r");
  if (!f) return;
  char line[256];
  while (fgets(line, sizeof line, f)) {
    char *eq = strchr(line, '=');
    if (!eq) continue;
    *eq = 0;
    char *k = line, *v = eq + 1;
    while (*k == ' ' || *k == '\t') k++;
    while (*v == ' ' || *v == '\t') v++;
    char *nl = strpbrk(v, "\r\n");
    if (nl) *nl = 0;
    if (!strcmp(k, "flip")) cfg_flip = atoi(v) != 0;
    else if (!strcmp(k, "fps")) { cfg_fps = atoi(v); if (cfg_fps < 1) cfg_fps = 1; if (cfg_fps > 120) cfg_fps = 120; }
    else if (!strcmp(k, "pick")) cfg_largest = !!strcmp(v, "newest");
    else if (!strcmp(k, "name")) snprintf(cfg_name, sizeof cfg_name, "%s", v);
  }
  fclose(f);
  logmsg("config reloaded: flip=%d fps=%d pick=%s name='%s'", cfg_flip, cfg_fps, cfg_largest ? "largest" : "newest",
         cfg_name);
}

// ---------------------------------------------------------------- candidate registry
struct candidate {
  void *tex;  // +1 CF reference to id<MTLTexture> (ARC-safe hand-off)
  unsigned w, h;
  MTLPixelFormat fmt;
  double t_seen;
};
static struct candidate g_cands[32];
static int g_ncands;
static pthread_mutex_t g_cand_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_have_new;

static const char *fmt_name(MTLPixelFormat f) {
  switch (f) {
    case MTLPixelFormatRGBA8Unorm: return "RGBA8Unorm";
    case MTLPixelFormatRGBA8Unorm_sRGB: return "RGBA8Unorm_sRGB";
    case MTLPixelFormatBGRA8Unorm: return "BGRA8Unorm";
    case MTLPixelFormatBGRA8Unorm_sRGB: return "BGRA8Unorm_sRGB";
    default: return "other";
  }
}

static int accept_desc(id<MTLTexture> t) {
  if (!t) return 0;
  if (t.textureType != MTLTextureType2D) return 0;
  if (t.width < 64 || t.height < 64) return 0;
  if (cfg_w && (int)t.width != cfg_w) return 0;
  if (cfg_h && (int)t.height != cfg_h) return 0;
  if (cfg_rgba == 1 && t.pixelFormat != MTLPixelFormatRGBA8Unorm && t.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB)
    return 0;
  if (cfg_rgba == 0 && t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB)
    return 0;
  return 1;
}

static void register_candidate(id<MTLTexture> t, const char *why) {
  int ok = accept_desc(t);
  logmsg("newSharedTexture %ux%u fmt=%s usage=0x%lx storage=%ld why=%s -> %s", (unsigned)t.width, (unsigned)t.height,
         fmt_name(t.pixelFormat), (unsigned long)t.usage, (long)t.storageMode, why, ok ? "ACCEPTED" : "ignored");
  if (!ok) return;
  pthread_mutex_lock(&g_cand_lock);
  if (g_ncands < (int)(sizeof g_cands / sizeof g_cands[0])) {
    int slot = g_ncands++;
    g_cands[slot].tex = (void *)CFBridgingRetain(t);
    g_cands[slot].w = (unsigned)t.width;
    g_cands[slot].h = (unsigned)t.height;
    g_cands[slot].fmt = t.pixelFormat;
    g_cands[slot].t_seen = now_s();
  } else {
    // keep the newest by replacing the oldest slot
    int oldest = 0;
    for (int i = 1; i < g_ncands; i++)
      if (g_cands[i].t_seen < g_cands[oldest].t_seen) oldest = i;
    CFRelease(g_cands[oldest].tex);
    g_cands[oldest].tex = (void *)CFBridgingRetain(t);
    g_cands[oldest].w = (unsigned)t.width;
    g_cands[oldest].h = (unsigned)t.height;
    g_cands[oldest].fmt = t.pixelFormat;
    g_cands[oldest].t_seen = now_s();
  }
  pthread_mutex_unlock(&g_cand_lock);
  g_have_new = 1;
}

// Returns +1 (caller CFRelease()s) so a concurrent replacement cannot free the texture mid-publish.
static void *pick_candidate(unsigned *w, unsigned *h) {
  void *out = NULL;
  pthread_mutex_lock(&g_cand_lock);
  if (g_ncands > 0) {
    int i = g_ncands - 1;
    if (cfg_largest) {
      unsigned long long best = 0;
      for (int k = 0; k < g_ncands; k++) {
        unsigned long long area = (unsigned long long)g_cands[k].w * g_cands[k].h;
        if (area >= best) { best = area; i = k; }
      }
    } else if (cfg_index >= 0 && cfg_index < g_ncands) {
      i = cfg_index;
    }
    out = g_cands[i].tex;
    CFRetain(out);
    if (w) *w = g_cands[i].w;
    if (h) *h = g_cands[i].h;
  }
  pthread_mutex_unlock(&g_cand_lock);
  return out;
}

// ---------------------------------------------------------------- the Metal hook
// One Method object can be shared by many classes (inherited implementations), but two unrelated
// classes may each own their own: keep the original IMP per Method instead of in a single global.
static Method g_methods[8];
static IMP g_origs[8];
static int g_nmethods;
static id hooked_new_shared(id self, SEL _cmd, MTLTextureDescriptor *desc);

static IMP orig_imp_for(id self) {
  Method m = class_getInstanceMethod(object_getClass(self), @selector(newSharedTextureWithDescriptor:));
  for (int i = 0; i < g_nmethods; i++)
    if (g_methods[i] == m) return g_origs[i];
  return g_nmethods ? g_origs[0] : NULL;
}

static id hooked_new_shared(id self, SEL _cmd, MTLTextureDescriptor *desc) {
  IMP orig = orig_imp_for(self);
  id tex = orig ? ((id(*)(id, SEL, MTLTextureDescriptor *))orig)(self, _cmd, desc) : nil;
  @try {
    if (tex) register_candidate(tex, "hook");
    else if (desc)
      logmsg("newSharedTexture %lux%lu fmt=%s -> NIL (Metal refused the shared descriptor)",
             (unsigned long)desc.width, (unsigned long)desc.height, fmt_name(desc.pixelFormat));
  } @catch (NSException *e) {
    logmsg("hook exception: %s", [[e reason] UTF8String]);
  }
  return tex;
}

static int swizzle_device_class(Class c) {
  if (!c) return 0;
  SEL sel = @selector(newSharedTextureWithDescriptor:);
  Method m = class_getInstanceMethod(c, sel);
  if (!m) return 0;
  if (method_getImplementation(m) == (IMP)hooked_new_shared) return 0;  // already ours
  if (g_nmethods < (int)(sizeof g_methods / sizeof g_methods[0])) {
    g_methods[g_nmethods] = m;
    g_origs[g_nmethods] = method_getImplementation(m);
    g_nmethods++;
    method_setImplementation(m, (IMP)hooked_new_shared);
  }
  logmsg("hooked -[%s newSharedTextureWithDescriptor:]", class_getName(c));
  return 1;
}

static int install_hook(void) {
  int n = 0;
  // A concrete MTLDevice class is only registered once Metal has been used; the VM creates its device
  // before the guest can create any texture, so polling for a short while is enough.
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
  if (dev) n += swizzle_device_class(object_getClass(dev));
  int count = objc_getClassList(NULL, 0);
  if (count > 0) {
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
      Class c = classes[i];
      const char *cn = class_getName(c);
      if (!strstr(cn, "Device") && !strstr(cn, "AGX") && !strstr(cn, "MTL")) continue;
      if (class_getInstanceMethod(c, @selector(newSharedTextureWithDescriptor:))) n += swizzle_device_class(c);
    }
    free(classes);
  }
  return n;
}

// ---------------------------------------------------------------- publisher
static SyphonMetalServer *g_server;
static id<MTLCommandQueue> g_queue;
static volatile int g_stop;
static unsigned long long g_frames, g_frames_window;
static double g_t_stats;
static double g_t_start;

static void publish_tick(CFRunLoopTimerRef timer, void *info) {
  (void)timer;
  (void)info;
  @autoreleasepool {
    static double last_conf;
    double nowc = now_s();
    if (nowc - last_conf >= 1.0) { reload_conf(); last_conf = nowc; }
    unsigned w = 0, h = 0;
    void *raw = pick_candidate(&w, &h);
    id<MTLTexture> tex = (__bridge id<MTLTexture>)raw;
    if (tex) {
      if (!g_server) {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        g_server = [[SyphonMetalServer alloc] initWithName:@(cfg_name) device:d options:nil];
        g_queue = [d newCommandQueue];
        g_t_start = now_s();
        logmsg("syphon server '%s' started on device %s (source %ux%u)", cfg_name,
               d ? [[d name] UTF8String] : "?", w, h);
      }
      if (g_server) {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        [g_server publishFrameTexture:tex
                      onCommandBuffer:cb
                          imageRegion:NSMakeRect(0, 0, w, h)
                              flipped:cfg_flip ? YES : NO];
        [cb commit];
        g_frames++;
      }
      CFRelease(raw);
    }
    double t = now_s();
    if (g_server && t - g_t_stats >= 1.0) {
      unsigned w2 = 0, h2 = 0;
      void *cur = pick_candidate(&w2, &h2);
      if (cur) CFRelease(cur);
      logmsg("publish %.1f fps, %llu total, source %ux%u, flip=%d, syphon clients=%d",
             (double)g_frames_window / (t - g_t_stats), g_frames, w2, h2, cfg_flip,
             g_server ? (int)[g_server hasClients] : 0);
      g_frames_window = 0;
      g_t_stats = t;
    }
    g_frames_window++;
  }
}

static void *publisher_main(void *arg) {
  (void)arg;
  @autoreleasepool {
    CFTimeInterval interval = 1.0 / (double)cfg_fps;
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0,
                                                  publish_tick, &ctx);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    // A run-loop timer both paces the publisher and keeps this thread's run loop alive for Syphon's
    // distributed-notification machinery (the failure mode observed with a plain usleep loop).
    CFRunLoopRun();
    CFRelease(timer);
  }
  return NULL;
}

// ---------------------------------------------------------------- selftest producer
static void *selftest_main(void *arg) {
  (void)arg;
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) {
      logmsg("selftest: no Metal device");
      return NULL;
    }
    [NSThread sleepForTimeInterval:1.5];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:1280
                                                                                height:720
                                                                             mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [d newSharedTextureWithDescriptor:td];
    logmsg("selftest: shared texture %p %lux%lu", tex, (unsigned long)tex.width, (unsigned long)tex.height);
    if (!tex) return NULL;
    // animate through a CPU staging texture + blit so the published frames change every second
    MTLTextureDescriptor *sd = [td copy];
    sd.storageMode = MTLStorageModeShared;
    sd.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> stage = [d newTextureWithDescriptor:sd];
    id<MTLCommandQueue> q = [d newCommandQueue];
    for (int i = 0; !g_stop; i++) {
      @autoreleasepool {
        size_t stride = 1280 * 4;
        uint8_t *px = malloc(stride * 720);
        for (int y = 0; y < 720; y++)
          for (int x = 0; x < 1280; x++) {
            uint8_t *p = px + y * stride + x * 4;
            int inbar = (x > i * 8 % 1280 && x < i * 8 % 1280 + 120);
            p[0] = inbar ? 255 : (uint8_t)(y * 255 / 720);  // B
            p[1] = inbar ? 255 : 30;                        // G
            p[2] = inbar ? 255 : (uint8_t)(x * 255 / 1280); // R
            p[3] = 255;
          }
        [stage replaceRegion:MTLRegionMake2D(0, 0, 1280, 720) mipmapLevel:0 withBytes:px bytesPerRow:stride];
        free(px);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:stage sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(1280, 720, 1)
                    toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        [NSThread sleepForTimeInterval:1.0 / 30];
      }
    }
  }
  return NULL;
}

// ---------------------------------------------------------------- entry point
__attribute__((constructor)) static void spoutsyphon_init(void) {
  read_config();
  if (!cfg_enabled) return;
  const char *lp = getenv("SPOUTSYPHON_LOG");
  g_log = fopen(lp && *lp ? lp : "/tmp/spoutsyphon.log", "a");
  if (!g_log) return;
  logmsg("=== libSpoutSyphon %s loaded in pid %d (%s) ===", cfg_selftest ? "[selftest]" : "", getpid(),
         [[[NSProcessInfo processInfo] processName] UTF8String]);
  logmsg("config: name='%s' fps=%d size=%dx%d(index %d) flip=%d fmt=%d", cfg_name, cfg_fps, cfg_w, cfg_h, cfg_index,
         cfg_flip, cfg_rgba);

  // Hook on a helper thread: MTLCreateSystemDefaultDevice from a constructor is fine, but the concrete
  // device class can appear later, so retry for a while.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (int i = 0; i < 600; i++) {
      if (install_hook()) break;
      [NSThread sleepForTimeInterval:0.1];
    }
    logmsg("hook installation finished, %d method(s) hooked", g_nmethods);
  });

  pthread_t th;
  pthread_create(&th, NULL, publisher_main, NULL);
  pthread_detach(th);
  if (cfg_selftest) {
    pthread_t st;
    pthread_create(&st, NULL, selftest_main, NULL);
    pthread_detach(st);
  }
}
