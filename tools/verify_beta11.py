#!/usr/bin/env python3
from pathlib import Path
import hashlib, re, sys, zipfile, subprocess

ROOT=Path(__file__).resolve().parents[1]
PLUGIN=ROOT/'miuread.koplugin'
MIU=PLUGIN/'miuread'
errors=[]; checks=[]
def ok(cond,msg):
    checks.append(msg)
    if not cond: errors.append(msg)
def text(p): return p.read_text(encoding='utf-8')

def sha256(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

cfg=text(MIU/'config.lua'); main=text(PLUGIN/'main.lua'); store=text(MIU/'store.lua')
dl=text(MIU/'extension_download.lua'); ins=text(MIU/'extension_install.lua'); job=text(MIU/'extension_job.lua'); center=text(MIU/'extension_center.lua'); catalog=text(MIU/'extension_catalog.lua')

ok('VERSION = "5.8.0-beta.11"' in cfg,'version is 5.8.0-beta.11')
ok('SCHEMA = 130' in cfg,'schema is 130')
for old in ['extension_transfer.lua','extension_verifier.lua','extension_package.lua','extension_installer.lua','extension_task.lua']:
    ok(not (MIU/old).exists(),f'legacy module removed: {old}')
for new in ['extension_download.lua','extension_install.lua','extension_job.lua']:
    ok((MIU/new).is_file(),f'new module present: {new}')
ok('require("miuread.extension_job")' in main,'main uses extension_job')
for token in ['miuread.extension_transfer','miuread.extension_verifier','miuread.extension_package','miuread.extension_installer','miuread.extension_task']:
    ok(token not in '\n'.join(text(p) for p in PLUGIN.rglob('*.lua')),f'no runtime require/reference to {token}')

# Download policy invariants.
ok('local LARGE_RESUME_BYTES=16*1024*1024' in dl,'large-file resume threshold is 16 MiB')
ok('local out={direct}' in dl and 'for _,route in ipairs(configured) do out[#out+1]=route end' in dl,'automatic source order starts direct then all configured mirrors')
ok('if custom_route then out[#out+1]=custom_route end' in dl,'custom source is last automatic fallback')
ok('while #routes>3' not in dl and 'route_score' not in dl and 'ttfb' not in dl.lower(),'no route scoring or 3-source truncation')
ok('return {}' in dl and 'mode:match("^mirror:%d+$")' in dl,'manual invalid source fails closed')
ok('source-"..U.id_name(route.key)..".part' in dl,'partials are source-local')
ok('copy' not in re.sub(r'copy_file_stream','',dl[dl.find('local function source_part'):dl.find('function M.run')]),'source identity helper does not copy partials across routes')
ok('validate_download(part,spec)' in dl and 'verify_kind=="sha_unavailable"' in dl,'source completion is integrity-gated')
ok('expected>0 and size~=expected' in dl and 'actual~=expected_sha' in dl,'size and SHA-256 are both enforced')
ok('local curl_available=command_available("curl")' in dl and 'transport=koreader_http' in dl and 'transport=curl' in dl,'KOReader HTTP primary with curl fallback retained')
ok('cached package verified' in dl and 'cached package rejected' in dl,'cached package is always revalidated')
ok('fresh_verify_kind=="sha_unavailable" or fresh_verify_kind=="catalog_integrity"' in dl,'fresh curl restart preserves terminal integrity errors')

# Installer invariants.
ok('pcall(require,"ffi/archiver")' in ins,'KOReader Archiver is archive authority')
ok('unzip ' not in ins and 'unzip\t' not in ins,'system unzip is not used by installer')
ok('install-journal.json' in ins,'transaction journal is written')
ok('.miuread-new-' in ins and '.miuread-old-' in ins,'transaction uses new/old staging directories')
ok('rename_dir(target,old_path)' in ins and 'rename_dir(new_path,target)' in ins,'install switches by staged rename')
ok('os.rename(old_path,target)' in ins,'rollback can restore old plugin')
ok('Compat.validate_candidate' in ins,'compatibility/ELF validation retained')
ok('main.lua' in ins and '_meta.lua' in ins,'plugin structure validation retained')
ok('MAX_ARCHIVE_ENTRIES' in ins and 'MAX_PLUGIN_FILES' in ins and 'max_plugin_bytes' in ins,'archive/file/expanded-size safety limits retained')
ok('symlinkattributes' in ins,'link-aware extraction safety retained')

# Job / lifecycle invariants.
ok('recover_install_journal' in job and 'install journal recovered' in job,'crash recovery for interrupted install exists')
ok('paused_user' in job and 'waiting_network' in job and 'cancelled' in job,'simple explicit task lifecycle retained')
ok('resume_generation=self.resume_generation+1' in job and 'function ExtensionJob:delete_data' in job,'delete invalidates auto-resume generation')
ok('pcall(done_cb' in job,'UI completion callbacks are contained with pcall')
ok('has_local_package' in job and 'not has_local_package and not network_connected()' in job,'verified local package can continue installation offline')
ok('source%-.+%.part$' in job,'job progress scans v4 source-local partials')

# Migration / cleanup.
ok('if schema<130' in store and 'extension_package_manager_version",4' in store,'schema 130 migrates to extension engine v4')
ok('route_health=removed' in store and 'cross_source_partials=removed' in store,'migration explicitly drops v3 route health/cross-source model')
ok('U.remove_tree(old_tasks)' in store,'legacy transient extension tasks are discarded')

# Center is deterministic only.
ok('不会猜测 Release、源码包或插件目录' in center,'unknown community repositories cannot be guessed into installable packages')
ok('ExtensionInstall.install' in center,'center delegates to sole transactional installer')
ok('ffi/archiver' not in center and 'unzip -t' not in center,'center contains no second archive verifier/installer')
ok('route_score' not in center,'center has no route-scoring policy')

# Critical official metadata pinned in catalog.
crit={
 'fanqie':('v2.2.1',126623,'21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b','fanqie.koplugin'),
 'zlibrary':('v1.0.49-e3c07c1014e2a50b0cfae757c476c16cb38efec1',445092,'455423604c7c5eab20fa00f9ac31c89514202892b34347c45fc34435e1252553','zlibrary.koplugin'),
 'inkstain':('v3.5.7',9983676,'87da12b78dd941f424c617fc10fdb620ca239b60fc9b61b39089f4c4717e0bee','inkstain.koplugin'),
 'pinyinime':('v1.2.0',63312207,'14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb','pinyinime.koplugin'),
}
for id,(ver,size,sha,dirname) in crit.items():
    ok(id in catalog and ver in catalog and str(size) in catalog and sha in catalog and dirname in catalog,f'critical catalog package pinned: {id}')
for id in ['anki','zotero','highlightsync']:
    # Restrict check to a bounded entry region ending at next entry.
    m=re.search(r'id\s*=\s*"'+re.escape(id)+r'"(.*?)(?=\n\s*\{\n\s*id\s*=|\n\}\n\nlocal)',catalog,re.S)
    ok(bool(m) and 'package =' not in m.group(1),f'unverified project is not guessed as installable: {id}')

# Uploaded AppStore package is an exact official deterministic-catalog package.
app=Path('/mnt/data/appstore.koplugin.zip')
if app.exists():
    ok(app.stat().st_size==273795,'uploaded AppStore size matches catalog')
    ok(sha256(app)=='dde0fcb3d8254a3c573ab8c46e7e5f35b688fb4f4177909211aeae7ed7d76449','uploaded AppStore SHA matches catalog')
    with zipfile.ZipFile(app) as z:
        bad=z.testzip(); names=z.namelist()
    ok(bad is None,'uploaded AppStore ZIP CRC validates')
    ok(any(n=='appstore.koplugin/main.lua' for n in names) and any(n=='appstore.koplugin/_meta.lua' for n in names),'uploaded AppStore contains deterministic plugin root')

# Syntax-check every shipped Lua source.
texluac=Path('/usr/bin/texluac')
if texluac.exists():
    lua_files=sorted(PLUGIN.rglob('*.lua'))
    failed=[]
    for p in lua_files:
        r=subprocess.run([str(texluac),'-p',str(p)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={**__import__('os').environ,'TERM':'xterm'})
        if r.returncode: failed.append((p,r.stderr.decode('utf-8','replace')))
    ok(not failed,f'all shipped Lua files parse ({len(lua_files)} files)')
    if failed:
        for p,e in failed: errors.append(f'Lua parse failed {p}: {e[:200]}')

print(f'checks={len(checks)} failures={len(errors)}')
if errors:
    for e in errors: print('FAIL:',e)
    sys.exit(1)
for c in checks: print('PASS:',c)
