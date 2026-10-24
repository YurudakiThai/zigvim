// Stand-ins for the Neovim internals that src/nvim/lua/treesitter.c uses, so the
// file compiles in zigvim with only the tree-sitter API, Lua and libuv.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define FUNC_ATTR_MALLOC
#define FUNC_ATTR_NONNULL_ALL
#define FUNC_ATTR_NONNULL_ARG(...)
#define FUNC_ATTR_NONNULL_RET
#define FUNC_ATTR_PURE
#define FUNC_ATTR_WARN_UNUSED_RESULT
#define NUL '\0'
#ifndef MIN
# define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#define IOSIZE 1025
#define vim_snprintf snprintf
#define os_hrtime uv_hrtime
#define os_fopen fopen

typedef int LuaRef;
typedef int handle_T;
typedef int32_t linenr_T;
typedef const char *cstr_t;

static char IObuff[IOSIZE];

static inline void *xmalloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) abort(); return p; }
static inline void *xcalloc(size_t c, size_t n) { void *p = calloc(c ? c : 1, n ? n : 1); if (!p) abort(); return p; }
static inline void *xrealloc(void *p, size_t n) { p = realloc(p, n ? n : 1); if (!p) abort(); return p; }
static inline void xfree(void *p) { free(p); }
static inline char *xstrdup(const char *s) { size_t n = strlen(s) + 1; return memcpy(xmalloc(n), s, n); }
static inline size_t xstrlcpy(char *dst, const char *src, size_t dsize)
{
  size_t n = strlen(src);
  if (dsize) { size_t c = n < dsize - 1 ? n : dsize - 1; memcpy(dst, src, c); dst[c] = NUL; }
  return n;
}
static inline void memchrsub(void *data, char c, char x, size_t len)
{
  char *p = data;
  for (size_t i = 0; i < len; i++) if (p[i] == c) p[i] = x;
}

// The language map (Neovim's PMap(cstr_t)): a short linear list, a few dozen entries at most.
typedef struct { char *key; void *val; } LangEntry;
typedef struct { LangEntry *items; size_t n, cap; } LangMap;
#define PMap(t) LangMap
#define MAP_INIT { 0 }
static inline LangEntry *lm_find(LangMap *m, const char *k)
{
  for (size_t i = 0; i < m->n; i++) if (strcmp(m->items[i].key, k) == 0) return &m->items[i];
  return NULL;
}
#define map_has(t, m, k) (lm_find((m), (k)) != NULL)
static inline void *lm_get(LangMap *m, const char *k) { LangEntry *e = lm_find(m, k); return e ? e->val : NULL; }
static inline void lm_put(LangMap *m, const char *k, void *v)
{
  if (m->n == m->cap) { m->cap = m->cap ? m->cap * 2 : 16; m->items = xrealloc(m->items, m->cap * sizeof(LangEntry)); }
  m->items[m->n++] = (LangEntry){ (char *)k, v };
}
static inline void lm_del(LangMap *m, const char *k, cstr_t *key)
{
  LangEntry *e = lm_find(m, k);
  if (!e) return;
  *key = e->key;
  *e = m->items[--m->n];
}
#define pmap_get(t) lm_get
#define pmap_put(t) lm_put
#define pmap_del(t) lm_del

// Buffer access, implemented in main.zig.
int64_t zv_buf_line_count(int64_t bufnr);  // -1 when the buffer is invalid
const char *zv_buf_get_line(int64_t bufnr, int64_t row, size_t *len);  // row is 0-based

#define strequal(a, b) (strcmp((a), (b)) == 0)
static uint64_t tslua_query_parse_count = 0;  // nvim__stats() field; nothing reads it yet
