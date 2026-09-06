local Config=require("miuread.config")
local Http=require("miuread.http")
local Json=require("miuread.json")
local U=require("miuread.util")
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")

local M={}

local function now()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end

local function sleep(seconds)
    seconds=tonumber(seconds) or .5
    if ok_socket and socket and type(socket.sleep)=="function" then socket.sleep(seconds); return end
    os.execute("sleep "..tostring(seconds).." >/dev/null 2>&1")
end

local function trim(value)
    return U.trim(tostring(value or ""))
end

local function starts_with(value,prefix)
    value,prefix=tostring(value or ""),tostring(prefix or "")
    return value:sub(1,#prefix)==prefix
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function command_available(name)
    return command_ok(os.execute("command -v "..tostring(name).." >/dev/null 2>&1"))
end

local function ensure_dir(path)
    if U.mkdir(path) then return true end
    return U.file_exists(path) or false
end

local function read_number(path)
    local raw=trim(U.read_file(path,true) or "")
    return tonumber(raw)
end

local function process_alive(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return false end
    return command_ok(os.execute("kill -0 "..tostring(math.floor(pid)).." >/dev/null 2>&1"))
end

local function zip_magic_valid(path)
    local file=io.open(path,"rb")
    if not file then return false end
    local head=file:read(4) or ""
    file:close()
    return head=="PK\003\004" or head=="PK\005\006" or head=="PK\007\008"
end

local function classify_error(value,status)
    local text=tostring(value or "")
    local lower=text:lower()
    if tostring(status or "")=="404" then return "source_unavailable" end
    if tostring(status or "")=="403" or tostring(status or "")=="429" then return "http_error" end
    if lower:find("could not resolve",1,true) or lower:find("dns",1,true)
        or lower:find("name or service not known",1,true) then return "dns_unavailable" end
    if lower:find("network is unreachable",1,true) or lower:find("no route to host",1,true) then return "network_offline" end
    if lower:find("timed out",1,true) or lower:find("timeout",1,true) then return "connect_timeout" end
    if lower:find("ssl",1,true) or lower:find("tls",1,true) then return "tls_error" end
    if tostring(status or "")=="416" or lower:find("range",1,true) or lower:find("resume",1,true) then return "range_rejected" end
    return "transport_error"
end

local function route_label(key)
    if key=="direct" then return "GitHub" end
    if tostring(key):sub(1,7)=="mirror:" then return "镜像 "..tostring(key):sub(8) end
    if key=="custom" then return "自定义镜像" end
    return tostring(key or "下载源")
end

local function route_score(network,key,index)
    local health=type(network.health)=="table" and network.health or {}
    local h=type(health[key])=="table" and health[key] or {}
    local score=100-(tonumber(index) or 0)
    local current=os.time()
    local success_at=tonumber(h.success_at) or 0
    local fail_at=tonumber(h.fail_at) or 0
    local speed=tonumber(h.average_speed) or 0
    local ttfb=tonumber(h.ttfb) or 0
    if success_at>0 and current-success_at<7*24*60*60 then score=score+60 end
    if speed>0 then score=score+math.min(160,speed/(64*1024)*10) end
    if ttfb>0 then score=score-math.min(40,ttfb*8) end
    if h.range_supported==true then score=score+12 end
    if fail_at>0 and current-fail_at<10*60 then
        score=score-100*math.max(1,tonumber(h.fail_count) or 1)
    end
    return score
end

function M.build_routes(url,network,mirrors)
    network=type(network)=="table" and network or {mode="auto",health={}}
    local direct={key="direct",label="GitHub",url=tostring(url),index=0}
    if not starts_with(url,"https://github.com/") then return {direct} end
    local routes={}
    local mirror_rows={}
    for index,prefix in ipairs(type(mirrors)=="table" and mirrors or Config.GITHUB_MIRRORS or {}) do
        prefix=trim(prefix)
        if prefix:match("^https://") then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            mirror_rows[#mirror_rows+1]={key="mirror:"..tostring(index),label="镜像 "..tostring(index),url=prefix..url,index=index}
        end
    end
    local custom=trim(network.custom_prefix)
    if custom:match("^https://") then
        if custom:sub(-1)~="/" then custom=custom.."/" end
        mirror_rows[#mirror_rows+1]={key="custom",label="自定义镜像",url=custom..url,index=99}
    end

    local mode=tostring(network.mode or "auto")
    if mode=="direct" then return {direct} end
    if mode=="custom" then
        for _,route in ipairs(mirror_rows) do if route.key=="custom" then return {route} end end
        return {direct}
    end
    if mode:match("^mirror:%d+$") then
        for _,route in ipairs(mirror_rows) do if route.key==mode then return {route} end end
        return {direct}
    end

    routes[1]=direct
    for _,route in ipairs(mirror_rows) do if route.key~="custom" then routes[#routes+1]=route end end
    table.sort(routes,function(a,b)
        local sa=route_score(network,a.key,a.index)
        local sb=route_score(network,b.key,b.index)
        if sa~=sb then return sa>sb end
        return a.index<b.index
    end)
    -- Avoid route storms. Three distinct transports are enough for one attempt;
    -- offline/DNS errors stop the loop even earlier.
    while #routes>3 do table.remove(routes) end
    return routes
end

local function progress_writer(task_dir,spec)
    local progress_path=task_dir.."/progress.json"
    local last_bytes=0
    local last_clock=now()
    local ema=0
    local first_byte_at=nil
    local started=last_clock
    local last_write=0
    local last_write_percent=0
    local last_write_bytes=0
    return function(bytes,route,stage,force,extra)
        bytes=math.max(0,tonumber(bytes) or 0)
        local clock=now()
        if bytes>0 and not first_byte_at then first_byte_at=clock end
        local dt=clock-last_clock
        if dt>.15 and bytes>=last_bytes then
            local instant=(bytes-last_bytes)/dt
            if instant>=0 then ema=ema<=0 and instant or (ema*.72+instant*.28) end
            last_bytes=bytes
            last_clock=clock
        end
        local total=tonumber(spec.size or 0) or 0
        local percent=total>0 and math.min(1,bytes/total) or 0
        local eta=total>bytes and ema>1 and math.floor((total-bytes)/ema+.5) or nil
        local should=force==true or clock-last_write>=.8
            or bytes-last_write_bytes>=512*1024
            or (total>0 and percent-last_write_percent>=.01)
        if not should then return end
        last_write=clock
        last_write_percent=percent
        last_write_bytes=bytes
        local payload={
            kind="extension",state="downloading",stage=tostring(stage or "download"),
            downloaded_bytes=bytes,total_bytes=total,percent=percent,
            speed_bps=math.floor(ema+.5),eta_seconds=eta,
            route_key=route and route.key or "",source=route and (route.label or route_label(route.key)) or "",
            resumed=extra and extra.resumed==true or false,
            message=extra and tostring(extra.message or "") or "",
            updated_at=os.time(),elapsed_seconds=math.max(0,clock-started),
            ttfb_seconds=first_byte_at and math.max(0,first_byte_at-started) or nil,
        }
        U.atomic_write(progress_path,Json.encode(payload),true)
    end
end

local function write_transport_script(task_dir,route,target,resume,connect_timeout,stall_seconds)
    ensure_dir(task_dir)
    local script=task_dir.."/transport.sh"
    local pid_path=task_dir.."/transport.pid"
    local exit_path=task_dir.."/transport.exit"
    local status_path=task_dir.."/transport.status"
    local error_path=task_dir.."/transport.error"
    os.remove(pid_path); os.remove(exit_path); os.remove(status_path); os.remove(error_path)
    local cmd="curl -L --fail --silent --show-error --connect-timeout "..tostring(connect_timeout)
        .." --speed-limit 1024 --speed-time "..tostring(stall_seconds)
        .." --retry 1 --retry-delay 1"
    if resume then cmd=cmd.." -C -" end
    cmd=cmd.." -o "..U.shell_quote(target)
        .." -w "..U.shell_quote("%{http_code}")
        .." "..U.shell_quote(route.url)
        .." >"..U.shell_quote(status_path).." 2>"..U.shell_quote(error_path)
    local body=table.concat({
        "#!/bin/sh",
        "rm -f "..U.shell_quote(exit_path),
        cmd.." &",
        "cpid=$!",
        "echo \"$cpid\" > "..U.shell_quote(pid_path),
        "wait \"$cpid\"",
        "rc=$?",
        "echo \"$rc\" > "..U.shell_quote(exit_path),
        "exit \"$rc\"",
        "",
    },"\n")
    if not U.atomic_write(script,body,true) then return nil,"无法创建下载脚本" end
    os.execute("chmod 700 "..U.shell_quote(script).." >/dev/null 2>&1")
    local launched=command_ok(os.execute("sh "..U.shell_quote(script).." >/dev/null 2>&1 &"))
    if not launched then return nil,"无法启动 curl" end
    local deadline=now()+3
    while now()<deadline and not U.file_exists(exit_path) and not U.file_exists(pid_path) do sleep(.05) end
    return {pid_path=pid_path,exit_path=exit_path,status_path=status_path,error_path=error_path,script=script}
end

local function run_curl(task_dir,route,target,resume,publish,spec)
    local info,launch_error=write_transport_script(task_dir,route,target,resume,
        tonumber(spec.connect_timeout) or 8,tonumber(spec.stall_seconds) or 35)
    if not info then return nil,{error=launch_error or "curl 启动失败",kind="transport_error"} end
    local started=now()
    local initial_size=U.file_size(target) or 0
    local last_size=initial_size
    local first_progress_at=nil
    publish(last_size,route,"download",true,{resumed=resume})
    while true do
        local rc=read_number(info.exit_path)
        local pid=read_number(info.pid_path)
        local current=U.file_size(target) or 0
        if current~=last_size then
            if current>initial_size and not first_progress_at then first_progress_at=now() end
            last_size=current
            publish(current,route,"download",false,{resumed=resume})
        end
        if rc~=nil then break end
        if pid and not process_alive(pid) and not U.file_exists(info.exit_path) then
            -- Give the shell a short chance to persist the exit status.
            sleep(.15)
            if not U.file_exists(info.exit_path) then break end
        end
        sleep(.45)
    end
    local rc=read_number(info.exit_path)
    local status=trim(U.read_file(info.status_path,true) or "")
    local err=trim(U.read_file(info.error_path,true) or "")
    local size=U.file_size(target) or 0
    publish(size,route,"download",true,{resumed=resume})
    local elapsed=math.max(.001,now()-started)
    local ok=tonumber(rc)==0 and size>0
    if ok and tonumber(spec.size or 0)>0 and size~=tonumber(spec.size) then
        ok=false
        err="下载大小与目录记录不一致"
    end
    if ok and not zip_magic_valid(target) then
        ok=false
        err="下载内容不是 ZIP"
    end
    if ok then
        local transferred=math.max(0,size-initial_size)
        return {
            ok=true,path=target,bytes=size,status=status,elapsed=elapsed,
            speed=transferred/elapsed,route_key=route.key,route_url=route.url,
            ttfb=first_progress_at and math.max(0,first_progress_at-started) or nil,
            range_supported=resume and true or nil,
        }
    end
    return nil,{
        error=err~="" and err or "curl 下载失败",status=status,bytes=size,elapsed=elapsed,
        kind=classify_error(err,status),route_key=route.key,route_url=route.url,
        resumed=resume,
    }
end

local function promote(candidate,package_path,canonical_partial)
    os.remove(package_path)
    local ok,err=os.rename(candidate,package_path)
    if not ok then
        local copied,copy_err=U.copy_file_stream(candidate,package_path,256*1024)
        if not copied then return nil,"无法保存插件包："..tostring(copy_err or err or "copy failed") end
        os.remove(candidate)
    end
    if canonical_partial and canonical_partial~=candidate then os.remove(canonical_partial) end
    return package_path
end

function M.run(store,task_dir,spec)
    spec=type(spec)=="table" and spec or {}
    if not ensure_dir(task_dir) then return {ok=false,error="无法创建扩展下载目录",kind="task_storage"} end
    local package_path=task_dir.."/package.zip"
    local canonical=task_dir.."/package.part"
    local publish=progress_writer(task_dir,spec)
    local routes=M.build_routes(spec.url,spec.network,spec.mirrors)
    local attempts={}
    local expected=tonumber(spec.size or 0) or 0
    local identity_proven=expected>0 or trim(spec.sha256)~=""

    if U.file_exists(package_path) and (U.file_size(package_path) or 0)>0 then
        publish(U.file_size(package_path) or 0,routes[1],"download",true,{message="已存在完整下载文件"})
        return {ok=true,path=package_path,bytes=U.file_size(package_path) or 0,attempts=attempts,route_key="cached",used_url=spec.url}
    end

    -- beta.4-style fast path: KOReader's own streaming HTTP is again primary.
    -- It runs only from byte zero. Any interrupted bytes are preserved for the
    -- recovery layer instead of being discarded.
    if (U.file_size(canonical) or 0)==0 and routes[1] then
        local route=routes[1]
        local http=Http:new(store)
        local started=now()
        local first_fast_byte=nil
        logger.info("[MiuRead][ExtensionTransfer] fast path start","route=",route.key,"url=",tostring(route.url))
        local called,result=pcall(function()
            return http:download_to_file(route.url,canonical,{
                auth=false,retries=0,redirects=10,timeout={8,6*60*60},
                integrity_attempts=1,preserve_partial=true,
                on_chunk=function(bytes)
                    if tonumber(bytes) and tonumber(bytes)>0 and not first_fast_byte then first_fast_byte=now() end
                    publish(bytes,route,"download",false,{resumed=false})
                end,
                heartbeat_seconds=1,heartbeat_bytes=256*1024,
            })
        end)
        local elapsed=math.max(.001,now()-started)
        local size=U.file_size(canonical) or 0
        publish(size,route,"download",true,{resumed=false})
        if called and size>0 and (expected<=0 or size==expected) and zip_magic_valid(canonical) then
            local final,promote_error=promote(canonical,package_path,canonical)
            if final then
                local speed=size/elapsed
                local ttfb=first_fast_byte and math.max(0,first_fast_byte-started) or nil
                attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=size,elapsed=elapsed,speed=speed,ttfb=ttfb,url=route.url,transport="koreader_http"}
                return {ok=true,path=final,bytes=size,attempts=attempts,route_key=route.key,used_url=route.url,transport="koreader_http",speed=speed,ttfb=ttfb}
            end
            return {ok=false,error=promote_error,kind="task_storage",attempts=attempts}
        end
        local err=called and tostring(result or "KOReader HTTP 下载不完整") or tostring(result or "KOReader HTTP 下载失败")
        local kind=classify_error(err,"")
        attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=err,bytes=size,elapsed=elapsed,url=route.url,transport="koreader_http"}
        logger.warn("[MiuRead][ExtensionTransfer] fast path failed","route=",route.key,"bytes=",tostring(size),"error=",err)
        if kind=="dns_unavailable" or kind=="network_offline" then
            return {ok=false,waiting_network=true,error=err,kind=kind,attempts=attempts,partial_bytes=size}
        end
    end

    if not command_available("curl") then
        local partial=U.file_size(canonical) or 0
        return {ok=false,error="KOReader 下载中断且当前设备没有 curl，断点已保留",kind="interrupted",attempts=attempts,partial_bytes=partial}
    end

    for index,route in ipairs(routes) do
        local source_bytes=U.file_size(canonical) or 0
        local candidate
        local resume=false
        if index==1 and source_bytes>0 then
            candidate=canonical
            resume=true
        elseif source_bytes>0 and identity_proven then
            candidate=task_dir.."/package."..U.id_name(route.key)..".part"
            os.remove(candidate)
            local copied=U.copy_file_stream(canonical,candidate,256*1024)
            if copied then resume=true else candidate=task_dir.."/package."..U.id_name(route.key)..".fresh.part" end
        else
            candidate=task_dir.."/package."..U.id_name(route.key)..".part"
            os.remove(candidate)
        end

        local result,detail=run_curl(task_dir,route,candidate,resume,publish,spec)
        if result then
            local final,promote_error=promote(result.path,package_path,canonical)
            if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
            attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=result.bytes,elapsed=result.elapsed,speed=result.speed,ttfb=result.ttfb,url=route.url,transport="curl",range_supported=result.range_supported}
            result.path=final; result.used_url=route.url; result.attempts=attempts; result.transport="curl"
            return result
        end

        detail=type(detail)=="table" and detail or {error=tostring(detail or "下载失败")}
        attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=detail.error,bytes=detail.bytes,elapsed=detail.elapsed,url=route.url,transport="curl",kind=detail.kind}
        logger.warn("[MiuRead][ExtensionTransfer] recovery route failed","route=",route.key,"kind=",tostring(detail.kind),"error=",tostring(detail.error))

        if detail.kind=="range_rejected" and resume then
            -- Never destroy the canonical partial just because this endpoint
            -- refuses Range. Retry this route from byte zero in a separate file.
            local fresh=task_dir.."/package."..U.id_name(route.key)..".restart.part"
            os.remove(fresh)
            local fresh_result,fresh_detail=run_curl(task_dir,route,fresh,false,publish,spec)
            if fresh_result then
                local final,promote_error=promote(fresh_result.path,package_path,canonical)
                if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=fresh_result.bytes,elapsed=fresh_result.elapsed,speed=fresh_result.speed,ttfb=fresh_result.ttfb,url=route.url,transport="curl_restart",range_supported=false}
                fresh_result.path=final; fresh_result.used_url=route.url; fresh_result.attempts=attempts; fresh_result.transport="curl_restart"
                return fresh_result
            end
            if fresh_detail and (fresh_detail.kind=="dns_unavailable" or fresh_detail.kind=="network_offline") then
                return {ok=false,waiting_network=true,error=fresh_detail.error,kind=fresh_detail.kind,attempts=attempts,partial_bytes=U.file_size(canonical) or 0}
            end
        end

        if detail.kind=="dns_unavailable" or detail.kind=="network_offline" then
            return {ok=false,waiting_network=true,error=detail.error,kind=detail.kind,attempts=attempts,partial_bytes=U.file_size(canonical) or 0}
        end
    end

    return {ok=false,error="所有可用下载源均失败，已保留可恢复断点",kind="sources_failed",attempts=attempts,partial_bytes=U.file_size(canonical) or 0}
end

return M
