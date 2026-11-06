// syphon_stats: measure what a Syphon client actually receives from the bridge.
//
// Connects to a named Syphon server and reports, once per second: frames delivered in that second
// (the real end-to-end frame rate through the Syphon path), the longest gap between frames (a drop /
// stall indicator), plus image geometry and a 1 Hz sample of mean colour and alpha. With --csv, the
// same numbers go to a file for the stability run.
//
//   syphon_stats [--name NAME] [--seconds N] [--csv FILE] [--dump FILE] [--require-frames N]
//
// Exit status: 0 if at least --require-frames frames arrived, 1 otherwise.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Syphon/SyphonServerDirectory.h>
#import <Syphon/SyphonMetalClient.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static id<MTLDevice> g_dev;
static SyphonMetalClient *g_client;
static volatile unsigned long long g_frames;
static volatile double g_last_frame_t, g_max_gap;

int main(int argc, char **argv) {
  @autoreleasepool {
    double seconds = 10;
    NSString *name = nil, *csv = nil, *dump = nil;
    unsigned long long require = 1;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--name") && i + 1 < argc) name = @(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
      else if (!strcmp(argv[i], "--csv") && i + 1 < argc) csv = @(argv[++i]);
      else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = @(argv[++i]);
      else if (!strcmp(argv[i], "--require-frames") && i + 1 < argc) require = strtoull(argv[++i], NULL, 10);
    }
    g_dev = MTLCreateSystemDefaultDevice();
    SyphonServerDirectory *dir = [SyphonServerDirectory sharedDirectory];

    // wait for the server to announce
    NSDictionary *desc = nil;
    double t_wait = now_s();
    while (now_s() - t_wait < 15 && !desc) {
      for (NSDictionary *d in [dir servers]) {
        if (!name || [d[SyphonServerDescriptionNameKey] isEqual:name]) { desc = d; break; }
      }
      if (!desc)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (!desc) {
      fprintf(stderr, "syphon_stats: no server named %s\n", name ? [name UTF8String] : "(any)");
      return 1;
    }
    fprintf(stderr, "syphon_stats: server '%s' app '%s'\n", [desc[SyphonServerDescriptionNameKey] UTF8String],
            [desc[SyphonServerDescriptionAppNameKey] UTF8String]);

    g_last_frame_t = now_s();
    g_client = [[SyphonMetalClient alloc] initWithServerDescription:desc device:g_dev options:nil
                                                   newFrameHandler:^(SyphonMetalClient *c) {
                                                     double t = now_s();
                                                     double gap = t - g_last_frame_t;
                                                     if (g_frames > 0 && gap > g_max_gap) g_max_gap = gap;
                                                     g_last_frame_t = t;
                                                     g_frames++;
                                                   }];
    if (!g_client) {
      fprintf(stderr, "syphon_stats: client init failed\n");
      return 1;
    }

    FILE *f = csv ? fopen([csv UTF8String], "w") : NULL;
    if (f) fprintf(f, "t,second_frames,fps,max_gap_ms,width,height,mean_r,mean_g,mean_b,mean_a\n");
    unsigned long long prev = 0, total_start = g_frames;
    unsigned W = 0, H = 0;
    int dumped = 0;
    double t0 = now_s(), t_last = t0;
    while (now_s() - t0 < seconds) {
      @autoreleasepool {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        double t = now_s() - t0;
        if (t - (t_last - t0) < 1.0) continue;
        unsigned long long cur = g_frames;
        double fps = (double)(cur - prev) / (t - (t_last - t0));
        double gap = g_max_gap * 1000.0;
        prev = cur;
        t_last = now_s();
        g_max_gap = 0;

        double mr = 0, mg = 0, mb = 0, ma = 0;
        int n = 0;
        id<MTLTexture> tex = [g_client newFrameImage];
        if (tex) {
          W = (unsigned)tex.width;
          H = (unsigned)tex.height;
          MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                                                       width:W height:H mipmapped:NO];
          td.usage = MTLTextureUsageShaderRead;
          td.storageMode = MTLStorageModeShared;
          id<MTLTexture> stage = [g_dev newTextureWithDescriptor:td];
          id<MTLCommandQueue> q = [g_dev newCommandQueue];
          id<MTLCommandBuffer> cb = [q commandBuffer];
          id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
          [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(W, H, 1)
                      toTexture:stage destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
          [b endEncoding];
          [cb commit];
          [cb waitUntilCompleted];
          NSUInteger stride = W * 4;
          uint8_t *px = malloc(stride * H);
          [stage getBytes:px bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
          for (unsigned y = 0; y < H; y += 16)
            for (unsigned x = 0; x < W; x += 16) {
              uint8_t *p = px + y * stride + x * 4;  // BGRA in Syphon's pool
              mb += p[0]; mg += p[1]; mr += p[2]; ma += p[3];
              n++;
            }
          if (dump && !dumped) {
            FILE *d = fopen([dump UTF8String], "wb");
            if (d) { fwrite(px, 1, stride * H, d); fclose(d); }
            dumped = 1;
            fprintf(stderr, "syphon_stats: raw BGRA frame -> %s\n", [dump UTF8String]);
          }
          free(px);
        }
        printf("t=%5.1fs fps=%5.1f frames=%llu max_gap=%6.1fms %ux%u meanRGBA=(%.0f,%.0f,%.0f,%.0f)\n", t, fps, cur,
               gap, W, H, mr / (n ? n : 1), mg / (n ? n : 1), mb / (n ? n : 1), ma / (n ? n : 1));
        fflush(stdout);
        if (f) {
          fprintf(f, "%.1f,%.0f,%.1f,%.1f,%u,%u,%.1f,%.1f,%.1f,%.1f\n", t, (double)(cur - prev), fps, gap, W, H,
                  mr / (n ? n : 1), mg / (n ? n : 1), mb / (n ? n : 1), ma / (n ? n : 1));
          fflush(f);
        }
        prev = cur;
      }
    }
    if (f) fclose(f);
    unsigned long long got = g_frames - total_start;
    fprintf(stderr, "syphon_stats: %llu frames in %.0fs (%.1f fps average)\n", got, seconds, got / seconds);
    [g_client stop];
    return got >= require ? 0 : 1;
  }
}
