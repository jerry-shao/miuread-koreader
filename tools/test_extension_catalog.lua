local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local SRC_ROOT=TOOL_DIR..'/..'
package.path=SRC_ROOT..'/miuread.koplugin/?.lua;'..package.path
local C=require('miuread.extension_catalog')
local packages=0
local function valid_artifact(a,label)
    assert(type(a)=='table',label..': artifact missing')
    assert(tostring(a.url or ''):match('^https://'),label..': URL invalid')
    assert((tonumber(a.size) or 0)>0,label..': size invalid')
    local sha=tostring(a.sha256 or ''):lower():gsub('[^0-9a-f]','')
    assert(#sha==64,label..': SHA invalid')
end
for _,e in ipairs(C.ENTRIES) do
    if e.package then
        packages=packages+1
        local p=e.package
        local install=p.install or {}
        assert(tostring(install.dirname or ''):match('^[%w%._%-]+%.koplugin$'),tostring(e.id)..': dirname invalid')
        if p.artifact then valid_artifact(p.artifact,tostring(e.id)) end
        if p.variants then
            local n=0
            for arch,v in pairs(p.variants) do
                n=n+1
                valid_artifact(v.artifact or v,tostring(e.id)..'/'..tostring(arch))
                local src,err=C.package_source(e,arch)
                assert(src, tostring(e.id)..'/'..tostring(arch)..': '..tostring(err))
            end
            assert(n>0,tostring(e.id)..': variants empty')
        else
            local src,err=C.package_source(e,nil)
            assert(src,tostring(e.id)..': '..tostring(err))
        end
    end
end
assert(packages>=12,'too few deterministic catalog packages: '..tostring(packages))
local critical={
    fanqie={'v2.2.1',126623,'21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b','fanqie.koplugin'},
    zlibrary={'v1.0.49-e3c07c1014e2a50b0cfae757c476c16cb38efec1',445092,'455423604c7c5eab20fa00f9ac31c89514202892b34347c45fc34435e1252553','zlibrary.koplugin'},
    inkstain={'v3.5.7',9983676,'87da12b78dd941f424c617fc10fdb620ca239b60fc9b61b39089f4c4717e0bee','inkstain.koplugin'},
    pinyinime={'v1.2.0',63312207,'14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb','pinyinime.koplugin'},
}
for id,x in pairs(critical) do
    local e=C.by_id(id); assert(e,id..': missing')
    local src,err=C.package_source(e,nil); assert(src,id..': '..tostring(err))
    assert(src.version==x[1],id..': version mismatch')
    assert(src.size==x[2],id..': size mismatch')
    assert(src.sha256==x[3],id..': SHA mismatch')
    assert(src.expected_dir==x[4],id..': dirname mismatch')
end
for _,id in ipairs({'anki','zotero','highlightsync'}) do
    local e=C.by_id(id); assert(e,id..': missing')
    assert(e.package==nil,id..': must not guess an unverified package')
end
print('extension_catalog deterministic packages: PASS ('..tostring(packages)..' catalog packages)')


-- beta.15 dynamic GitHub Release asset discovery: official ZIPs only, digest
-- propagated when GitHub provides it, and ties are surfaced instead of guessed.
local dynamic={repo='owner/demo.koplugin',install_dirname='demo.koplugin'}
local rel={tag_name='v2.0.0',assets={
    {name='Source code.zip',browser_download_url='https://github.com/owner/demo.koplugin/archive/v2.zip',size=111,content_type='application/zip'},
    {name='demo.koplugin-v2.0.0.zip',browser_download_url='https://github.com/owner/demo.koplugin/releases/download/v2/demo.koplugin-v2.0.0.zip',size=222,digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',content_type='application/zip'},
}}
local ds,derr,dc=C.release_package_source(dynamic,rel,nil)
assert(ds and not derr,'dynamic release source should resolve')
assert(ds.asset_name=='demo.koplugin-v2.0.0.zip','dynamic release selected wrong asset')
assert(ds.size==222 and ds.sha256==string.rep('a',64),'dynamic release metadata not propagated')
assert(ds.allow_missing_sha==false,'digest-backed release must require SHA')
assert(type(dc)=='table' and #dc==1,'source/checksum assets should be filtered')

-- Do not treat the ordinary word 'resources' as a source-code archive just
-- because it contains the substring 'source'. This guards generic asset names.
local resource_rel={tag_name='v2.1',assets={{name='demo-resources.koplugin.zip',browser_download_url='https://github.com/owner/demo.koplugin/releases/download/v2.1/demo-resources.koplugin.zip',size=444,content_type='application/zip'}}}
local resource_src=assert(C.release_package_source(dynamic,resource_rel,nil))
assert(resource_src.asset_name=='demo-resources.koplugin.zip','resources-named plugin asset was incorrectly filtered as source code')

local oldrel={tag_name='v1',assets={{name='demo.koplugin.zip',browser_download_url='https://github.com/owner/demo.koplugin/releases/download/v1/demo.koplugin.zip',size=333,content_type='application/zip'}}}
local oldsrc=assert(C.release_package_source(dynamic,oldrel,nil))
assert(oldsrc.allow_missing_sha==true and oldsrc.sha256=='','old GitHub release without digest should use archive validation fallback')

local tie={tag_name='v3',assets={
    {name='demo.koplugin-a.zip',browser_download_url='https://github.com/owner/demo.koplugin/releases/download/v3/demo.koplugin-a.zip',size=100,content_type='application/zip'},
    {name='demo.koplugin-b.zip',browser_download_url='https://github.com/owner/demo.koplugin/releases/download/v3/demo.koplugin-b.zip',size=101,content_type='application/zip'},
}}
local ts,te,tc=C.release_package_source(dynamic,tie,nil)
assert(ts==nil and te=='最新 Release 有多个同等候选安装包，需要选择','ambiguous release must not be guessed')
assert(type(tc)=='table' and #tc==2,'ambiguous release candidates should be returned to UI')

-- Generic source fallback is evidence-driven, not a per-plugin allow-list.
local probe={installable=true,branch='master',path=''}
local ss,se=C.source_package_source(dynamic,{default_branch='master',source_probe=probe},probe)
assert(ss and not se,'verified source fallback should resolve')
assert(ss.source=='github-source-verified' and ss.url:find('/archive/refs/heads/master.zip',1,true),'verified source fallback URL incorrect')
local blocked,berr=C.source_package_source(dynamic,{default_branch='master'},{installable=false})
assert(blocked==nil and tostring(berr):find('尚未确认',1,true),'unverified source must remain blocked')

print('extension_catalog beta15 release/source policy: PASS')
