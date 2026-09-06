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
        elseif url:match('^https://github%.com') then
            data=scenario=='size' and BAD_SHORT or BAD_SAME
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

-- Large-file partials stay attached to the exact source. A partial written by
-- GitHub must never appear as the starting bytes of a mirror transport.
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

-- Manual source selection is fail-closed: an invalid requested mirror does not
-- silently fall back to GitHub.
assert(#D.build_sources('https://github.com/a/b/x.zip',{mode='mirror:9'},{'https://m1/'})==0)
print('extension_download failover + integrity model: PASS')
