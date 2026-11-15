// cam_send.m — publish the Mac camera as raw BGRA frames over TCP for the VRChat virtual camera.
//
// Pairs with src/guest/unitycam_feed.c inside the VM. Frames travel through a gvproxy TCP forward
// (127.0.0.1:9123 on the Mac -> guest 9123), so nothing is exposed beyond loopback.
//
//   cam_send --port 9123 [--device 0|name] [--width 640 --height 480] [--fps 15] [--list]
//
// The first run asks macOS for camera access; grant it to the host application running this binary.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_port = 9123;
static int g_fd = -1;
static int g_wantW = 640, g_wantH = 480;
static NSString *g_deviceName = nil;
static int g_deviceIndex = 0;
static NSString *g_logPath = nil;

static uint64_t g_frames, g_sentFrames, g_bytes;
static CFAbsoluteTime g_lastStat;
static FILE *g_logf;

static int connect_to_guest(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)g_port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static int send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = buf;
  while (len) {
    ssize_t n = send(fd, p, len, 0);
    if (n <= 0) return 0;
    p += n;
    len -= (size_t)n;
  }
  return 1;
}

@interface CamSender : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) CIContext *ci;
@end

@implementation CamSender
- (NSData *)jpegFromPixelBuffer:(CVPixelBufferRef)pb width:(size_t *)outW height:(size_t *)outH {
  CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
  CGFloat scale = (CGFloat)g_wantW / img.extent.size.width;
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
  CGImageRef cg = [self.ci createCGImage:img fromRect:img.extent];
  if (!cg) return nil;
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                CFSTR("public.jpeg"), 1, NULL);
  NSDictionary *opts = @{(id)kCGImageDestinationLossyCompressionQuality : @(0.7)};
  CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)opts);
  CGImageDestinationFinalize(dest);
  CFRelease(dest);
  *outW = CGImageGetWidth(cg);
  *outH = CGImageGetHeight(cg);
  CGImageRelease(cg);
  return data;
}

- (void)captureOutput:(AVCaptureOutput *)out
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  g_frames++;
  CFRetain(sampleBuffer);
  @autoreleasepool {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) { CFRelease(sampleBuffer); return; }
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!self.ci) self.ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    size_t w = 0, h = 0;
    NSData *jpeg = [self jpegFromPixelBuffer:pb width:&w height:&h];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    if (g_fd < 0) {
      g_fd = connect_to_guest();
      if (g_fd >= 0) { fprintf(stderr, "cam_send: connected, streaming %zux%zu jpeg\n", w, h);
        if (g_logf) { fprintf(g_logf, "connected %zux%zu\n", w, h); fflush(g_logf); } }
    }
    if (g_fd >= 0 && jpeg.length) {
      uint32_t hdr[4] = {0x4a414355u, (uint32_t)w, (uint32_t)h, (uint32_t)jpeg.length};
      int ok = send_all(g_fd, hdr, sizeof hdr) && send_all(g_fd, jpeg.bytes, jpeg.length);
      if (!ok) {
        close(g_fd);
        g_fd = -1;
        fprintf(stderr, "cam_send: disconnected from the VM\n");
      } else {
        g_sentFrames++;
        g_bytes += jpeg.length;
      }
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_lastStat >= 2.0) {
      if (g_logf) { fprintf(g_logf, "%.1f fps sent, %.0f kB/s, %s\n",
                            g_sentFrames / (now - g_lastStat),
                            (g_bytes / 1024.0) / (now - g_lastStat),
                            g_fd >= 0 ? "connected" : "waiting"); fflush(g_logf); }
      fprintf(stderr, "cam_send: captured %.1f fps, sent %.1f fps (%.0f kB/s), %s\n",
              g_frames / (now - g_lastStat), g_sentFrames / (now - g_lastStat),
              (g_bytes / 1024.0) / (now - g_lastStat), g_fd >= 0 ? "connected" : "waiting for the VM");
      g_frames = g_sentFrames = g_bytes = 0;
      g_lastStat = now;
    }
  }
  CFRelease(sampleBuffer);
}
@end

static NSArray<AVCaptureDevice *> *video_devices(void) {
  AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                         AVCaptureDeviceTypeExternalUnknown ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  return ds.devices;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    int wantFps = 15;
    int listOnly = 0;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--port") && i + 1 < argc) g_port = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--device") && i + 1 < argc) {
        const char *v = argv[++i];
        char *end = NULL;
        long idx = strtol(v, &end, 10);
        if (end && *end == 0) g_deviceIndex = (int)idx;
        else g_deviceName = @(v);
      } else if (!strcmp(argv[i], "--width") && i + 1 < argc) g_wantW = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--height") && i + 1 < argc) g_wantH = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--fps") && i + 1 < argc) wantFps = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--log") && i + 1 < argc) g_logPath = @(argv[++i]);
      else if (!strcmp(argv[i], "--list")) listOnly = 1;
    }

    if (g_logPath) g_logf = fopen([g_logPath UTF8String], "a");
    NSArray<AVCaptureDevice *> *devices = video_devices();
    if (listOnly || devices.count == 0) {
      int i = 0;
      for (AVCaptureDevice *d in devices) printf("%d: %s\n", i++, [d.localizedName UTF8String]);
      if (devices.count == 0) printf("no cameras (grant Camera access in System Settings > Privacy & Security)\n");
      return devices.count ? 0 : 1;
    }

    AVCaptureDevice *dev = nil;
    if (g_deviceName) {
      for (AVCaptureDevice *d in devices)
        if ([d.localizedName isEqualToString:g_deviceName]) { dev = d; break; }
      if (!dev) { fprintf(stderr, "cam_send: no camera named '%s'\n", [g_deviceName UTF8String]); return 1; }
    } else {
      if (g_deviceIndex < 0 || (NSUInteger)g_deviceIndex >= devices.count) {
        fprintf(stderr, "cam_send: device index %d out of range (%lu cameras)\n", g_deviceIndex,
                (unsigned long)devices.count);
        return 1;
      }
      dev = devices[g_deviceIndex];
    }
    fprintf(stderr, "cam_send: camera '%s' -> 127.0.0.1:%d\n", [dev.localizedName UTF8String], g_port);

    CamSender *sender = [CamSender new];
    AVCaptureSession *session = [AVCaptureSession new];
    sender.session = session;
    [session beginConfiguration];
    NSString *preset = [NSString stringWithFormat:@"AVCaptureSessionPreset%d%d", g_wantW >= 1000 ? 1 : 0, 0];
    (void)preset;
    if ([session canSetSessionPreset:AVCaptureSessionPreset640x480])
      session.sessionPreset = AVCaptureSessionPreset640x480;
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!input) { fprintf(stderr, "cam_send: input failed: %s\n", [[err description] UTF8String]); return 1; }
    [session addInput:input];

    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    out.alwaysDiscardsLateVideoFrames = YES;
    dispatch_queue_t q = dispatch_queue_create("cam.capture", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:sender queue:q];
    [session addOutput:out];
    for (AVCaptureConnection *c in out.connections)
      if (c.supportsVideoMinFrameDuration) c.videoMinFrameDuration = CMTimeMake(1, wantFps);
    [session commitConfiguration];

    g_lastStat = CFAbsoluteTimeGetCurrent();
    // heartbeat: a CLI process without Camera permission gets no buffers at all, which otherwise looks
    // like a silent hang
    dispatch_queue_t hb = dispatch_get_main_queue();
    __block unsigned long long lastFrames = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
      if (g_frames == 0 && lastFrames == 0) {
        fprintf(stderr, "cam_send: no frames yet - if this persists, grant Camera access to the host app "
                        "in System Settings > Privacy & Security > Camera and run again\n");
      }
      lastFrames = g_frames > 0 ? 1 : 0;
    }];
    (void)hb;
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    [session startRunning];
    fprintf(stderr, "cam_send: running (Ctrl-C to stop)\n");
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
