# 5.8.0-beta.21 verification

## 完成标准

- PR #72 在线评论点赞完整保留：`review_single` 查询官方状态，`like_review` 执行点赞/取消点赞；默认关闭，仅在“划线与评论”中由用户主动开启。
- `store.lua` 只能存在一份有效 `preferences` 默认表，必须保留 beta.20 的 `shelf_group_hint`、主页/锁屏布局版本，并在该表的 `thoughts` 中包含 `online_likes=false`。
- 已确认的点赞内存状态同时保存 `is_liked` 与最新 `likesCount`；关闭后重开弹窗要同时恢复爱心和数量，缓存签名必须包含两者。
- 服务器 `succ=false` 不得当作成功；服务器返回 `likesCount` 时必须优先使用，接口未返回时才允许临时按 +/-1 显示。
- 点赞不进入批注 pending queue/离线队列，不新增本地点赞数据库；写请求保持 `retries=0`、`rate_limit_retries=0` 的无盲重试策略。
- 同一评论请求中禁止重复点击；旧 pooled popup 会话返回值不得更新重新打开的弹窗；账号/登录会话变化不得串用点赞状态。
- 确认 `-2011/-2012` 登录失效后按 `auth_revision` 熔断，重新登录导致 revision 变化后可自然恢复。
- 在线点赞关闭时，评论弹窗打开/关闭必须保持 beta.20 的 `partial` waveform；开启后才使用 `ui` waveform，点赞成功继续优先局部刷新赞区域。
- Schema 保持 135，不为默认关闭的可选布尔项增加迁移。
- beta.20 的 Issue #105 分组恢复、100 本无分组提醒，以及 beta.19 的阅读时长、精确进度、SAFE pending、sources 清理、主页按需加载、后台下载、休眠与退出收尾全部保持。

## 自动验证

- `python3 tools/verify_beta21.py`
- `texlua tools/test_online_comment_likes.lua`
- `texlua tools/test_shelf_group_recovery.lua`
- `texlua tools/test_readtime_recovery.lua`
- `texlua tools/test_store_repair.lua`
- `texlua tools/test_store_shared.lua`
- `texlua tools/test_extension_catalog.lua`
- `texlua tools/test_extension_download.lua`
- `texlua tools/test_extension_install.lua`
- `texlua tools/test_digest_stream.lua`

Release ZIP 必须只有一个 `miuread.koplugin/` 根目录，插件版本必须为 `5.8.0-beta.21`，Schema 必须为 135。
