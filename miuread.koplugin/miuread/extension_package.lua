-- Package resolver v3.
-- Curated entries may carry a deterministic package descriptor. Unknown/community
-- repositories still use the generic planner, but the UI decides when multiple
-- candidates need explicit user choice instead of silently walking every asset.
local Compat=require("miuread.extension_compat")
local LegacyPlanner=require("miuread.extension_installer")

local M={}

local function starts_with(value,prefix)
    value,prefix=tostring(value or ""),tostring(prefix or "")
    return value:sub(1,#prefix)==prefix
end

local function normalize_package(entry,repo)
    local package=type(entry) == "table" and entry.package or nil
    if type(package)~="table" then return nil end
    local artifact=type(package.artifact)=="table" and package.artifact or package
    local url=tostring(artifact.url or package.url or "")
    if not starts_with(url,"https://") then return nil end
    local install=type(package.install)=="table" and package.install or {}
    local version=tostring(package.version or artifact.version or "")
    return {
        url=url,
        version=version,
        source=tostring(package.type or "catalog-package"),
        channel=tostring(package.channel or "release"),
        remote_ref=tostring(package.remote_ref or (version~="" and ("release:"..version) or "catalog:"..tostring(entry.id or repo or "package"))),
        asset_name=tostring(artifact.name or url:match("/([^/?#]+)$") or "package.zip"),
        size=tonumber(artifact.size or package.size) or 0,
        sha256=tostring(artifact.sha256 or package.sha256 or ""),
        expected_dir=tostring(install.dirname or package.install_dirname or ""),
        layout=tostring(install.layout or package.layout or ""),
        min_koreader=tostring((type(package.compatibility)=="table" and package.compatibility.min_koreader) or package.min_koreader or ""),
        deterministic=true,
        score=10000,
    }
end

function M.plan(entry,plugin,repo,repo_info,release,installed_record)
    entry=type(entry)=="table" and entry or {}
    local effective={}
    for k,v in pairs(entry) do effective[k]=v end
    local package=type(entry.package)=="table" and entry.package or {}
    local package_compat=type(package.compatibility)=="table" and package.compatibility or {}
    if tostring(effective.min_koreader or "")=="" and tostring(package_compat.min_koreader or "")~="" then
        effective.min_koreader=tostring(package_compat.min_koreader)
    end
    local compatibility=Compat.evaluate(effective,plugin)
    if compatibility.installable~=true then
        return nil,compatibility.block_reason or "当前设备不支持自动安装此扩展",compatibility
    end
    if tostring(entry.install_strategy or "")=="external_manual" or entry.auto_install==false then
        return nil,"此扩展需要从作者发布渠道手动安装",compatibility
    end

    local pinned=normalize_package(entry,repo)
    if pinned then return {pinned},nil,compatibility,{mode="catalog",deterministic=true} end

    local sources,err,legacy_compat=LegacyPlanner.plan(entry,plugin,repo,repo_info,release,installed_record)
    if not sources then return nil,err,legacy_compat or compatibility,{mode="community",deterministic=false} end
    for _,source in ipairs(sources) do source.deterministic=false end
    return sources,nil,legacy_compat or compatibility,{mode=entry.recommended==true and "curated_dynamic" or "community",deterministic=false}
end

function M.describe(source)
    source=type(source)=="table" and source or {}
    if source.deterministic==true then
        local version=tostring(source.version or "")
        return version~="" and ("目录固定包 · "..version) or "目录固定包"
    end
    if tostring(source.asset_name or "")~="" then return tostring(source.asset_name) end
    if source.source=="branch-source" then return "仓库分支源码" end
    if source.source=="release-source" then return "Release 源码包" end
    return tostring(source.source or "安装包")
end

return M
