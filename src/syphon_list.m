// syphon_list: print the Syphon servers currently announced on this Mac (name/app/uuid), one per line as
// tab-separated fields. Waits briefly for the announce round-trip, which is asynchronous.
#import <Foundation/Foundation.h>
#import <Syphon/SyphonServerDirectory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    double wait = 1.5;
    for (int i = 1; i < argc; i++)
      if (!strcmp(argv[i], "--wait") && i + 1 < argc) wait = atof(argv[++i]);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:wait];
    while ([end timeIntervalSinceNow] > 0)
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSArray *s = [[SyphonServerDirectory sharedDirectory] servers];
    printf("%lu\n", (unsigned long)s.count);
    for (NSDictionary *d in s)
      printf("%s\t%s\t%s\n", [d[SyphonServerDescriptionNameKey] UTF8String],
             [d[SyphonServerDescriptionAppNameKey] UTF8String], [d[SyphonServerDescriptionUUIDKey] UTF8String]);
  }
  return 0;
}
