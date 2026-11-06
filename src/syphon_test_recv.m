// syphon_test_recv: receive every announced Syphon server and verify frames actually change.
// Prints one line per second per server: frames received, mean RGB, and a cheap frame checksum,
// so "continuous changing test frames" is measurable without OBS.
//
//   syphon_test_recv [--seconds S] [--outdir DIR] [--name SUBSTR]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Syphon/SyphonServerDirectory.h>
#import <Syphon/SyphonMetalClient.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

@interface Receiver : NSObject
@property(nonatomic, strong) id<MTLDevice> dev;
@property(nonatomic, strong) SyphonMetalClient *client;
@property(nonatomic, strong) NSString *uuid;
@property(nonatomic) unsigned frames;
@property(nonatomic) unsigned lastChecksum;
@property(nonatomic) double lastChange;
@property(nonatomic) double t0;
@property(nonatomic) int W, H;
@property(nonatomic) BOOL dumped;
@property(nonatomic, strong) NSString *outdir;
@end

@implementation Receiver
- (void)tick {
  if (!self.client.isValid) return;
  @autoreleasepool {
    id<MTLTexture> tex = [self.client newFrameImage];
    if (!tex) return;
    self.frames++;
    if (!self.dumped) {
      self.W = (int)tex.width;
      self.H = (int)tex.height;
      fprintf(stderr, "[%s] frame %dx%d format=%lu\n", [self.uuid UTF8String], self.W, self.H,
              (unsigned long)tex.pixelFormat);
    }
    // read back through a shared staging texture once per second
    static double lastRead = 0;
    double t = now_s();
    if (t - lastRead > 1.0) {
      lastRead = t;
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                                                   width:tex.width
                                                                                  height:tex.height
                                                                               mipmapped:NO];
      td.usage = MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModeShared;
      id<MTLTexture> stage = [self.dev newTextureWithDescriptor:td];
      id<MTLCommandQueue> q = [self.dev newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
      [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(tex.width, tex.height, 1)
                  toTexture:stage destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit endEncoding];
      [cb commit];
      [cb waitUntilCompleted];

      NSUInteger stride = (NSUInteger)tex.width * 4;
      uint8_t *p = (uint8_t *)malloc(stride * tex.height);
      [stage getBytes:p bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, tex.width, tex.height) mipmapLevel:0];
      unsigned long long sum = 0;
      double mr = 0, mg = 0, mb = 0, ma = 0;
      int n = 0;
      for (int y = 0; y < self.H; y += 17) {
        for (int x = 0; x < self.W; x += 17) {
          const uint8_t *q4 = p + y * stride + x * 4;
          sum = sum * 131 + q4[0] * 7 + q4[1] * 13 + q4[2] * 29 + q4[3] * 3;
          mb += q4[0]; mg += q4[1]; mr += q4[2]; ma += q4[3]; n++;
        }
      }
      unsigned chk = (unsigned)(sum & 0xffffffff);
      if (chk != self.lastChecksum) { self.lastChange = t; self.lastChecksum = chk; }
      fprintf(stderr,
              "[%s] t=%5.1fs frames=%u %dx%d mean RGB=(%.0f,%.0f,%.0f) A=%.0f chk=%08x%s\n",
              [self.uuid UTF8String], t - self.t0, self.frames, self.W, self.H, mr / n, mg / n, mb / n,
              ma / n, chk, (t - self.lastChange > 2.0) ? "  [STALLED]" : "");
      if (!self.dumped && self.outdir) {
        NSString *path = [self.outdir stringByAppendingPathComponent:
                                          [NSString stringWithFormat:@"recv-%@.bgra", self.uuid]];
        FILE *f = fopen([path UTF8String], "wb");
        if (f) { fwrite(p, 1, (size_t)stride * self.H, f); fclose(f); }
        self.dumped = YES;
        fprintf(stderr, "[%s] raw frame -> %s\n", [self.uuid UTF8String], [path UTF8String]);
      }
      free(p);
    }
    tex = nil;
  }
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    double seconds = 10;
    NSString *outdir = nil, *filter = nil;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
      else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = @(argv[++i]);
      else if (!strcmp(argv[i], "--name") && i + 1 < argc) filter = @(argv[++i]);
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSMutableDictionary<NSString *, Receiver *> *receivers = [NSMutableDictionary dictionary];
    SyphonServerDirectory *dir = [SyphonServerDirectory sharedDirectory];

    void (^sync)(void) = ^{
      for (NSDictionary *desc in [dir servers]) {
        NSString *uuid = desc[SyphonServerDescriptionUUIDKey];
        NSString *name = desc[SyphonServerDescriptionNameKey];
        if (!uuid) continue;
        if (filter && [name rangeOfString:filter].location == NSNotFound) continue;
        if (receivers[uuid]) continue;
        Receiver *r = [Receiver new];
        r.dev = dev;
        r.uuid = uuid;
        r.outdir = outdir;
        r.t0 = now_s();
        r.client = [[SyphonMetalClient alloc] initWithServerDescription:desc device:dev options:nil newFrameHandler:nil];
        if (!r.client) { fprintf(stderr, "client init failed for %s\n", [name UTF8String]); continue; }
        receivers[uuid] = r;
        fprintf(stderr, "attached: name=%s uuid=%s\n", [name UTF8String], [uuid UTF8String]);
      }
      for (NSString *uuid in [receivers allKeys]) {
        Receiver *r = receivers[uuid];
        if (!r.client.isValid) { fprintf(stderr, "server gone: %s\n", [uuid UTF8String]); [receivers removeObjectForKey:uuid]; }
      }
    };
    sync();
    [[NSNotificationCenter defaultCenter] addObserverForName:SyphonServerAnnounceNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { sync(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:SyphonServerRetireNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { sync(); }];

    double t0 = now_s();
    while (now_s() - t0 < seconds) {
      @autoreleasepool {
        for (Receiver *r in [receivers allValues]) [r tick];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
      }
    }
    fprintf(stderr, "receiver done: %lu server(s), %u frame(s)\n", (unsigned long)receivers.count,
            receivers.count ? [[receivers allValues][0] frames] : 0);
  }
  return 0;
}
