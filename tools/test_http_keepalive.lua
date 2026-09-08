local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

local now=1000
local next_id=0
local function new_conn()
    next_id=next_id+1
    local conn={id=next_id,closed=false,connects=0}
    function conn:settimeout() return 1 end
    function conn:connect(host,port) self.host,self.port=host,tonumber(port); self.connects=self.connects+1; return 1 end
    function conn:close() self.closed=true; return 1 end
    function conn:send(data) return #(tostring(data or '')) end
    function conn:receive() return nil,'timeout','' end
    return conn
end

local Config={HTTP_KEEPALIVE=true}
package.preload['miuread.config']=function() return Config end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['socketutil']=function()
    return {block_timeout=15,total_timeout=35,set_timeout=function() end,reset_timeout=function() end}
end
package.preload['socket']=function()
    return {
        gettime=function() return now end,
        sleep=function(v) now=now+(tonumber(v) or 0) end,
        select=function(readable) return {} end,
        tcp=function() return new_conn() end,
        tcp4=function() return new_conn() end,
    }
end
package.preload['socket.http']=function() return {request=function() return 1,200,{['content-length']='0'},'HTTP/1.1 200 OK' end} end
package.preload['ssl.https']=function()
    return {
        request=function() return 1,200,{['content-length']='0'},'HTTP/1.1 200 OK' end,
        tcp=function()
            return function() return new_conn() end
        end,
    }
end
package.preload['socket.url']=function()
    local M={}
    function M.parse(url,defaults)
        local scheme,authority,path=tostring(url):match('^(https?)://([^/]+)(/.*)$')
        if not scheme then return nil end
        local host,port=authority:match('^(.-):(%d+)$')
        return {scheme=scheme,host=host or authority,port=tonumber(port) or tonumber(defaults and defaults.port),path=path}
    end
    function M.build(p)
        return tostring(p.scheme)..'://'..tostring(p.host)..':'..tostring(p.port)..tostring(p.path or '/')
    end
    return M
end
package.preload['ltn12']=function()
    return {source={string=function() return function() return nil end end},sink={table=function() return function() return 1 end end}}
end
package.preload['lfs']=function() return {} end
package.preload['miuread.json']=function() return {encode=function() return '{}' end,decode=function() return {} end} end
package.preload['miuread.network_policy']=function()
    local M={}
    function M:new() return setmetatable({}, {__index=M}) end
    function M:current_mode() return 'auto' end
    function M:should_force_ipv4() return false end
    function M:ipv4_available() return true end
    return M
end
package.preload['miuread.network_health']=function() return {} end
package.preload['miuread.cookies']=function() return {header=function() return '' end} end
package.preload['miuread.protocol']=function() return {USER_AGENT='MiuRead-test'} end
package.preload['miuread.util']=function()
    return {
        redact_url=function(v) return tostring(v) end,
        atomic_write=function() return true end,
        read_json_file=function() return nil end,
        copy=function(v) return v end,
    }
end

local Http=require('miuread.http')
local h=Http:new({data_dir='/tmp/miu-http-keepalive-test',temp_dir='/tmp'})

-- Opt-in boundaries.
assert(h:_keepalive_begin('https://weread.qq.com/web/test',{},false,'')==nil,'non opt-in request entered keep-alive')
Config.HTTP_KEEPALIVE=false
assert(h:_keepalive_begin('https://weread.qq.com/web/test',{keepalive=true},false,'')==nil,'disabled keep-alive did not fall back')
Config.HTTP_KEEPALIVE=true
assert(h:_keepalive_begin('https://example.com/web/test',{keepalive=true},false,'')==nil,'non-WeRead origin entered pool')
assert(h:_keepalive_begin('https://weread.qq.com/web/test',{keepalive=true},false,'/tmp/body.bin')==nil,'streaming request entered pool')

-- A complete HTTP/1.1 response may return its connection to the pool and the
-- next request to the same origin must reuse that exact connection.
local first=h:_keepalive_begin('https://weread.qq.com/web/a',{keepalive=true},false,'')
assert(first and first:connect('weread.qq.com',443)==1,'first pooled connection failed to open')
local first_conn=first.conn
h:_keepalive_finish(first,true,200,{['Content-Length']='3'},'HTTP/1.1 200 OK',nil)
assert(h.keepalive_pool and next(h.keepalive_pool)~=nil,'complete response was not returned to pool')
local second=h:_keepalive_begin('https://weread.qq.com/web/b',{keepalive=true},false,'')
assert(second and second.conn==first_conn and second.pooled==true,'same-origin connection was not reused')
assert(second:connect('weread.qq.com',443)==1 and second.reused==true,'reused connection was not accepted')
h:_keepalive_finish(second,true,200,{['Transfer-Encoding']='chunked'},'HTTP/1.1 200 OK',nil)

-- Connection: close and undelimited bodies must never return to the pool.
local close_session=h:_keepalive_begin('https://weread.qq.com/web/c',{keepalive=true},false,'')
assert(close_session:connect('weread.qq.com',443)==1)
local close_conn=close_session.conn
h:_keepalive_finish(close_session,true,200,{['Content-Length']='1',['Connection']='close'},'HTTP/1.1 200 OK',nil)
assert(close_conn.closed==true,'Connection: close socket was retained')

local undelimited=h:_keepalive_begin('https://weread.qq.com/web/d',{keepalive=true},false,'')
assert(undelimited:connect('weread.qq.com',443)==1)
local undelimited_conn=undelimited.conn
h:_keepalive_finish(undelimited,true,200,{},'HTTP/1.1 200 OK',nil)
assert(undelimited_conn.closed==true,'undelimited response socket was retained')

-- 64th use is the hard cap.
local capped=h:_keepalive_begin('https://weread.qq.com/web/e',{keepalive=true},false,'')
assert(capped:connect('weread.qq.com',443)==1)
capped.uses=63
local capped_conn=capped.conn
h:_keepalive_finish(capped,true,204,{},'HTTP/1.1 204 No Content',nil)
assert(capped_conn.closed==true,'64-use socket was returned to pool')

-- Explicit task cleanup must close all idle sockets and empty the pool.
local cleanup=h:_keepalive_begin('https://weread.qq.com/web/f',{keepalive=true},false,'')
assert(cleanup:connect('weread.qq.com',443)==1)
local cleanup_conn=cleanup.conn
h:_keepalive_finish(cleanup,true,304,{},'HTTP/1.1 304 Not Modified',nil)
h:close_idle_connections()
assert(cleanup_conn.closed==true and next(h.keepalive_pool)==nil,'close_idle_connections did not empty/close pool')

-- Source-level guard: transparent pool replay is read-only and requires no
-- response bytes. This protects POST writes from accidental future broadening.
local source_path=ROOT..'miuread/http.lua'
local f=assert(io.open(source_path,'rb')); local source=f:read('*a'); f:close()
assert(source:find('method == "GET" or method == "HEAD"',1,true),'GET/HEAD-only replay guard missing')
assert(source:find('keepalive.received_any ~= true',1,true),'no-response-byte replay guard missing')
assert(not source:find('method == "POST" or method == "GET"',1,true),'POST was added to transparent pool replay')

print('beta22 HTTP keep-alive: PASS')
