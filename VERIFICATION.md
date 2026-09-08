# 5.8.0-beta.19 verification

## 完成标准

- 阅读时间首次约 15 秒、之后约每 60 秒上传，周期与 beta.18 一致。
- 正常 60 秒阅读时间结果不得触发整份 `miuread.lua` 保存，包括 `read_report` 认证健康状态更新。
- 正常阅读期间的 300 秒快照只更新当前运行状态，不固定重写整份设置。
- 只有关闭书籍、休眠、退出、最终上传、关键配置/身份变化等需要可靠落盘的事件继续完整保存。
- 明确未发送且可安全补报的阅读秒数写入独立恢复记录；不确定是否已发送的秒数绝不进入恢复债务。
- 恢复记录必须绑定 book / login session / account / core map；写入失败必须退回完整设置保存，不能以性能换正确性。
- 阅读进度算法、手动上传、返回主页、关书、熄屏精确位置均与 beta.18 一致；不得加入 1% 显示阈值或同页无条件跳过刷新。
- 历史 `sources -> ... -> sources` 持久化链在 schema 134 升级时清理，后续新保存也不能重新生成。
- 四个主页大型模块按需加载；首次实际进入对应页面仍完整可用。
- 每次整份设置保存记录原因、耗时和文件大小。

## 自动验证

- `python3 tools/verify_beta19.py`
- `texlua tools/test_extension_catalog.lua`
- `texlua tools/test_extension_download.lua`
- `texlua tools/test_extension_install.lua`
- `texlua tools/test_store_repair.lua`
- `texlua tools/test_store_shared.lua`
- `texlua tools/test_digest_stream.lua`

Release ZIP 必须只有一个 `miuread.koplugin/` 根目录，插件版本必须为 `5.8.0-beta.19`。
