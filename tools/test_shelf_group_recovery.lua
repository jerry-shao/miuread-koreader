local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

local function copy(v,seen)
    if type(v)~='table' then return v end
    seen=seen or {}; if seen[v] then return seen[v] end
    local out={}; seen[v]=out
    for k,x in pairs(v) do out[copy(k,seen)]=copy(x,seen) end
    return out
end
local function trim(s) return tostring(s or ''):match('^%s*(.-)%s*$') end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.protocol']=function() return {is_mp_account=function() return false end,is_mp=function() return false end} end
package.preload['miuread.codec']=function() return {} end
package.preload['miuread.download_result']=function() return {} end
package.preload['miuread.util']=function()
    return {
        copy=copy,trim=trim,
        clamp=function(v,a,b) v=tonumber(v) or a; if v<a then return a elseif v>b then return b end; return v end,
    }
end

local Library=require('miuread.library')
local function store_with(filter,cache)
    local prefs={shelf_filter=copy(filter or {enabled=false,archives={},archive_keys={}})}
    local shelf_cache=copy(cache or {raw_books={},raw_mp={},books={},mp={},groups={authoritative=false,list={},book_groups={}}})
    local store={}
    function store:preferences() return copy(prefs) end
    function store:save_preferences(v) prefs=copy(v); return true end
    function store:shelf_cache() return copy(shelf_cache) end
    function store:save_shelf_cache(v) shelf_cache=copy(v); return true end
    function store:get(_,default) return copy(default) end
    function store:set_deferred() return true end
    function store:_prefs() return prefs end
    function store:_cache() return shelf_cache end
    return store
end
local function books(n)
    local out={}
    for i=1,n do out[#out+1]={bookId=tostring(i),title='B'..i,readUpdateTime=1000-i} end
    return out
end

-- Issue #105: 5.7 could leave enabled=true with no selected group. This must
-- mean full shelf, never zero books.
do
    local store=store_with({enabled=true,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{books=books(32),archive={}})
    assert(#shown==32,'empty selected-group state did not restore full shelf')
    assert(store:_prefs().shelf_filter.enabled==false,'empty selected-group state was not normalized')
    assert(#store:_cache().raw_books==32 and #store:_cache().books==32,'raw 32 books were not retained/restored')
    local recovery=lib:take_shelf_filter_recovery()
    assert(recovery and recovery.kind=='empty_selection_recovered','empty-selection recovery reason missing')
end

-- A stale selected group that disappeared from an authoritative snapshot must
-- fall back to all books instead of fail-closed zero.
do
    local store=store_with({enabled=true,archives={Old=true},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{
        books=books(32),
        archive={{name='New',bookIds={'1','2'}}},
    })
    assert(#shown==32,'stale deleted group did not restore full shelf')
    assert(store:_prefs().shelf_filter.enabled==false,'stale group filter remained enabled')
    local recovery=lib:take_shelf_filter_recovery()
    assert(recovery and recovery.kind=='stale_selection_recovered','stale-selection recovery reason missing')
end

-- A real, existing empty group is an intentional filter and may legally show 0.
do
    local store=store_with({enabled=true,archives={Empty=true},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{
        books=books(32),
        archive={{name='Empty',bookIds={}}},
    })
    assert(#shown==0,'valid empty group was incorrectly expanded to full shelf')
    assert(store:_prefs().shelf_filter.enabled==true,'valid empty group filter was disabled')
end

-- A valid selected group still filters normally and deduplicates through the
-- normalized book list.
do
    local store=store_with({enabled=true,archives={Keep=true},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{
        books=books(10),
        archive={{name='Keep',bookIds={'2','4','6'}}},
    })
    assert(#shown==3,'valid selected group did not filter to three books')
end

-- No groups + >=100 raw books produces a recommendation candidate only after
-- a fresh authoritative group response. It never changes the displayed shelf.
do
    local store=store_with({enabled=false,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{books=books(100),archive={}})
    assert(#shown==100,'100-book ungrouped shelf was truncated or filtered')
    local hint=lib:large_shelf_group_hint(100)
    assert(hint and hint.books==100 and hint.groups==0 and hint.authoritative==true,'100-book no-group hint missing')
end

-- 99 books must not trigger the recommendation.
do
    local store=store_with({enabled=false,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{books=books(99),archive={}})
    assert(#shown==99,'99-book shelf changed')
    assert(lib:large_shelf_group_hint(100)==nil,'99 books incorrectly triggered large-shelf hint')
end

-- Existing groups suppress the recommendation even when full-shelf mode is
-- active and the account has many books.
do
    local store=store_with({enabled=false,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{
        books=books(120),archive={{name='Group',bookIds={'1','2'}}},
    })
    assert(#shown==120,'full shelf with groups was unexpectedly filtered')
    assert(lib:large_shelf_group_hint(100)==nil,'existing group did not suppress recommendation')
end

-- A non-authoritative response can never prove that the account has zero
-- groups, so it must never trigger the recommendation.
do
    local store=store_with({enabled=false,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{books=books(120)})
    assert(#shown==120,'incomplete group response changed full shelf')
    assert(lib:large_shelf_group_hint(100)==nil,'incomplete group response triggered recommendation')
end

-- A genuinely empty authoritative WeRead shelf remains empty.
do
    local store=store_with({enabled=false,archives={},archive_keys={}})
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:_apply_stream_response{books={},archive={}})
    assert(#shown==0,'true empty shelf was incorrectly restored from nowhere')
end

-- Even before migration runs, cached raw books are fail-open when the old
-- selected-group flag has no actual selection. This gives offline recovery.
do
    local raw=books(32)
    local store=store_with({enabled=true,archives={},archive_keys={}}, {
        raw_books=raw,raw_mp={},books={},mp={},groups={authoritative=true,list={},book_groups={}},updated_at=1,
        effective_scope={mode='selected',fingerprint='selected||',updated_at=1},
    })
    local lib=Library:new({}, {}, store)
    local shown=select(1,lib:cached())
    assert(#shown==32,'offline cache did not recover raw books from old empty selection')
end

print('beta20 shelf group recovery: PASS')
