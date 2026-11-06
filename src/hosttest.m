// hosttest: minimal stand-in for the steamac-vm process. It creates a Metal device, then idles in a
// Cocoa run loop so an injected libSpoutSyphon.dylib (DYLD_INSERT_LIBRARIES) can be exercised without
// restarting the real VM. Used by scripts/test-dylib.sh.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    double seconds = 20;
    for (int i = 1; i < argc; i++)
      if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("hosttest: device=%s\n", dev ? [[dev name] UTF8String] : "(none)");
    fflush(stdout);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
      @autoreleasepool {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      }
    }
    printf("hosttest: done\n");
  }
  return 0;
}
