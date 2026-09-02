// Host-test shim (Linux/GNUstep only).
//
// Supplies the two things GNUstep 1.29 with the GCC runtime does not give us:
// libdispatch's dispatch_once, and the Objective-C subscripting methods, which
// GNUstep implements but only declares for newer API versions.
#ifndef LF_HOST_SHIM
#define LF_HOST_SHIM

#import <Foundation/Foundation.h>
#include <Block.h>

#ifndef __unused
#define __unused __attribute__((unused))
#endif

typedef long dispatch_once_t;
static inline void lf_dispatch_once(dispatch_once_t *pred, void (^block)(void)) {
    if (!*pred) {
        *pred = 1;
        block();
    }
}
#define dispatch_once(p, b) lf_dispatch_once((p), (b))

@interface NSDictionary (LFHostSubscripting)
- (id)objectForKeyedSubscript:(id)key;
@end

@interface NSMutableDictionary (LFHostSubscripting)
- (void)setObject:(id)object forKeyedSubscript:(id)key;
@end

@interface NSArray (LFHostSubscripting)
- (id)objectAtIndexedSubscript:(NSUInteger)index;
@end

@interface NSMutableArray (LFHostSubscripting)
- (void)setObject:(id)object atIndexedSubscript:(NSUInteger)index;
@end

#endif
