#include "cua_driver_abi.h"
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
struct CuaDriverHandle { int unused; };
struct CuaDriverOperation { int unused; };
static _Atomic int entered = 0, allowed = 0, invokes = 0;
int test_create_entered(void) { return atomic_load(&entered); }
void test_allow_create(void) { atomic_store(&allowed, 1); }
int test_invokes(void) { return atomic_load(&invokes); }
bool cua_driver_abi_is_compatible_v1(uint16_t major, uint16_t minor) { return major == 1 && minor == 1; }
CuaDriverStatus cua_driver_create_v1(const uint8_t *p, size_t n, CuaDriverHandle **out, CuaDriverBuffer *err) {
  atomic_store(&entered, 1);
  while (!atomic_load(&allowed)) usleep(1000);
  *out = calloc(1, sizeof(CuaDriverHandle));
  return 0;
}
void cua_driver_destroy_v1(CuaDriverHandle **p) { free(*p); *p = NULL; }
void cua_driver_buffer_free_v1(CuaDriverBuffer *p) { free(p->data); memset(p, 0, sizeof(*p)); }
static void succeed(CuaDriverCompletionV1 cb, void *ctx, const char *s) {
  size_t n = strlen(s);
  CuaDriverBuffer result = { .data = (uint8_t *)strdup(s), .len = n, .capacity = n + 1 };
  cb(ctx, 0, result, (CuaDriverBuffer){0});
}
CuaDriverStatus cua_driver_invoke_v1(CuaDriverHandle *p, const uint8_t *name, size_t nn, const uint8_t *args, size_t na, CuaDriverCompletionV1 cb, void *ctx, CuaDriverOperation **out, CuaDriverBuffer *err) {
  atomic_fetch_add(&invokes, 1);
  *out = calloc(1, sizeof(CuaDriverOperation));
  succeed(cb, ctx, "{}");
  return 0;
}
CuaDriverStatus cua_driver_shutdown_v1(CuaDriverHandle *p, CuaDriverCompletionV1 cb, void *ctx, CuaDriverOperation **out, CuaDriverBuffer *err) {
  *out = calloc(1, sizeof(CuaDriverOperation)); succeed(cb, ctx, "null"); return 0;
}
void cua_driver_operation_cancel_v1(CuaDriverOperation *p) {}
void cua_driver_operation_release_v1(CuaDriverOperation **p) { free(*p); *p = NULL; }
uint32_t cua_driver_mactools_policy_v1(void) { return 1; }
