local FFIUtil=require("ffi/util")
local Json=require("miuread.json")
local U=require("miuread.util")
local UIManager=require("ui/uimanager")
local logger=require("logger")
local SubprocessHygiene=require("miuread.subprocess_hygiene")
local Power=require("miuread.pseudo_lockscreen")

local ExtensionTask={}
ExtensionTask.__index=ExtensionTask

local NETWORK_KEY="extension_center_network_v2"
local ACTIVE_STATES={
    downloading=true,waiting_network=true,paused_user=true,paused_power=true,
    interrupted=true,verifying=true,extracting=true,installing=true,downloaded=true,
    cancelled_resumable=true,
}
local RESUMABLE_STATES={
    waiting_network=true,paused_user=true,paused_power=true,interrupted=true,
    cancelled_resumable=true,failed=true,downloaded=true,
}

local function trim(value) return U.trim(tostring(value or "")) end
local function command_ok(rc) return rc==true or rc==0 end
local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw or raw=="" then return nil end
    local ok,value=pcall(Json.decode,raw)
    return ok and type(value)=="table" and value or nil
end
local function write_json(path,value)
    return U.atomic_write(path,Json.encode(type(value)=="table" and value or {}),true)
end
local function process_alive(pid)
    pid=tonumber(pid)
    return pid and pid>1 and command_ok(os.execute("kill -0 "..tostring(math.floor(pid)).." >/dev/null 2>&1")) or false
end

local function process_start_ticks(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return nil end
    local raw=U.read_file("/proc/"..tostring(math.floor(pid)).."/stat",true) or ""
    local rest=raw:match("^%d+ %b() (.+)$")
    if not rest then return nil end
    local index=0
    for token in rest:gmatch("%S+") do
        index=index+1
        -- /proc/<pid>/stat field 22 (starttime); rest begins at field 3.
        if index==20 then return tostring(token) end
    end
    return nil
end

local function safe_kill_owned_worker(owner)
    owner=type(owner)=="table" and owner or {}
    local pid=tonumber(owner.worker_pid)
    local expected=tostring(owner.worker_start_ticks or "")
    if not pid or pid<=1 or expected=="" or not process_alive(pid) then return false end
    local actual=process_start_ticks(pid)
    if actual~=expected then
        logger.warn("[MiuRead][ExtensionTask] stale worker pid reused; not killed","pid=",tostring(pid))
        return false
    end
    os.execute("kill "..tostring(math.floor(pid)).." >/dev/null 2>&1")
    return true
end
local function safe_kill_transport(task_dir)
    local pid=tonumber(trim(U.read_file(task_dir.."/transport.pid",true) or ""))
    if not pid or pid<=1 or not process_alive(pid) then return false end
    local cmdline=U.read_file("/proc/"..tostring(math.floor(pid)).."/cmdline",true) or ""
    cmdline=cmdline:gsub("%z"," ")
    -- Never kill an unrelated reused PID. A MiuRead curl worker command line
    -- contains the task directory because -o points inside it.
    if not cmdline:find(task_dir,1,true) then
        logger.warn("[MiuRead][ExtensionTask] stale transport pid not owned","pid=",tostring(pid))
        return false
    end
    os.execute("kill "..tostring(math.floor(pid)).." >/dev/null 2>&1")
    return true
end
local function valid_dir(path)
    return path and path~="" and U.mkdir(path) and true or false
end

function ExtensionTask:new(store)
    local root=tostring(store and store.data_dir or "").."/extensions/tasks"
    U.mkdir(tostring(store and store.data_dir or "").."/extensions")
    U.mkdir(root)
    local o=setmetatable({
        store=store,root=root,session=tostring(os.time()).."-"..tostring(math.random(100000,999999)),
        current=nil,worker_pid=nil,poll_task=nil,on_progress=nil,on_done=nil,
        resume_generation=0,last_progress_signature=nil,
    },self)
    o:_startup_reap()
    o:_adopt_latest_active()
    return o
end

function ExtensionTask:_task_path(task) return tostring(task and task.task_dir or "").."/task.json" end
function ExtensionTask:_save(task)
    if type(task)~="table" or trim(task.task_dir)=="" then return false end
    task.updated_at=os.time()
    U.mkdir(task.task_dir)
    return write_json(self:_task_path(task),task)
end

function ExtensionTask:_load_dir(path)
    local task=read_json(path.."/task.json")
    if type(task)=="table" then task.task_dir=path end
    return task
end

function ExtensionTask:list_tasks(include_completed)
    local out={}
    for _,path in ipairs(U.list(self.root)) do
        local task=self:_load_dir(path)
        if task and (include_completed==true or ACTIVE_STATES[tostring(task.state or "")]) then out[#out+1]=task end
    end
    table.sort(out,function(a,b) return (tonumber(a.updated_at) or 0)>(tonumber(b.updated_at) or 0) end)
    return out
end

function ExtensionTask:_startup_reap()
    local now=os.time()
    for _,path in ipairs(U.list(self.root)) do
        local task=self:_load_dir(path)
        if task then
            local state=tostring(task.state or "")
            local owner=read_json(path.."/owner.json") or {}
            if state=="downloading" or state=="verifying" or state=="extracting" or state=="installing" then
                safe_kill_transport(path)
                safe_kill_owned_worker(owner)
                task.state="interrupted"
                task.message="KOReader 上次退出时任务被中断，下载数据已保留"
                task.interrupted_at=now
                task.worker_pid=nil
                self:_save(task)
                os.remove(path.."/owner.json")
                logger.warn("[MiuRead][ExtensionTask] stale task reaped","task=",tostring(task.task_id),"owner_session=",tostring(owner.session or "-"))
            elseif (state=="completed" or state=="failed") and now-(tonumber(task.updated_at) or now)>7*24*60*60 then
                -- Keep a short recent history in the download centre, but not forever.
                U.remove_tree(path)
            end
        end
    end
end

function ExtensionTask:_adopt_latest_active()
    local list=self:list_tasks(false)
    if #list>0 then self.current=list[1] end
end

function ExtensionTask:snapshot()
    if self.current and trim(self.current.task_dir)~="" then
        local fresh=self:_load_dir(self.current.task_dir)
        if fresh then self.current=fresh end
    end
    return self.current and U.copy(self.current) or nil
end

function ExtensionTask:busy()
    return self.worker_pid~=nil or (self.current and ACTIVE_STATES[tostring(self.current.state or "")]==true) or false
end

function ExtensionTask:running()
    return self.worker_pid~=nil and self.current and self.current.state=="downloading" or false
end

function ExtensionTask:can_continue_locked()
    if self:running() then return true,"extension_download_active" end
    local state=self.current and tostring(self.current.state or "") or ""
    -- Verification/extraction/install are short local critical sections. On
    -- Kindle they may finish under the same screen-saver hold even though no
    -- network transport is running; Kobo/Android are still paused by main.lua's
    -- platform gate.
    if state=="verifying" or state=="extracting" or state=="installing" then
        return true,"extension_install_finish"
    end
    return false,state~="" and state or "no_extension_task"
end

function ExtensionTask:_power_active(value)
    pcall(Power.set_task_active,"extension_download",value==true)
    if value~=true then pcall(Power.background_task_done,"extension_download_done") end
end

function ExtensionTask:_kill_worker(reason)
    safe_kill_transport(self.current and self.current.task_dir or "")
    if self.worker_pid then pcall(FFIUtil.terminateSubProcess,self.worker_pid) end
    self.worker_pid=nil
    if self.poll_task then UIManager:unschedule(self.poll_task); self.poll_task=nil end
    self:_power_active(false)
    logger.info("[MiuRead][ExtensionTask] worker stopped","reason=",tostring(reason or "unknown"))
end

function ExtensionTask:_network_settings()
    local value=self.store:get(NETWORK_KEY,{mode="auto",custom_prefix="",health={}})
    value=type(value)=="table" and value or {mode="auto",custom_prefix="",health={}}
    value.health=type(value.health)=="table" and value.health or {}
    return value
end

function ExtensionTask:_update_route_stats(attempts)
    if type(attempts)~="table" then return end
    local network=self:_network_settings()
    local changed=false
    for _,attempt in ipairs(attempts) do
        local key=tostring(attempt.key or "")
        if key~="" then
            local h=type(network.health[key])=="table" and network.health[key] or {}
            if attempt.ok==true then
                h.success_at=os.time(); h.fail_count=0; h.last_error=nil
                local speed=tonumber(attempt.speed) or 0
                if speed>0 then
                    local old=tonumber(h.average_speed) or 0
                    h.average_speed=old>0 and math.floor(old*.65+speed*.35+.5) or math.floor(speed+.5)
                end
                if tonumber(attempt.ttfb) then h.ttfb=tonumber(attempt.ttfb) end
                if attempt.range_supported~=nil then h.range_supported=attempt.range_supported==true end
            else
                h.fail_at=os.time(); h.fail_count=math.min(8,(tonumber(h.fail_count) or 0)+1)
                h.last_error=U.first_line(tostring(attempt.error or attempt.kind or "下载失败"),120)
            end
            network.health[key]=h; changed=true
        end
    end
    if changed then self.store:set_deferred(NETWORK_KEY,network); self.store:flush() end
end

function ExtensionTask:_emit_progress(force)
    local task=self:snapshot()
    if not task then return end
    local progress=read_json(task.task_dir.."/progress.json") or {}
    for k,v in pairs(progress) do task[k]=v end
    task.kind="extension"
    task.repo=task.repo or (self.current and self.current.repo)
    task.name=task.name or (self.current and self.current.name)
    task.version=task.version or (self.current and self.current.version)
    if self.current then
        for _,key in ipairs({"task_id","task_dir","repo","name","version","source_url","size","sha256","used_url","route_key"}) do
            if self.current[key]~=nil and progress[key]==nil then task[key]=self.current[key] end
        end
        -- progress.json is transport telemetry; task.json is authoritative for
        -- lifecycle phases. Otherwise stale "downloading" telemetry would mask
        -- WAIT_NETWORK / VERIFY / EXTRACT / INSTALL states after the transfer.
        task.state=tostring(self.current.state or task.state or "")
        task.stage=tostring(self.current.stage or task.stage or task.state or "")
        task.message=tostring(self.current.message or task.message or "")
    end
    local sig=table.concat({tostring(task.state),tostring(task.stage),tostring(task.downloaded_bytes),tostring(task.speed_bps),tostring(task.message)},"|")
    if force or sig~=self.last_progress_signature then
        self.last_progress_signature=sig
        if type(self.on_progress)=="function" then pcall(self.on_progress,U.copy(task)) end
    end
end

function ExtensionTask:_schedule_poll()
    if self.poll_task or not self.worker_pid then return end
    local task
    task=function()
        if self.poll_task~=task then return end
        self.poll_task=nil
        self:_poll()
    end
    self.poll_task=task
    UIManager:scheduleIn(.55,task)
end

function ExtensionTask:_poll()
    if not self.worker_pid or not self.current then return end
    self:_emit_progress(false)
    local ok,done=pcall(FFIUtil.isSubProcessDone,self.worker_pid,false)
    if ok and done~=true then self:_schedule_poll(); return end
    if not ok then
        logger.warn("[MiuRead][ExtensionTask] worker status check failed",tostring(done))
        self:_schedule_poll(); return
    end

    local task=self.current
    local result=read_json(task.task_dir.."/result.json")
    self.worker_pid=nil
    os.remove(task.task_dir.."/owner.json")
    self:_power_active(false)
    if type(result)~="table" then result={ok=false,error="扩展下载进程没有返回结果",kind="interrupted"} end
    self:_update_route_stats(result.attempts)

    if result.ok==true and result.path then
        task.state="downloaded"; task.stage="downloaded"; task.package_path=result.path
        task.downloaded_bytes=tonumber(result.bytes) or U.file_size(result.path) or 0
        task.total_bytes=tonumber(task.size) or 0
        task.percent=task.total_bytes>0 and math.min(1,task.downloaded_bytes/task.total_bytes) or 1
        task.used_url=tostring(result.used_url or result.route_url or task.source_url or "")
        task.route_key=tostring(result.route_key or "")
        task.transport=tostring(result.transport or "")
        task.message="下载完成，准备校验"
        self:_save(task); self.current=task; self:_emit_progress(true)
        local done_cb=self.on_done
        if type(done_cb)=="function" then done_cb(U.copy(result),nil,U.copy(task)) end
        return
    end

    task.error=tostring(result.error or "下载失败")
    task.error_kind=tostring(result.kind or "transport_error")
    task.downloaded_bytes=tonumber(result.partial_bytes) or U.file_size(task.task_dir.."/package.part") or 0
    if result.waiting_network==true then
        task.state="waiting_network"; task.stage="waiting_network"
        task.message="等待网络，已保存下载进度"
        self:_save(task); self.current=task; self:_emit_progress(true)
        return
    end
    task.state="failed"; task.stage="error"; task.message="下载未完成，断点已保留"
    self:_save(task); self.current=task; self:_emit_progress(true)
    local done_cb=self.on_done
    if type(done_cb)=="function" then done_cb(nil,task.error,U.copy(task),result) end
end

function ExtensionTask:_find_resumable(spec)
    local repo=tostring(spec.repo or "")
    local version=tostring(spec.version or "")
    for _,task in ipairs(self:list_tasks(true)) do
        local same_identity=tostring(task.source_url or "")==tostring(spec.url or "")
        local old_sha=tostring(task.sha256 or ""):lower()
        local new_sha=tostring(spec.sha256 or ""):lower()
        if old_sha~="" and new_sha~="" and old_sha==new_sha then same_identity=true end
        if tostring(task.repo or "")==repo and tostring(task.version or "")==version
            and same_identity and RESUMABLE_STATES[tostring(task.state or "")]==true then
            local partial=U.file_size(task.task_dir.."/package.part") or 0
            local package=U.file_size(task.task_dir.."/package.zip") or 0
            if partial>0 or package>0 or tostring(task.state or "")=="waiting_network"
                or tostring(task.state or "")=="paused_power" then return task end
        end
    end
end

function ExtensionTask:_spawn(task,spec)
    if self.worker_pid then return false,"已有插件下载进程正在运行" end
    if not valid_dir(task.task_dir) then return false,"无法创建插件下载目录" end
    os.remove(task.task_dir.."/result.json")
    task.state="downloading"; task.stage="download"; task.message="正在下载"
    task.started_at=tonumber(task.started_at) or os.time(); task.updated_at=os.time()
    task.source_url=tostring(spec.url or task.source_url or "")
    task.size=tonumber(spec.size or task.size) or 0
    task.sha256=tostring(spec.sha256 or task.sha256 or "")
    task.spec=U.copy(spec)
    self:_save(task)
    self.current=task

    local store=self.store
    local task_dir=task.task_dir
    local child_spec=U.copy(spec)
    child_spec.network=self:_network_settings()
    child_spec.mirrors=U.copy(require("miuread.config").GITHUB_MIRRORS or {})
    local child=function()
        SubprocessHygiene.close_inherited_sockets()
        U.mkdir(task_dir)
        local Transfer=require("miuread.extension_transfer")
        local ok,value=pcall(Transfer.run,store,task_dir,child_spec)
        local result=ok and value or {ok=false,error=tostring(value),kind="worker_error"}
        write_json(task_dir.."/result.json",result)
    end
    local ok,pid,err=pcall(FFIUtil.runInSubProcess,child,false,false)
    if not ok or not pid then
        task.state="failed"; task.error=tostring(err or pid or "worker unavailable"); task.error_kind="worker"
        self:_save(task); self.current=task
        return false,task.error
    end
    self.worker_pid=pid
    task.worker_pid=pid
    self:_save(task)
    write_json(task.task_dir.."/owner.json",{
        task_id=task.task_id,session=self.session,worker_pid=pid,
        worker_start_ticks=process_start_ticks(pid),started_at=os.time(),
    })
    self:_power_active(true)
    logger.info("[MiuRead][ExtensionTask] started","task=",tostring(task.task_id),"pid=",tostring(pid),"repo=",tostring(task.repo))
    self:_emit_progress(true)
    self:_schedule_poll()
    return true
end

function ExtensionTask:start(spec,on_progress,on_done)
    spec=type(spec)=="table" and spec or {}
    if trim(spec.url)=="" then return false,"插件安装包地址为空" end
    if self:busy() and not (self.current and RESUMABLE_STATES[tostring(self.current.state or "")]) then
        return false,"已有插件下载任务正在进行"
    end
    if self.worker_pid then return false,"已有插件下载任务正在进行" end

    local task=self:_find_resumable(spec)
    if not task then
        local id="ext-"..U.id_name(spec.repo or spec.name or "plugin").."-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
        local dir=self.root.."/"..id
        U.mkdir(dir)
        task={
            task_id=id,task_dir=dir,kind="extension",repo=tostring(spec.repo or ""),name=tostring(spec.name or spec.repo or "扩展"),
            version=tostring(spec.version or ""),state="queued",stage="prepare",source_url=tostring(spec.url),
            size=tonumber(spec.size) or 0,sha256=tostring(spec.sha256 or ""),created_at=os.time(),updated_at=os.time(),
            deterministic=spec.deterministic==true,asset_name=tostring(spec.asset_name or ""),expected_dir=tostring(spec.expected_dir or ""),
        }
    else
        task.message="继续上次下载"; task.error=nil; task.error_kind=nil
    end
    self.on_progress=on_progress
    self.on_done=on_done
    self.current=task
    return self:_spawn(task,spec)
end

function ExtensionTask:set_callbacks(on_progress,on_done)
    self.on_progress=on_progress; self.on_done=on_done
end

function ExtensionTask:activate(task)
    if self.worker_pid then return false,"已有插件下载进程正在运行" end
    if type(task)~="table" or trim(task.task_dir)=="" then return false,"插件下载任务无效" end
    local fresh=self:_load_dir(task.task_dir)
    if not fresh then return false,"插件下载任务已经不存在" end
    self.current=fresh
    self.last_progress_signature=nil
    return true
end

function ExtensionTask:set_phase(state,message,extra)
    local task=self.current
    if not task then return false end
    task.state=tostring(state or task.state)
    task.stage=task.state
    task.message=tostring(message or task.message or "")
    for k,v in pairs(type(extra)=="table" and extra or {}) do task[k]=v end
    self:_save(task); self.current=task; self:_emit_progress(true)
    return true
end

function ExtensionTask:complete_install(extra)
    local task=self.current
    if not task then return false end
    task.state="completed"; task.stage="done"; task.message="安装完成"
    task.completed_at=os.time(); task.percent=1
    for k,v in pairs(type(extra)=="table" and extra or {}) do task[k]=v end
    self:_save(task); self.current=task; self:_emit_progress(true)
    self:_power_active(false)
    return true
end

function ExtensionTask:fail_install(message,kind)
    local task=self.current
    if not task then return false end
    task.state="failed"; task.stage="error"; task.error=tostring(message or "安装失败")
    task.error_kind=tostring(kind or "install"); task.message="安装失败"
    self:_save(task); self.current=task; self:_emit_progress(true)
    self:_power_active(false)
    return true
end

function ExtensionTask:pause(reason)
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    self:_kill_worker(reason or "manual_pause")
    task.state=reason=="power" and "paused_power" or "paused_user"
    task.stage=task.state
    task.message=reason=="power" and "设备休眠，唤醒联网后自动继续" or "下载已暂停，断点已保留"
    task.worker_pid=nil
    self:_save(task); self.current=task; self:_emit_progress(true)
    return true
end

function ExtensionTask:cancel()
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    self:_kill_worker("user_cancel")
    task.state="cancelled_resumable"; task.stage="cancelled"; task.message="下载已停止，断点已保留"
    task.worker_pid=nil
    self:_save(task); self.current=task; self:_emit_progress(true)
    return true
end

function ExtensionTask:delete_data(task)
    task=type(task)=="table" and task or self.current
    if not task then return false,"没有插件下载任务" end
    if self.current and task.task_id==self.current.task_id then self:_kill_worker("delete_data"); self.current=nil end
    return U.remove_tree(task.task_dir)~=nil
end

function ExtensionTask:resume(reason)
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    if self.worker_pid then return true end
    if not RESUMABLE_STATES[tostring(task.state or "")] then return false,"当前任务状态不支持继续" end
    local spec=type(task.spec)=="table" and task.spec or {
        repo=task.repo,name=task.name,version=task.version,url=task.source_url,size=task.size,sha256=task.sha256,
        deterministic=task.deterministic,asset_name=task.asset_name,expected_dir=task.expected_dir,
    }
    task.message="正在继续下载"
    logger.info("[MiuRead][ExtensionTask] resume","reason=",tostring(reason or "manual"),"task=",tostring(task.task_id))
    return self:_spawn(task,spec)
end

function ExtensionTask:on_suspend(mode)
    mode=tostring(mode or "REAL_SUSPEND")
    if not self.current then return true end
    if mode=="SCREEN_SAVER_HOLD" or mode=="PSEUDO_LOCKED" or mode=="DOWNLOAD_LOCKED" then
        logger.info("[MiuRead][ExtensionTask] screen-off transfer retained","mode=",mode,"running=",tostring(self:running()))
        return true
    end
    if self:running() then self:pause("power") end
    return true
end

local function network_connected()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then return true end
    if type(NetworkMgr.queryNetworkState)=="function" then pcall(NetworkMgr.queryNetworkState,NetworkMgr) end
    local connected=nil
    if type(NetworkMgr.isConnected)=="function" then
        local ok,value=pcall(NetworkMgr.isConnected,NetworkMgr)
        if ok then connected=value==true end
    end
    if connected==false then return false end
    if type(NetworkMgr.isOnline)=="function" then
        local ok,value=pcall(NetworkMgr.isOnline,NetworkMgr)
        if ok then return connected~=false and value==true end
    end
    if connected~=nil then return connected==true end
    if type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then return value==true end
    end
    return true
end

function ExtensionTask:on_resume()
    local task=self.current
    if not task or (task.state~="paused_power" and task.state~="waiting_network") then return false end
    self.resume_generation=self.resume_generation+1
    local generation=self.resume_generation
    local delays={1.0,3.2,6.2}
    for index,delay in ipairs(delays) do
        UIManager:scheduleIn(delay,function()
            if generation~=self.resume_generation or self.worker_pid or not self.current then return end
            local state=tostring(self.current.state or "")
            if state~="paused_power" and state~="waiting_network" then return end
            if network_connected() then
                if index<#delays and delay<3 then return end -- association needs a short stable window on Kindle
                self:resume("network_after_wake")
                return
            end
            if index==#delays then
                self.current.state="waiting_network"; self.current.stage="waiting_network"
                self.current.message="等待 Wi-Fi，已保存下载进度"
                self:_save(self.current); self:_emit_progress(true)
            end
        end)
    end
    return true
end

function ExtensionTask:on_user_resume_begin()
    self:_power_active(false)
    return true
end

function ExtensionTask:quiesce_for_exit(reason)
    if not self.current then return true end
    if self.worker_pid then self:_kill_worker("exit:"..tostring(reason or "unknown")) end
    local state=tostring(self.current.state or "")
    if state=="downloading" or state=="paused_power" or state=="waiting_network" then
        self.current.state="interrupted"; self.current.stage="interrupted"
        self.current.message="KOReader 已退出，断点已保留，可稍后继续"
        self.current.worker_pid=nil
        self:_save(self.current); self:_emit_progress(true)
    end
    return true
end

return ExtensionTask
