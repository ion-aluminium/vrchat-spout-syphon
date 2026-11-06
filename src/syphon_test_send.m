// syphon_test_send: stage-D isolation test. Publishes a synthetic animated BGRA8 texture through
// SyphonMetalServer so a receiver (or OBS's mac-syphon source) can be validated without VRChat.
//
//   syphon_test_send [--name NAME] [--width W] [--height H] [--fps N] [--seconds S] [--alpha]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Syphon/SyphonMetalServer.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *name = "SpoutBridgeTest";
    int W = 1280, H = 720, fps = 30;
    double seconds = 0;  // 0 = forever
    int alpha = 0;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
      else if (!strcmp(argv[i], "--width") && i + 1 < argc) W = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--height") && i + 1 < argc) H = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
      else if (!strcmp(argv[i], "--alpha")) alpha = 1;
    }

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "no Metal device\n"); return 1; }
    fprintf(stderr, "device: %s\n", [[dev name] UTF8String]);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    if (!tex) { fprintf(stderr, "texture alloc failed\n"); return 1; }

    SyphonMetalServer *server = [[SyphonMetalServer alloc] initWithName:@(name) device:dev options:nil];
    if (!server) { fprintf(stderr, "SyphonMetalServer init failed\n"); return 1; }
    fprintf(stderr, "syphon server started: %s (%dx%d @ %d fps)\n", name, W, H, fps);

    id<MTLCommandQueue> q = [dev newCommandQueue];
    const double t0 = now_s();
    unsigned frame = 0;
    double next = t0;
    for (;;) {
      double t = now_s() - t0;
      // A pattern that makes orientation, colour and motion obvious:
      //   left half: horizontal red ramp, right half: vertical green ramp,
      //   a moving blue/white block, and a 8px border whose alpha shows the alpha channel.
      uint8_t *px = (uint8_t *)malloc((size_t)W * H * 4);
      int bx = (int)((t * 240.0) / 1.0) % W;
      for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
          uint8_t *p = px + ((size_t)y * W + x) * 4;
          uint8_t b = 0, g = 0, r = 0, a = 255;
          if (x < W / 2) { r = (uint8_t)(x * 255 / (W / 2)); g = 40; b = 40; }
          else { r = 40; g = (uint8_t)(y * 255 / H); b = 40; }
          int dx = abs(x - bx);
          if (dx < 60 && y > H / 2 - 60 && y < H / 2 + 60) { r = 255; g = 255; b = 255; }
          if (x < 8 || y < 8 || x >= W - 8 || y >= H - 8) { b = 255; g = 0; r = 0; a = alpha ? 0 : 255; }
          if (alpha) a = (uint8_t)((x * 255) / W);
          p[0] = b; p[1] = g; p[2] = r; p[3] = a;
        }
      }
      [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:(NSUInteger)W * 4];
      free(px);

      id<MTLCommandBuffer> cb = [q commandBuffer];
      [server publishFrameTexture:tex
                  onCommandBuffer:cb
                       imageRegion:NSMakeRect(0, 0, W, H)
                           flipped:NO];
      [cb commit];
      frame++;

      if ((frame % (unsigned)fps) == 0)
        fprintf(stderr, "frame %u t=%.1fs clients=%d\n", frame, t, (int)[server hasClients]);

      if (seconds > 0 && t >= seconds) break;
      next += 1.0 / fps;
      double slp = next - now_s();
      // Syphon discovery answers SyphonServerAnnounceRequest on the main run loop: pump it, do not sleep.
      NSDate *until = [NSDate dateWithTimeIntervalSinceNow:(slp > 0 ? slp : 0.001)];
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    }
    fprintf(stderr, "done: %u frames\n", frame);
  }
  return 0;
}
