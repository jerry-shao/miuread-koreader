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
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.util']=function()
    return {copy=copy,utf8_len=function(s) return #tostring(s or '') end}
end
package.preload['miuread.protocol']=function()
    return {
        escape=function(v) return tostring(v or ''):gsub(' ','%%20') end,
        reader_url=function(book,chapter) return 'https://weread.qq.com/web/reader/'..tostring(book)..'/'..tostring(chapter) end,
    }
end
package.preload['miuread.codec']=function() return {b64encode=function(v) return tostring(v or '') end} end
local auth_error_code=function(value)
    local s=tostring(value or '')
    return tonumber(s:match('(-?%d%d%d%d)'))
end
package.preload['miuread.http']=function() return {auth_error_code=auth_error_code} end

local Api=require('miuread.api')

-- Read official like state. This path must be a non-retrying GET and carry the
-- book/chapter context used by the Web reader.
do
    local seen={}
    local http={}
    function http:get_json(url,opt)
        seen.url,seen.opt=url,copy(opt)
        return {data={review={isLike=true},likesCount=9},errCode=0}
    end
    local api=Api:new(http,{},nil)
    local row=api:review_single('review 1',{bookId='book-1',chapterUid='chapter-2'})
    assert(seen.url=='https://weread.qq.com/web/review/single?reviewId=review%201','review_single URL/escaping changed')
    assert(seen.opt.retries==0 and seen.opt.rate_limit_retries==0,'review_single may retry unexpectedly')
    assert(seen.opt.pacing_scope=='annotation-read','review_single pacing scope changed')
    assert(seen.opt.headers.Referer=='https://weread.qq.com/web/reader/book-1/chapter-2','review_single lost reader context')
    assert(type(row.review)=='table' and row.review.isLike==true and row.likesCount==9,'review_single did not unwrap official state')
end

-- Like and unlike must use the existing guarded annotation-write path, with no
-- transport retries and the exact isUnlike flag sent to WeRead.
do
    local calls={}
    local http={}
    function http:post_json(url,payload,opt)
        calls[#calls+1]={url=url,payload=copy(payload),opt=copy(opt)}
        return {data={succ=true,likesCount=(payload.isUnlike and 8 or 10)},errCode=0}
    end
    local api=Api:new(http,{},nil)
    local liked=api:like_review('r1',false,{bookId='b',chapterUid='c'})
    local unliked=api:like_review('r1',true,{bookId='b',chapterUid='c'})
    assert(#calls==2,'like_review request count changed')
    assert(calls[1].url=='https://weread.qq.com/web/review/like','like endpoint changed')
    assert(calls[1].payload.reviewId=='r1' and calls[1].payload.isUnlike==false,'like payload changed')
    assert(calls[2].payload.isUnlike==true,'unlike payload changed')
    assert(calls[1].opt.retries==0 and calls[1].opt.rate_limit_retries==0,'like write gained blind retries')
    assert(calls[1].opt.pacing_scope=='annotation-write','like write pacing scope changed')
    assert(liked.succ==true and liked.likesCount==10 and unliked.likesCount==8,'server like response was not preserved')
end

-- A confirmed Web-session expiry may renew once and then retry once; it must not
-- become an open-ended retry loop.
do
    local attempts,recoveries=0,0
    local http={}
    function http:get_json()
        attempts=attempts+1
        if attempts==1 then error('request failed -2012') end
        return {data={review={isLike=false},likesCount=3},errCode=0}
    end
    local reader={_recover_login_session=function() recoveries=recoveries+1; return true end}
    local api=Api:new(http,{},reader)
    local row=api:review_single('r2',{})
    assert(attempts==2 and recoveries==1,'review state auth renewal is not bounded to one retry')
    assert(row.review.isLike==false and row.likesCount==3,'renewed review state read failed')
end

-- Missing IDs fail closed before any network request.
do
    local api=Api:new({},{},nil)
    local ok1=pcall(function() api:review_single('',{}) end)
    local ok2=pcall(function() api:like_review('',false,{}) end)
    assert(ok1==false and ok2==false,'empty review id did not fail closed')
end

print('beta21 online comment likes API: PASS')
