// Test-only AX fault injection, loaded solely into the owned policy probe.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic unsigned failures;
unsigned mactools_fixture_failed_action_reads(void) { return atomic_load(&failures); }

static _Atomic bool fail_ancestry;
static _Atomic unsigned ancestor_failures, descendant_reads;
void mactools_fixture_fail_ancestry(bool enabled) {
    atomic_store(&ancestor_failures, 0);
    atomic_store(&descendant_reads, 0);
    atomic_store(&fail_ancestry, enabled);
}
unsigned mactools_fixture_ancestor_failures(void) { return atomic_load(&ancestor_failures); }
unsigned mactools_fixture_descendant_reads(void) { return atomic_load(&descendant_reads); }

static bool fixture_element(AXUIElementRef element, CFStringRef expected) {
    const char *configured = getenv("MACTOOLS_POLICY_FIXTURE_PID");
    pid_t pid = 0;
    CFTypeRef identifier = NULL;
    if (!configured || AXUIElementGetPid(element, &pid) != kAXErrorSuccess
        || pid != (pid_t)strtol(configured, NULL, 10)
        || AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute, &identifier) != kAXErrorSuccess
        || !identifier) { return false; }
    bool matches = CFGetTypeID(identifier) == CFStringGetTypeID() && CFEqual(identifier, expected);
    CFRelease(identifier);
    return matches;
}

static AXError failed_ancestor_read(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    if (atomic_load(&fail_ancestry)) {
        if (CFEqual(attribute, kAXRoleAttribute)
            && fixture_element(element, CFSTR("mactools-ancestry-parent"))) {
            if (value) *value = NULL;
            atomic_fetch_add(&ancestor_failures, 1);
            return kAXErrorCannotComplete;
        }
        if (CFEqual(attribute, kAXValueAttribute)
            && fixture_element(element, CFSTR("mactools-ancestry-control"))) {
            atomic_fetch_add(&descendant_reads, 1);
        }
    }
    return AXUIElementCopyAttributeValue(element, attribute, value);
}

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

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement; const void *original; } interpose_attribute_value = {
    (const void *)failed_ancestor_read, (const void *)AXUIElementCopyAttributeValue
};
