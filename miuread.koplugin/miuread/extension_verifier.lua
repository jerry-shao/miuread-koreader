local U=require("miuread.util")

local M={}

local function command_ok(rc)
    return rc==true or rc==0
end

local function command_available(name)
    return command_ok(os.execute("command -v "..tostring(name).." >/dev/null 2>&1"))
end

local function sha256_file(path)
    if not U.file_exists(path) then return nil,"文件不存在" end
    local commands={}
    if command_available("sha256sum") then
        commands[#commands+1]="sha256sum "..U.shell_quote(path).." 2>/dev/null"
    end
    if command_available("busybox") then
        commands[#commands+1]="busybox sha256sum "..U.shell_quote(path).." 2>/dev/null"
    end
    if command_available("openssl") then
        commands[#commands+1]="openssl dgst -sha256 "..U.shell_quote(path).." 2>/dev/null"
    end
    for _,cmd in ipairs(commands) do
        local pipe=io.popen(cmd,"r")
        if pipe then
            local raw=pipe:read("*l") or ""
            pipe:close()
            local value=raw:match("([0-9a-fA-F][0-9a-fA-F]+)%s*$") or raw:match("^([0-9a-fA-F]+)")
            if value and #value==64 then return value:lower() end
        end
    end
    return nil,"设备缺少可用的 SHA-256 校验工具"
end

local function zip_magic(path)
    local file=io.open(path,"rb")
    if not file then return nil,"无法读取下载文件" end
    local head=file:read(4) or ""
    file:close()
    if head=="PK\003\004" or head=="PK\005\006" or head=="PK\007\008" then return true end
    return nil,"下载内容不是 ZIP"
end

function M.verify(path,spec)
    spec=type(spec)=="table" and spec or {}
    if not U.file_exists(path) then return nil,"下载文件不存在","missing" end
    local size=U.file_size(path) or 0
    if size<=0 then return nil,"下载文件为空","empty" end

    local expected=tonumber(spec.size or spec.archive_size or 0) or 0
    if expected>0 and size~=expected then
        return nil,"下载大小不完整：应为 "..tostring(expected).." 字节，实际 "..tostring(size).." 字节","size"
    end

    local expected_sha=tostring(spec.sha256 or ""):lower():gsub("[^0-9a-f]","")
    local actual_sha=""
    if expected_sha~="" then
        local sha,err=sha256_file(path)
        if not sha then return nil,err or "无法计算 SHA-256","sha_unavailable" end
        actual_sha=sha
        if sha~=expected_sha then
            return nil,"SHA-256 校验失败；下载内容与目录记录不一致","sha256"
        end
    end

    local magic,magic_error=zip_magic(path)
    if not magic then return nil,magic_error,"zip_magic" end
    if command_available("unzip") then
        local ok=command_ok(os.execute("unzip -tqq "..U.shell_quote(path).." >/dev/null 2>&1"))
        if not ok then return nil,"ZIP 下载不完整或已经损坏","zip_integrity" end
    end

    return {
        size=size,
        sha256=actual_sha,
        expected_size=expected,
        expected_sha256=expected_sha,
    }
end

return M
