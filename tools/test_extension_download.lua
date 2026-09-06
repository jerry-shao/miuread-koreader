local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local SRC_ROOT=TOOL_DIR..'/..'
local ROOT=SRC_ROOT..'/miuread.koplugin/'
local TMP=(os.getenv('TMPDIR') or '/tmp')..'/miuread-beta11-download-tests'
package.path = ROOT..'?.lua;' .. package.path

local function trim(v) return tostring(v or ''):match('^%s*(.-)%s*$') end
local function file_size(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local n=f:seek('end'); f:close(); return n
end
local function read_file(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local s=f:read('*a'); f:close(); return s
end
local function write_file(path,data)
    local f=assert(io.open(path,'wb')); f:write(data); f:close(); return true
end
local real_execute=os.execute
os.execute=function(cmd)
    if tostring(cmd):match('^command %-v curl') then return 1 end
    if tostring(cmd):match('^command %-v sha256sum') then return 0 end
    if tostring(cmd):match('^command %-v busybox') then return 1 end
    if tostring(cmd):match('^command %-v openssl') then return 1 end
    return real_execute(cmd)
end

package.preload['miuread.config']=function()
    return {GITHUB_MIRRORS={'https://m1/','https://m2/','https://m3/'}}
end
package.preload['miuread.json']=function()
    return {encode=function() return '{}' end}
end
package.preload['logger']=function()
    return {info=function() end,warn=function() end,dbg=function() end}
end
package.preload['miuread.util']=function()
    return {
        trim=trim,
        mkdir=function(path) real_execute('mkdir -p '..string.format('%q',path)); return true end,
        file_exists=function(path) local f=io.open(path,'rb'); if f then f:close(); return true end; return false end,
        file_size=file_size,
        read_file=function(path) return read_file(path) end,
        atomic_write=function(path,data) return write_file(path,data) end,
        shell_quote=function(v) return string.format('%q',tostring(v or '')) end,
        copy_file_stream=function(src,dst)
            local s=read_file(src); if not s then return nil,'read failed' end
            write_file(dst,s); return true
        end,
        first_line=function(v,max) local s=tostring(v or ''):match('([^\r\n]*)') or ''; return s:sub(1,max or #s) end,
        id_name=function(v) return tostring(v or ''):gsub('[^%w%-_%.]','_') end,
    }
end

local GOOD='VALID-PACKAGE-CONTENT'
local BAD_SAME='BROKEN-PACKAGE-CONTEN'
local BAD_SHORT='SHORT'
local expected_sha='cd7348d1dda37cc182aa9d6b9f08f4452bf91d9caa144ee093e17e9c87b62efb'
local scenario='sha'
local calls={}
local preexisting_sizes={}
package.preload['miuread.http']=function()
    local H={}
    function H:new() return setmetatable({}, {__index=H}) end
    function H:download_to_file(url,path,opts)
        calls[#calls+1]=url
        preexisting_sizes[#preexisting_sizes+1]=file_size(path) or 0
        local data
        if scenario=='large_isolation' then
            data=string.rep('x',4096)
        elseif scenario=='mixed_retry' and url:match('^https://github%.com') then
            data=BAD_SHORT
        elseif scenario=='mixed_retry' and url:match('^https://m1/') then
            error('timeout')
        elseif url:match('^https://github%.com') then
            data=scenario=='size' and BAD_SHORT or (scenario=='nohash' and GOOD or BAD_SAME)
        elseif url:match('^https://m1/') then
            data=GOOD
        else
            error('unexpected source: '..url)
        end
        write_file(path,data)
        if opts and opts.on_chunk then opts.on_chunk(#data) end
        return true
    end
    return H
end

local D=require('miuread.extension_download')
local function clean(dir) real_execute('rm -rf '..string.format('%q',dir)); real_execute('mkdir -p '..string.format('%q',dir)) end
local function run_case(kind)
    scenario=kind; calls={}
    local dir=TMP..'/runtime-'..kind
    clean(dir)
    local result=D.run({},dir,{
        repo='test/plugin',url='https://github.com/test/plugin/releases/download/v1/p.zip',
        size=#GOOD,sha256=expected_sha,network={mode='auto'},mirrors={'https://m1/','https://m2/','https://m3/'},
    })
    assert(result and result.ok==true,kind..': expected successful failover')
    assert(result.route_key=='mirror:1',kind..': expected mirror:1, got '..tostring(result.route_key))
    assert(read_file(result.path)==GOOD,kind..': final package bytes differ')
    assert(#calls==2,kind..': should stop after first valid backup source')
    assert(calls[1]:match('^https://github%.com'),kind..': direct must be first')
    assert(calls[2]:match('^https://m1/'),kind..': mirror 1 must be second')
    local direct_part=dir..'/source-direct.part'
    assert(not read_file(direct_part),kind..': rejected direct partial must not remain for small package')
end
run_case('sha')
run_case('size')

-- beta.17: GitHub does not publish a digest for every historical Release.
-- A verified official asset may still install after archive/plugin validation;
-- compute and return a local SHA-256 so the installed record has a durable
-- fingerprint for later recovery/reinstall checks.
scenario='nohash'; calls={}
local nohash_dir=TMP..'/runtime-nohash'; clean(nohash_dir)
local nohash=D.run({},nohash_dir,{
    repo='test/nohash',url='https://github.com/test/nohash/releases/download/v1/p.zip',
    size=#GOOD,sha256='',allow_missing_sha=true,network={mode='direct'},mirrors={},
})
assert(nohash and nohash.ok==true,'missing-digest official asset should install after local validation')
assert(nohash.route_key=='direct','missing-digest case should keep official asset identity')
assert(nohash.sha256==expected_sha,'missing-digest official asset did not persist local SHA-256 fingerprint')

-- Sub-threshold partials stay route-local. beta.15 may seed another route only
-- after a checkpoint is large enough to be worth a verified Range resume.
scenario='large_isolation'; calls={}; preexisting_sizes={}
local large_dir=TMP..'/runtime-large-isolation'; clean(large_dir)
local large=D.run({},large_dir,{
    repo='test/large',url='https://github.com/test/large/releases/download/v1/p.zip',
    size=16*1024*1024+100,sha256=expected_sha,network={mode='auto'},mirrors={'https://m1/','https://m2/'},
})
assert(large and large.ok==false,'large isolation case should exhaust sources')
assert(#calls==3,'large isolation should try direct + two mirrors')
for i,n in ipairs(preexisting_sizes) do assert(n==0,'source '..tostring(i)..' inherited another source partial') end
assert(file_size(large_dir..'/source-direct.part')==4096,'direct partial should remain source-local')
assert(file_size(large_dir..'/source-mirror_1.part')==4096,'mirror1 partial should be independent')

-- A meaningful checkpoint may seed a different transport for the exact same
-- official asset. The original checkpoint must remain intact. curl is disabled
-- in this portable test, so the copied seed itself is the observable result.
local seed_dir=TMP..'/runtime-cross-route-seed'; clean(seed_dir)
local seed=string.rep('p',600*1024)
write_file(seed_dir..'/source-direct.part',seed)
local seeded=D.run({},seed_dir,{
    repo='test/seed',url='https://github.com/test/seed/releases/download/v1/p.zip',
    size=8*1024*1024,sha256=expected_sha,network={mode='auto'},mirrors={'https://m1/'},
})
assert(seeded and seeded.ok==false,'seed-only model should not complete without curl')
assert(file_size(seed_dir..'/source-direct.part')==#seed,'original checkpoint was destroyed')
assert(file_size(seed_dir..'/source-mirror_1.part')==#seed,'meaningful checkpoint did not seed the fallback route')

-- A bad/truncated mirror plus another route's temporary timeout is retryable,
-- not a terminal package-install failure.
scenario='mixed_retry'; calls={}
local mixed_dir=TMP..'/runtime-mixed-retry'; clean(mixed_dir)
-- Reuse the module mock but switch behavior through the shared scenario below.
local mixed=D.run({},mixed_dir,{
    repo='test/mixed',url='https://github.com/test/mixed/releases/download/v1/p.zip',
    size=#GOOD,sha256=expected_sha,network={mode='auto'},mirrors={'https://m1/'},
})
assert(mixed and mixed.ok==false and mixed.waiting_network==true,'mixed content/transport failure should preserve task for retry')

-- Manual source selection is fail-closed: an invalid requested mirror does not
-- silently fall back to GitHub.
assert(#D.build_sources('https://github.com/a/b/x.zip',{mode='mirror:9'},{'https://m1/'})==0)
print('extension_download failover + integrity model: PASS')

-- beta.15 route construction: GitHub Chinese community mirror is a transport
-- for the same official asset, not a different package identity.
local official='https://github.com/owner/demo.koplugin/releases/download/v2/demo.koplugin.zip'
local routes={
    {key='git_zh',label='GitHub 中文社区',mode='replace_host',base='https://mirrors.git-zh.com',preferred=true},
    {key='direct',label='GitHub 官方',mode='direct'},
    {key='ghfast',label='ghfast',mode='prefix',base='https://ghfast.top/'},
}
local auto=D.build_sources(official,{mode='auto'},nil,routes)
assert(#auto==3,'beta15 route list size mismatch')
assert(auto[1].key=='git_zh' and auto[1].url=='https://mirrors.git-zh.com/owner/demo.koplugin/releases/download/v2/demo.koplugin.zip','git-zh route transform incorrect')
assert(auto[2].key=='direct' and auto[2].url==official,'official route must retain exact asset URL')
assert(auto[3].key=='ghfast' and auto[3].url=='https://ghfast.top/'..official,'prefix route must retain exact asset identity')
local direct_only=D.build_sources(official,{mode='direct'},nil,routes)
assert(#direct_only==1 and direct_only[1].key=='direct','manual direct mode must fail closed to official route')
local zh_only=D.build_sources(official,{mode='route:git_zh'},nil,routes)
assert(#zh_only==1 and zh_only[1].key=='git_zh','manual GitHub Chinese route selection incorrect')
local bad_route=D.build_sources(official,{mode='route:not-there'},nil,routes)
assert(#bad_route==0,'invalid manual route must fail closed')
print('extension_download beta15 route identity: PASS')
