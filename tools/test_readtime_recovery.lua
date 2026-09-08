local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
local TMP=(os.getenv('TMPDIR') or '/tmp')..'/miuread-beta19-readtime-recovery'
package.path=ROOT..'?.lua;'..package.path
os.execute('rm -rf '..string.format('%q',TMP)); os.execute('mkdir -p '..string.format('%q',TMP))

local function copy(v,seen)
    if type(v)~='table' then return v end
    seen=seen or {}; if seen[v] then return seen[v] end
    local out={}; seen[v]=out
    for k,x in pairs(v) do out[copy(k,seen)]=copy(x,seen) end
    return out
end
local function merge(a,b)
    local out=copy(a or {})
    for k,v in pairs(b or {}) do
        if type(v)=='table' and type(out[k])=='table' then out[k]=merge(out[k],v) else out[k]=copy(v) end
    end
    return out
end
local function encode(v,seen)
    local t=type(v)
    if t=='nil' then return 'nil' elseif t=='boolean' or t=='number' then return tostring(v)
    elseif t=='string' then return string.format('%q',v) elseif t~='table' then error('unsupported '..t) end
    seen=seen or {}; assert(not seen[v],'cycle'); seen[v]=true
    local parts={'{'}
    for k,x in pairs(v) do parts[#parts+1]='['..encode(k,seen)..']='..encode(x,seen)..',' end
    parts[#parts+1]='}'; seen[v]=nil; return table.concat(parts)
end
local function decode(s)
    local f,err=load('return '..tostring(s or '')); assert(f,err)
    return f()
end
local fail_write=false
package.preload['ui/event']=function() return {new=function(_,...) return {...} end} end
package.preload['ui/uimanager']=function() return {scheduleIn=function() end,unschedule=function() end} end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['ffi/util']=function() return {} end
package.preload['miuread.json']=function() return {encode=encode,decode=decode} end
package.preload['miuread.config']=function() return {READ_INTERVAL=60,READ_FIRST_DELAY=15,REMOTE_THRESHOLD=3,CONTROL_WRITE_DELAY=60} end
package.preload['miuread.read_report_service']=function() return {} end
package.preload['miuread.protocol']=function() return {} end
package.preload['miuread.http']=function() return {} end
package.preload['miuread.legacy_adapter_worker']=function() return {} end
package.preload['miuread.book_integrity']=function() return {} end
package.preload['miuread.precise_position']=function() return {} end
package.preload['miuread.source_position']=function() return {} end
package.preload['miuread.subprocess_hygiene']=function() return {} end
package.preload['miuread.util']=function()
    return {
        copy=copy,merge=merge,
        clamp=function(v,a,b) v=tonumber(v) or a; if v<a then return a elseif v>b then return b end; return v end,
        read_file=function(path,binary) local f=io.open(path,binary and 'rb' or 'r'); if not f then return nil end; local d=f:read('*a'); f:close(); return d end,
        atomic_write=function(path,data,binary)
            if fail_write then return nil,'forced write failure' end
            local f=assert(io.open(path,binary and 'wb' or 'w')); f:write(data or ''); f:close(); return true
        end,
        first_line=function(v) return tostring(v or '') end,
    }
end

local Sync=require('miuread.sync')
local sessions={book1={}}
local auth={login_session_id='login-1',account={vid='vid-1'}}
local full_flushes=0
local store={data_dir=TMP,auth=function() return copy(auth) end}
function store:session(id) return copy(sessions[id] or {}) end
function store:save_session(id,patch,flush_now)
    sessions[id]=merge(sessions[id] or {},patch or {})
    if flush_now~=false then full_flushes=full_flushes+1 end
    return copy(sessions[id]),true
end
local sync=setmetatable({store=store},Sync)

local ok,state=sync:_save_safe_pending_state('book1',25,'core-1')
assert(ok==true and full_flushes==0,'SAFE pending should use tiny journal, not full settings')
assert(sessions.book1.pending_report_seconds==25 and sessions.book1.pending_report_safe==true,'live session SAFE pending missing')
local pending,authoritative=sync:_load_readtime_recovery('book1','core-1')
assert(authoritative==true and pending==25,'journal did not restore SAFE pending')

ok,state=sync:_save_safe_pending_state('book1',0,'core-1')
assert(ok==true and full_flushes==0,'zero tombstone should stay tiny')
pending,authoritative=sync:_load_readtime_recovery('book1','core-1')
assert(authoritative==true and pending==0,'zero tombstone must override stale settings debt')

-- Even if an older full settings snapshot still says 25 seconds, the journal's
-- zero tombstone remains authoritative and prevents duplicate replay.
sessions.book1.pending_report_seconds=25; sessions.book1.pending_report_safe=true
pending,authoritative=sync:_load_readtime_recovery('book1','core-1')
assert(authoritative==true and pending==0,'stale full-settings SAFE debt could replay after accepted report')

-- Recovery debt may never cross an account/session boundary.
auth.account.vid='vid-2'
pending,authoritative=sync:_load_readtime_recovery('book1','core-1')
assert(authoritative==true and pending==0,'recovery debt crossed account identity')
auth.account.vid='vid-1'

-- If the tiny journal cannot be written, correctness must win: use beta.18's
-- full settings persistence for this crash-critical state.
fail_write=true
ok,state=sync:_save_safe_pending_state('book1',31,'core-1')
assert(ok==true and full_flushes==1,'journal failure did not fall back to full settings persistence')
assert(sessions.book1.pending_report_seconds==31 and sessions.book1.pending_report_safe==true,'fallback lost SAFE pending')

print('beta19 readtime recovery journal: PASS')
