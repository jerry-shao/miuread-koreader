-- MiuRead built-in extension downloader v4.
--
-- Deliberately small policy surface:
--   * deterministic source order (official -> configured mirrors -> custom)
--   * one KOReader HTTP attempt and one curl fallback per source
--   * source-local partial files only; partials are never copied across sources
--   * a source is successful only after expected size + SHA-256 validation
--
-- The installer owns archive/structure validation. This module returns only a
-- byte-for-byte verified local package.

local Config=require("miuread.config")
local Http=require("miuread.http")
local Json=require("miuread.json")
local U=require("miuread.util")
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")

local M={}

local LARGE_RESUME_BYTES=16*1024*1024

local function now()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end

local function sleep(seconds)
    seconds=tonumber(seconds) or .4
    if ok_socket and socket and type(socket.sleep)=="function" then socket.sleep(seconds); return end
    os.execute("sleep "..tostring(seconds).." >/dev/null 2>&1")
end

local function trim(value) return U.trim(tostring(value or "")) end
local function starts_with(value,prefix)
    value,prefix=tostring(value or ""),tostring(prefix or "")
    return value:sub(1,#prefix)==prefix
end
local function command_ok(rc) return rc==true or rc==0 end
local function command_available(name)
    return command_ok(os.execute("command -v "..tostring(name).." >/dev/null 2>&1"))
end
local function process_alive(pid)
    pid=tonumber(pid)
    return pid and pid>1 and command_ok(os.execute("kill -0 "..tostring(math.floor(pid)).." >/dev/null 2>&1")) or false
end
local function read_number(path)
    local raw=trim(U.read_file(path,true) or "")
    return tonumber(raw)
end
local function ensure_dir(path)
    return U.mkdir(path) or U.file_exists(path) or false
end

local function route_label(key)
    if key=="direct" then return "GitHub" end
    if tostring(key):sub(1,7)=="mirror:" then return "镜像 "..tostring(key):sub(8) end
    if key=="custom" then return "自定义镜像" end
    return tostring(key or "下载源")
end

local function normalize_prefix(prefix)
    prefix=trim(prefix)
    if not prefix:match("^https://") then return nil end
    if prefix:sub(-1)~="/" then prefix=prefix.."/" end
    return prefix
end

function M.build_sources(url,network,mirrors)
    url=tostring(url or "")
    network=type(network)=="table" and network or {mode="auto",custom_prefix=""}
    local direct={key="direct",label="GitHub",url=url,index=1}
    if not starts_with(url,"https://github.com/") then return {direct} end

    local configured={}
    for index,prefix in ipairs(type(mirrors)=="table" and mirrors or Config.GITHUB_MIRRORS or {}) do
        prefix=normalize_prefix(prefix)
        if prefix then
            configured[#configured+1]={
                key="mirror:"..tostring(index),label="镜像 "..tostring(index),url=prefix..url,index=index+1,
            }
        end
    end
    local custom=normalize_prefix(network.custom_prefix)
    local custom_route=custom and {key="custom",label="自定义镜像",url=custom..url,index=100} or nil
    local mode=tostring(network.mode or "auto")
    if mode=="direct" then return {direct} end
    if mode=="custom" then return custom_route and {custom_route} or {} end
    if mode:match("^mirror:%d+$") then
        for _,route in ipairs(configured) do if route.key==mode then return {route} end end
        return {}
    end

    local out={direct}
    for _,route in ipairs(configured) do out[#out+1]=route end
    -- A configured custom prefix is an explicit user-provided fallback. In auto
    -- mode it is tried last, never promoted by historical speed/health data.
    if custom_route then out[#out+1]=custom_route end
    return out
end

local function classify_error(value,status)
    local text=tostring(value or "")
    local lower=text:lower()
    status=tostring(status or "")
    if status=="404" then return "source_unavailable" end
    if status=="403" or status=="429" then return "http_error" end
    if lower:find("could not resolve",1,true) or lower:find("dns",1,true)
        or lower:find("name or service not known",1,true) then return "dns_unavailable" end
    if lower:find("network is unreachable",1,true) or lower:find("no route to host",1,true) then return "network_offline" end
    if lower:find("timed out",1,true) or lower:find("timeout",1,true) then return "connect_timeout" end
    if lower:find("ssl",1,true) or lower:find("tls",1,true) then return "tls_error" end
    if status=="416" or lower:find("range",1,true) or lower:find("resume",1,true) then return "range_rejected" end
    return "transport_error"
end

local function sha256_file(path)
    if not U.file_exists(path) then return nil,"文件不存在" end
    local commands={}
    if command_available("sha256sum") then commands[#commands+1]="sha256sum "..U.shell_quote(path).." 2>/dev/null" end
    if command_available("busybox") then commands[#commands+1]="busybox sha256sum "..U.shell_quote(path).." 2>/dev/null" end
    if command_available("openssl") then commands[#commands+1]="openssl dgst -sha256 "..U.shell_quote(path).." 2>/dev/null" end
    for _,cmd in ipairs(commands) do
        local pipe=io.popen(cmd,"r")
        if pipe then
            local raw=pipe:read("*l") or ""
            pipe:close()
            local value=raw:match("([0-9a-fA-F][0-9a-fA-F]+)%s*$") or raw:match("^([0-9a-fA-F]+)")
            if value and #value==64 then return value:lower() end
        end
    end
    -- Small packages have a safe in-process fallback. Large packages deliberately
    -- avoid reading the entire archive into Lua memory on e-ink devices.
    local size=U.file_size(path) or 0
    if size>0 and size<=8*1024*1024 then
        local raw=U.read_file(path,true)
        if raw then
            local ok,D=pcall(require,"miuread.digests")
            if ok and D and type(D.sha256)=="function" then return D.sha256(raw):lower() end
        end
    end
    return nil,"设备缺少可用于大文件的 SHA-256 校验工具"
end

local function validate_download(path,spec)
    if not U.file_exists(path) then return nil,"下载文件不存在","missing" end
    local size=U.file_size(path) or 0
    if size<=0 then return nil,"下载文件为空","empty" end
    local expected=tonumber(spec.size or 0) or 0
    if expected>0 and size~=expected then
        return nil,"下载大小不完整：应为 "..tostring(expected).." 字节，实际 "..tostring(size).." 字节","size"
    end
    local expected_sha=trim(spec.sha256):lower():gsub("[^0-9a-f]","")
    if expected_sha=="" then
        return nil,"内置扩展缺少 SHA-256 目录记录","catalog_integrity"
    end
    local actual,sha_error=sha256_file(path)
    if not actual then return nil,sha_error or "无法计算 SHA-256","sha_unavailable" end
    if actual~=expected_sha then
        return nil,"SHA-256 校验失败；下载内容与目录记录不一致","sha256"
    end
    return {size=size,sha256=actual}
end

local function progress_writer(task_dir,spec,total_sources)
    local progress_path=task_dir.."/progress.json"
    local last_bytes,last_clock,last_write=0,now(),0
    local ema=0
    return function(bytes,route,transport,force,message,source_index)
        bytes=math.max(0,tonumber(bytes) or 0)
        local clock=now()
        local dt=clock-last_clock
        if dt>.15 and bytes>=last_bytes then
            local instant=(bytes-last_bytes)/dt
            if instant>=0 then ema=ema<=0 and instant or (ema*.72+instant*.28) end
            last_bytes,last_clock=bytes,clock
        end
        if force~=true and clock-last_write<.8 then return end
        last_write=clock
        local total=tonumber(spec.size or 0) or 0
        local percent=total>0 and math.min(1,bytes/total) or 0
        local payload={
            kind="extension",state="downloading",stage="download",downloaded_bytes=bytes,total_bytes=total,
            percent=percent,speed_bps=math.floor(ema+.5),route_key=route and route.key or "",
            source=route and route.label or "",transport=tostring(transport or ""),message=tostring(message or ""),
            source_index=tonumber(source_index) or 1,source_total=tonumber(total_sources) or 1,updated_at=os.time(),
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
    if resume then cmd=cmd.." -C -" end
    cmd=cmd.." -o "..U.shell_quote(target)
        .." -w "..U.shell_quote("%{http_code}")
        .." "..U.shell_quote(route.url)
        .." >"..U.shell_quote(status_path).." 2>"..U.shell_quote(error_path)
    local body=table.concat({
        "#!/bin/sh","rm -f "..U.shell_quote(exit_path),cmd.." &","cpid=$!",
        "echo \"$cpid\" > "..U.shell_quote(pid_path),"wait \"$cpid\"","rc=$?",
        "echo \"$rc\" > "..U.shell_quote(exit_path),"exit \"$rc\"","",
    },"\n")
    if not U.atomic_write(script,body,true) then return nil,"无法创建下载脚本" end
    os.execute("chmod 700 "..U.shell_quote(script).." >/dev/null 2>&1")
    if not command_ok(os.execute("sh "..U.shell_quote(script).." >/dev/null 2>&1 &")) then return nil,"无法启动 curl" end
    local deadline=now()+3
    while now()<deadline and not U.file_exists(exit_path) and not U.file_exists(pid_path) do sleep(.05) end
    if not U.file_exists(exit_path) and not U.file_exists(pid_path) then
        return nil,"curl 子进程未能启动"
    end
    return {pid_path=pid_path,exit_path=exit_path,status_path=status_path,error_path=error_path}
end

local function run_curl(task_dir,route,target,resume,publish,spec,source_index,total_sources)
    local info,launch_error=write_transport_script(task_dir,route,target,resume,tonumber(spec.connect_timeout) or 8,tonumber(spec.stall_seconds) or 35)
    if not info then return nil,{error=launch_error or "curl 启动失败",kind="transport_error"} end
    publish(U.file_size(target) or 0,route,"curl",true,resume and "正在继续同一下载源" or "",source_index)
    local last_size=U.file_size(target) or 0
    while true do
        local rc=read_number(info.exit_path)
        local pid=read_number(info.pid_path)
        local current=U.file_size(target) or 0
        if current~=last_size then last_size=current; publish(current,route,"curl",false,"",source_index) end
        if rc~=nil then break end
        if pid and not process_alive(pid) and not U.file_exists(info.exit_path) then
            sleep(.15)
            if not U.file_exists(info.exit_path) then break end
        end
        sleep(.45)
    end
    local rc=read_number(info.exit_path)
    local status=trim(U.read_file(info.status_path,true) or "")
    local err=trim(U.read_file(info.error_path,true) or "")
    local size=U.file_size(target) or 0
    publish(size,route,"curl",true,"",source_index)
    if tonumber(rc)==0 and size>0 then return {path=target,bytes=size,status=status} end
    return nil,{error=err~="" and err or "curl 下载失败",kind=classify_error(err,status),status=status,bytes=size}
end

local function promote(candidate,package_path)
    os.remove(package_path)
    local ok,err=os.rename(candidate,package_path)
    if ok then return package_path end
    local copied,copy_err=U.copy_file_stream(candidate,package_path,256*1024)
    if not copied then return nil,"无法保存插件包："..tostring(copy_err or err or "copy failed") end
    os.remove(candidate)
    return package_path
end

local function attempt_record(attempts,route,transport,ok,kind,error,bytes)
    attempts[#attempts+1]={
        key=route.key,label=route.label,url=route.url,transport=transport,ok=ok==true,
        kind=tostring(kind or (ok and "verified" or "transport_error")),error=error and U.first_line(tostring(error),180) or nil,
        bytes=tonumber(bytes) or 0,
    }
end

local function network_link_ready()
    -- This is deliberately a link-state check, not a repair routine or an
    -- Internet probe. The parent task performs the normal NetworkMgr readiness
    -- gate; the child only uses this to distinguish a real Wi-Fi drop from one
    -- hostname/route failing while another mirror may still be reachable.
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then return true end
    if type(NetworkMgr.isConnected)=="function" then
        local ok,value=pcall(NetworkMgr.isConnected,NetworkMgr)
        if ok then return value==true end
    end
    if type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then return value==true end
    end
    return true
end

local function should_wait_network(_,kind)
    if kind~="network_offline" and kind~="dns_unavailable" then return false end
    return network_link_ready()~=true
end

local function source_part(task_dir,route)
    return task_dir.."/source-"..U.id_name(route.key)..".part"
end

function M.run(store,task_dir,spec)
    spec=type(spec)=="table" and spec or {}
    if not ensure_dir(task_dir) then return {ok=false,error="无法创建扩展下载目录",kind="task_storage"} end
    local package_path=task_dir.."/package.zip"
    local sources=M.build_sources(spec.url,spec.network,spec.mirrors)
    if #sources==0 then return {ok=false,error="没有可用扩展下载源",kind="no_source"} end
    local attempts={}
    local publish=progress_writer(task_dir,spec,#sources)
    local expected=tonumber(spec.size or 0) or 0
    local persistent_resume=expected>=LARGE_RESUME_BYTES

    -- Cache is never trusted. It is revalidated before reuse.
    if U.file_exists(package_path) then
        local verified,verify_error,verify_kind=validate_download(package_path,spec)
        if verified then
            logger.info("[MiuRead][ExtensionDownload] cached package verified","repo=",tostring(spec.repo),"bytes=",tostring(verified.size))
            publish(verified.size,sources[1],"cache",true,"已验证现有下载文件",1)
            return {ok=true,path=package_path,bytes=verified.size,sha256=verified.sha256,route_key="cached",used_url=tostring(spec.url),transport="cache",attempts=attempts}
        end
        logger.warn("[MiuRead][ExtensionDownload] cached package rejected","kind=",tostring(verify_kind),"error=",tostring(verify_error))
        os.remove(package_path)
    end

    local curl_available=command_available("curl")
    for index,route in ipairs(sources) do
        local part=source_part(task_dir,route)
        local existing=U.file_size(part) or 0
        if expected>0 and existing>expected then os.remove(part); existing=0 end
        if not persistent_resume and existing>0 then os.remove(part); existing=0 end

        -- A previously completed source-local partial may already be valid.
        if existing>0 and (expected<=0 or existing==expected) then
            local verified,verify_error,verify_kind=validate_download(part,spec)
            if verified then
                local final,promote_error=promote(part,package_path)
                if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                attempt_record(attempts,route,"resume_cache",true,"verified",nil,verified.size)
                logger.info("[MiuRead][ExtensionDownload] source verified","source=",route.key,"transport=resume_cache","bytes=",tostring(verified.size))
                return {ok=true,path=final,bytes=verified.size,sha256=verified.sha256,route_key=route.key,used_url=route.url,transport="resume_cache",attempts=attempts}
            end
            attempt_record(attempts,route,"resume_cache",false,verify_kind,verify_error,existing)
            os.remove(part); existing=0
        end

        -- KOReader HTTP is the primary byte-zero transport. A large source-local
        -- partial is intentionally left for curl to resume; it is never copied to
        -- another route.
        if existing==0 then
            local http=Http:new(store)
            logger.info("[MiuRead][ExtensionDownload] source start","source=",route.key,"transport=koreader_http","index=",tostring(index),"total=",tostring(#sources))
            publish(0,route,"koreader_http",true,"正在尝试 "..route.label,index)
            local called,result=pcall(function()
                return http:download_to_file(route.url,part,{
                    auth=false,retries=0,redirects=10,timeout={8,6*60*60},integrity_attempts=1,preserve_partial=true,
                    on_chunk=function(bytes) publish(bytes,route,"koreader_http",false,"",index) end,
                    heartbeat_seconds=1,heartbeat_bytes=256*1024,
                })
            end)
            local bytes=U.file_size(part) or 0
            if called and bytes>0 then
                local verified,verify_error,verify_kind=validate_download(part,spec)
                if verified then
                    local final,promote_error=promote(part,package_path)
                    if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                    attempt_record(attempts,route,"koreader_http",true,"verified",nil,verified.size)
                    logger.info("[MiuRead][ExtensionDownload] source verified","source=",route.key,"transport=koreader_http","bytes=",tostring(verified.size))
                    return {ok=true,path=final,bytes=verified.size,sha256=verified.sha256,route_key=route.key,used_url=route.url,transport="koreader_http",attempts=attempts}
                end
                attempt_record(attempts,route,"koreader_http",false,verify_kind,verify_error,bytes)
                logger.warn("[MiuRead][ExtensionDownload] source content rejected","source=",route.key,"transport=koreader_http","kind=",tostring(verify_kind),"bytes=",tostring(bytes),"error=",tostring(verify_error))
                if verify_kind=="sha_unavailable" or verify_kind=="catalog_integrity" then
                    return {ok=false,error=verify_error,kind=verify_kind,attempts=attempts,partial_bytes=bytes}
                end
                -- A full-size wrong-SHA file is not a resumable partial. Retry
                -- this same source once through curl from byte zero.
                if expected>0 and bytes>=expected then os.remove(part); bytes=0 end
                if not persistent_resume then os.remove(part); bytes=0 end
            else
                local err=called and tostring(result or "KOReader HTTP 下载失败") or tostring(result or "KOReader HTTP 下载失败")
                local kind=classify_error(err,"")
                attempt_record(attempts,route,"koreader_http",false,kind,err,bytes)
                logger.warn("[MiuRead][ExtensionDownload] transport failed","source=",route.key,"transport=koreader_http","kind=",kind,"bytes=",tostring(bytes),"error=",err)
                if should_wait_network(route,kind) then
                    return {ok=false,waiting_network=true,error=err,kind=kind,attempts=attempts,partial_bytes=bytes}
                end
                if not persistent_resume then os.remove(part); bytes=0 end
            end
        end

        if curl_available then
            local bytes=U.file_size(part) or 0
            local resume=persistent_resume and bytes>0 and (expected<=0 or bytes<expected)
            logger.info("[MiuRead][ExtensionDownload] source start","source=",route.key,"transport=curl","resume=",tostring(resume),"bytes=",tostring(bytes))
            local curl_result,curl_error=run_curl(task_dir,route,part,resume,publish,spec,index,#sources)
            if curl_result then
                local verified,verify_error,verify_kind=validate_download(part,spec)
                if verified then
                    local final,promote_error=promote(part,package_path)
                    if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                    attempt_record(attempts,route,resume and "curl_resume" or "curl",true,"verified",nil,verified.size)
                    logger.info("[MiuRead][ExtensionDownload] source verified","source=",route.key,"transport=curl","bytes=",tostring(verified.size))
                    return {ok=true,path=final,bytes=verified.size,sha256=verified.sha256,route_key=route.key,used_url=route.url,transport=resume and "curl_resume" or "curl",attempts=attempts}
                end
                attempt_record(attempts,route,resume and "curl_resume" or "curl",false,verify_kind,verify_error,U.file_size(part) or 0)
                logger.warn("[MiuRead][ExtensionDownload] source content rejected","source=",route.key,"transport=curl","kind=",tostring(verify_kind),"error=",tostring(verify_error))
                if verify_kind=="sha_unavailable" or verify_kind=="catalog_integrity" then
                    return {ok=false,error=verify_error,kind=verify_kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                end
                -- A resumable partial may itself have been polluted by an
                -- interrupted/proxy response. Before rejecting this source,
                -- retry it once from byte zero through curl.
                if resume then
                    os.remove(part)
                    local fresh,fresh_error=run_curl(task_dir,route,part,false,publish,spec,index,#sources)
                    if fresh then
                        local fresh_verified,fresh_verify_error,fresh_verify_kind=validate_download(part,spec)
                        if fresh_verified then
                            local final,promote_error=promote(part,package_path)
                            if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                            attempt_record(attempts,route,"curl_restart",true,"verified",nil,fresh_verified.size)
                            logger.info("[MiuRead][ExtensionDownload] source verified","source=",route.key,"transport=curl_restart","bytes=",tostring(fresh_verified.size))
                            return {ok=true,path=final,bytes=fresh_verified.size,sha256=fresh_verified.sha256,route_key=route.key,used_url=route.url,transport="curl_restart",attempts=attempts}
                        end
                        attempt_record(attempts,route,"curl_restart",false,fresh_verify_kind,fresh_verify_error,U.file_size(part) or 0)
                        if fresh_verify_kind=="sha_unavailable" or fresh_verify_kind=="catalog_integrity" then
                            return {ok=false,error=fresh_verify_error,kind=fresh_verify_kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                        end
                    else
                        fresh_error=type(fresh_error)=="table" and fresh_error or {error=tostring(fresh_error or "curl 重新下载失败"),kind="transport_error"}
                        attempt_record(attempts,route,"curl_restart",false,fresh_error.kind,fresh_error.error,U.file_size(part) or 0)
                        if should_wait_network(route,fresh_error.kind) then
                            return {ok=false,waiting_network=true,error=fresh_error.error,kind=fresh_error.kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                        end
                    end
                end
                os.remove(part)
            else
                curl_error=type(curl_error)=="table" and curl_error or {error=tostring(curl_error or "curl 下载失败"),kind="transport_error"}
                attempt_record(attempts,route,resume and "curl_resume" or "curl",false,curl_error.kind,curl_error.error,U.file_size(part) or 0)
                logger.warn("[MiuRead][ExtensionDownload] transport failed","source=",route.key,"transport=curl","kind=",tostring(curl_error.kind),"error=",tostring(curl_error.error))
                if curl_error.kind=="range_rejected" and resume then
                    os.remove(part)
                    local fresh,fresh_error=run_curl(task_dir,route,part,false,publish,spec,index,#sources)
                    if fresh then
                        local verified,verify_error,verify_kind=validate_download(part,spec)
                        if verified then
                            local final,promote_error=promote(part,package_path)
                            if not final then return {ok=false,error=promote_error,kind="task_storage",attempts=attempts} end
                            attempt_record(attempts,route,"curl_restart",true,"verified",nil,verified.size)
                            return {ok=true,path=final,bytes=verified.size,sha256=verified.sha256,route_key=route.key,used_url=route.url,transport="curl_restart",attempts=attempts}
                        end
                        attempt_record(attempts,route,"curl_restart",false,verify_kind,verify_error,U.file_size(part) or 0)
                        if verify_kind=="sha_unavailable" or verify_kind=="catalog_integrity" then
                            return {ok=false,error=verify_error,kind=verify_kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                        end
                        os.remove(part)
                    else
                        fresh_error=type(fresh_error)=="table" and fresh_error or {error=tostring(fresh_error or "curl 重新下载失败"),kind="transport_error"}
                        attempt_record(attempts,route,"curl_restart",false,fresh_error.kind,fresh_error.error,U.file_size(part) or 0)
                        if should_wait_network(route,fresh_error.kind) then
                            return {ok=false,waiting_network=true,error=fresh_error.error,kind=fresh_error.kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                        end
                    end
                end
                if should_wait_network(route,curl_error.kind) then
                    return {ok=false,waiting_network=true,error=curl_error.error,kind=curl_error.kind,attempts=attempts,partial_bytes=U.file_size(part) or 0}
                end
                if not persistent_resume then os.remove(part) end
            end
        else
            logger.warn("[MiuRead][ExtensionDownload] curl unavailable","source=",route.key)
        end
    end

    local partial=0
    for _,route in ipairs(sources) do partial=math.max(partial,U.file_size(source_part(task_dir,route)) or 0) end
    local network_only=#attempts>0
    for _,attempt in ipairs(attempts) do
        local kind=tostring(attempt.kind or "")
        if kind~="dns_unavailable" and kind~="network_offline" then network_only=false; break end
    end
    if network_only then
        return {ok=false,waiting_network=true,error="当前网络或 DNS 尚未就绪，已保留下载进度",kind="network_unready",attempts=attempts,partial_bytes=partial}
    end
    return {ok=false,error="所有可用下载源均失败",kind="sources_failed",attempts=attempts,partial_bytes=partial}
end

M.validate_download=validate_download
M.LARGE_RESUME_BYTES=LARGE_RESUME_BYTES

return M
