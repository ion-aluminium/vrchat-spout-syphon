// windowid: print the CGWindowID of the frontmost (or largest) window owned by a process name.
// Used to screenshot a single application window with `screencapture -l <id>` instead of the whole screen.
//
//   windowid <owner-name> [--list]
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: %s <owner-name> [--list]\n", argv[0]);
      return 2;
    }
    NSString *want = @(argv[1]);
    int list = argc > 2 && !strcmp(argv[2], "--list");
    CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    unsigned long best = 0;
    double best_area = 0;
    for (NSDictionary *w in (__bridge NSArray *)wins) {
      NSString *owner = w[(id)kCGWindowOwnerName];
      NSNumber *wid = w[(id)kCGWindowNumber];
      NSDictionary *bounds = w[(id)kCGWindowBounds];
      double area = [bounds[@"Width"] doubleValue] * [bounds[@"Height"] doubleValue];
      if (list) printf("%-6s %-24s %8.0fx%-8.0f id=%s\n", [owner isEqual:want] ? "=>" : "",
                       [owner UTF8String], [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue],
                       [[wid stringValue] UTF8String]);
      if (owner && [owner isEqualToString:want] && area > best_area) {
        best_area = area;
        best = [wid unsignedLongValue];
      }
    }
    CFRelease(wins);
    if (best) printf("%lu\n", best);
    return best ? 0 : 1;
  }
}
