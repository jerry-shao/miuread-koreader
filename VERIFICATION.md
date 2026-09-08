# 5.8.0-beta.20 verification

## 完成标准

- Issue #105：旧状态 `shelf_filter.enabled=true` 且未选择任何分组时必须显示完整微信书架。
- 权威分组快照确认原选择已经不存在时，自动恢复全部书籍并给出一次恢复提示。
- 一个真实存在、明确选中的空分组仍允许显示 0 本；真正微信书架为 0 本时也必须保持 0 本。
- 分组响应不完整时保留现有有效缓存，不把“不知道有没有分组”误判成“没有分组”。
- Schema 135 能从已有 `raw_books > 0 / books = 0` 缓存离线恢复书架。
- 取消最后一个分组或“清空选择”后立即回到全部微信书架。
- 只有新鲜、权威的分组响应明确 `groups=0` 且 `raw_books>=100` 时才产生建立分组建议。
- 100 本提醒不改变书架内容；99 本不提醒；已有任意微信分组时不提醒。
- 提醒按账号独立；“知道了”结束当前无分组阶段，“不再提醒”永久关闭该账号提醒；提示只在主页空闲且没有其他模态界面时出现。
- 日志记录 raw/groups/selected/mode/effective/reason。
- beta.19 的阅读时长、精确进度、SAFE pending、sources 清理、主页按需加载、后台下载、休眠与退出收尾全部保持。

## 自动验证

- `python3 tools/verify_beta20.py`
- `texlua tools/test_shelf_group_recovery.lua`
- `texlua tools/test_readtime_recovery.lua`
- `texlua tools/test_store_repair.lua`
- `texlua tools/test_store_shared.lua`
- `texlua tools/test_extension_catalog.lua`
- `texlua tools/test_extension_download.lua`
- `texlua tools/test_extension_install.lua`
- `texlua tools/test_digest_stream.lua`

Release ZIP 必须只有一个 `miuread.koplugin/` 根目录，插件版本必须为 `5.8.0-beta.20`，Schema 必须为 135。
