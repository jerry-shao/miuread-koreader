local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local SRC_ROOT=TOOL_DIR..'/..'
local ROOT=SRC_ROOT..'/miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path
local lfs=require('lfs')
local BASE=(os.getenv('TMPDIR') or '/tmp')..'/miuread-beta11-install-runtime'
local DATA=BASE..'/data'
local TASK=BASE..'/task'
local real_execute=os.execute
local real_rename=os.rename
local fail_swap=false

local function q(s) return string.format('%q',tostring(s)) end
local function mkdir_p(path) real_execute('mkdir -p '..q(path)); return true end
local function exists(path) return lfs.attributes(path)~=nil end
local function file_exists(path) return lfs.attributes(path,'mode')=='file' end
local function read_file(path) local f=io.open(path,'rb'); if not f then return nil end; local s=f:read('*a'); f:close(); return s end
local function write_file(path,data)
    local parent=tostring(path):match('^(.*)/[^/]+$'); if parent then mkdir_p(parent) end
    local f=assert(io.open(path,'wb')); f:write(data or ''); f:close(); return true
end
local function remove_tree(path) real_execute('rm -rf '..q(path)); return true end
local function copy_tree(src,dst)
    local rc=real_execute('cp -a '..q(src)..' '..q(dst)); return (rc==true or rc==0) and true or nil
end
os.rename=function(from,to)
    if fail_swap and tostring(from):find('.miuread-new-',1,true) and tostring(to):match('/test%.koplugin$') then
        return nil,'injected swap failure'
    end
    return real_rename(from,to)
end

package.preload['datastorage']=function() return {getDataDir=function() return DATA end} end
package.preload['libs/libkoreader-lfs']=function() return lfs end
package.preload['miuread.json']=function() return {encode=function() return '{}' end} end
package.preload['miuread.util']=function()
    return {
        trim=function(v) return tostring(v or ''):match('^%s*(.-)%s*$') end,
        read_file=function(path) return read_file(path) end,
        atomic_write=function(path,data) return write_file(path,data) end,
        file_exists=file_exists,
        file_size=function(path) return lfs.attributes(path,'size') end,
        mkdir=mkdir_p,
        remove_tree=remove_tree,
        copy_tree=copy_tree,
        free_space=function() return 1024*1024*1024 end,
    }
end
package.preload['miuread.extension_compat']=function()
    return {evaluate=function() return {installable=true} end,validate_candidate=function() return true end}
end
package.preload['logger']=function() return {info=function() end,warn=function() end} end

local fake_entries={}
local fake_content={}
package.preload['ffi/archiver']=function()
    local Reader={}
    function Reader:new() return setmetatable({entries=fake_entries},{__index=Reader}) end
    function Reader:open(path) return file_exists(path) end
    function Reader:close() return true end
    function Reader:iterate()
        local i=0; local entries=self.entries
        return function() i=i+1; return entries[i] end
    end
    function Reader:extractToPath(path,dest)
        if fake_content[path]==nil then return false end
        return write_file(dest,fake_content[path])
    end
    return {Reader=Reader}
end

local Install=require('miuread.extension_install')
local function reset_old()
    remove_tree(BASE); mkdir_p(DATA..'/plugins/test.koplugin'); mkdir_p(TASK)
    write_file(DATA..'/plugins/test.koplugin/main.lua','return {}')
    write_file(DATA..'/plugins/test.koplugin/_meta.lua','return {version="1.0", fullname="Old"}')
    write_file(TASK..'/package.zip','fake zip bytes')
    fake_entries={
        {path='test.koplugin/main.lua',mode='file'},
        {path='test.koplugin/_meta.lua',mode='file'},
    }
    fake_content={
        ['test.koplugin/main.lua']='return {}',
        ['test.koplugin/_meta.lua']='return {version="2.0", fullname="New"}',
    }
end
local spec={repo='test/test.koplugin',expected_dir='test.koplugin',existing_path=DATA..'/plugins/test.koplugin',max_plugin_bytes=1024*1024,entry={},compatibility={installable=true}}

-- Successful transactional update.
reset_old(); fail_swap=false
local value,err,kind=Install.install({},TASK,TASK..'/package.zip',spec)
assert(value, tostring(kind)..':'..tostring(err))
assert(read_file(DATA..'/plugins/test.koplugin/_meta.lua'):find('2.0',1,true),'new version not installed')
assert(not file_exists(TASK..'/package.zip'),'verified package should be consumed after install')
assert(not file_exists(TASK..'/install-journal.json'),'journal should be cleared on success')

-- Inject failure during final new->target switch. Old plugin must be restored.
reset_old(); fail_swap=true
local value2,err2,kind2=Install.install({},TASK,TASK..'/package.zip',spec)
assert(value2==nil and kind2=='swap_new','expected injected swap_new failure')
assert(read_file(DATA..'/plugins/test.koplugin/_meta.lua'):find('1.0',1,true),'old plugin was not restored')
assert(not file_exists(TASK..'/install-journal.json'),'journal should be cleared after synchronous rollback')
fail_swap=false

-- Unsafe archive paths fail before extraction/installation.
reset_old()
fake_entries={{path='../escape.lua',mode='file'}}
fake_content={['../escape.lua']='bad'}
local value3,err3,kind3=Install.install({},TASK,TASK..'/package.zip',spec)
assert(value3==nil and kind3=='archive_validate','unsafe archive should fail validation')
assert(read_file(DATA..'/plugins/test.koplugin/_meta.lua'):find('1.0',1,true),'unsafe archive touched old plugin')

print('extension_install transaction + rollback + path safety: PASS')
