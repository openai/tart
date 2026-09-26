#include <CoreFoundation/CoreFoundation.h>

#include "TartCoreFoundationShim.h"

void tart_cf_release(const void *object) {
  CFRelease((CFTypeRef)object);
}
