// Test-only AX fault injection, loaded solely into the owned policy probe.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic unsigned failures;
unsigned mactools_fixture_failed_action_reads(void) { return atomic_load(&failures); }

static AXError failed_action_read(AXUIElementRef element, CFArrayRef *names) {
    const char *configured = getenv("MACTOOLS_POLICY_FIXTURE_PID");
    pid_t pid = 0;
    CFTypeRef identifier = NULL;
    if (configured && AXUIElementGetPid(element, &pid) == kAXErrorSuccess
        && pid == (pid_t)strtol(configured, NULL, 10)
        && AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute, &identifier) == kAXErrorSuccess
        && identifier) {
        bool selected = CFGetTypeID(identifier) == CFStringGetTypeID()
            && CFEqual(identifier, CFSTR("mactools-ambiguous-peer"));
        CFRelease(identifier);
        if (selected) {
            if (names) *names = NULL;
            atomic_fetch_add(&failures, 1);
            return kAXErrorCannotComplete;
        }
    }
    return AXUIElementCopyActionNames(element, names);
}

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement; const void *original; } interpose_action_names = {
    (const void *)failed_action_read, (const void *)AXUIElementCopyActionNames
};
