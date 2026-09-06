local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local SRC_ROOT=TOOL_DIR..'/..'
package.path=SRC_ROOT..'/miuread.koplugin/?.lua;'..package.path

-- texlua is Lua 5.3 and does not ship LuaJIT's `bit` module. Provide a 32-bit
-- compatibility shim only for this portable regression test; KOReader uses its
-- native LuaJIT bit module at runtime.
package.preload['bit']=package.preload['bit'] or function()
    local M={}
    local function u(x) return (x & 0xffffffff) end
    function M.band(a,...) local r=u(a or 0); for i=1,select('#',...) do r=u(r & u(select(i,...))) end; return r end
    function M.bor(a,...) local r=u(a or 0); for i=1,select('#',...) do r=u(r | u(select(i,...))) end; return r end
    function M.bxor(a,...) local r=u(a or 0); for i=1,select('#',...) do r=u(r ~ u(select(i,...))) end; return r end
    function M.bnot(a) return u(~u(a)) end
    function M.lshift(a,n) return u(u(a) << n) end
    function M.rshift(a,n) return u(u(a) >> n) end
    function M.rol(a,n) n=n%32; local x=u(a); if n==0 then return x end; return u((x << n) | (x >> (32-n))) end
    function M.ror(a,n) n=n%32; local x=u(a); if n==0 then return x end; return u((x >> n) | (x << (32-n))) end
    return M
end

local D=require('miuread.digests')
local TMP=(os.getenv('TMPDIR') or '/tmp')..'/miuread-beta15-digest.bin'
local f=assert(io.open(TMP,'wb'))
for i=1,20000 do f:write(string.rep(string.char(i%251),137)) end
f:close()
local pipe=assert(io.popen('sha256sum '..string.format('%q',TMP),'r'))
local expected=(pipe:read('*l') or ''):match('^(%x+)')
pipe:close()
local actual,err=D.sha256_file(TMP,65536)
os.remove(TMP)
assert(actual,err or 'streaming digest failed')
assert(actual==expected,'streaming SHA-256 mismatch')
assert(D.sha256('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','string SHA-256 regression')
print('streaming SHA-256: PASS')
