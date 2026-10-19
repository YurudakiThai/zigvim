#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <uv.h>
#include <stdlib.h>
#include <string.h>

// lua_pushcfunction is a macro in Lua, define it here for Zig
#define lua_pushcfunction(L, f) lua_pushcclosure(L, f, 0)
