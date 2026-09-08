# 5.8.0-beta.22 verification

## 完成标准

- PR #73 的 WeRead TCP/TLS 连接复用正式纳入 beta.22，`Config.HTTP_KEEPALIVE=true` 为默认开关，设置为 `false` 时必须完整回退到原有一请求一连接路径。
- 连接复用必须是逐请求显式 opt-in：只有下载链路传入 `keepalive=true`；登录、书架、阅读进度、阅读时长、批注、评论点赞及其他普通 HTTP 调用不得自动进入连接池。
- 仅 WeRead 域名且非流式落盘请求允许进入连接池；流式图片/大文件继续使用原有独立连接。
- 响应只有在 Content-Length、chunked、204 或 304 等可明确界定响应体边界时才允许回池；`Connection: close`、HTTP/1.0 未声明 keep-alive、流错误或异常交换必须关闭连接。
- 空闲连接超过 25 秒必须失效；单连接达到 64 次使用上限后不得继续回池；取用前必须通过 `socket.select` 检测陈旧连接。
- 复用连接提前失效时，仅 GET / HEAD 可在没有收到响应字节的前提下透明重建一次；POST 不得在连接池层自动重放，继续交给原有调用方 retry。
- 下载任务无论正常完成、取消还是异常退出，都必须执行 `close_idle_connections()`；限流冷却和网络恢复探测前同样必须清理连接池。
- 下载汇总日志必须继续提供 `elapsed / network / pacing / ratelimit / throttle / requests / connections / reused / bytes`，便于真机 A/B 与后续故障定位。
- 版本必须为 `5.8.0-beta.22`，Schema 继续保持 135；不因为网络优化增加设置迁移。
- beta.21 在线评论点赞、beta.20 Issue #105 分组恢复与 100 本提醒、beta.19 阅读时长/SAFE pending/精确进度/后台稳定性等回归保护必须全部继续通过。

## 自动验证

- `python3 tools/verify_beta22.py`
- `texlua tools/test_http_keepalive.lua`
- `texlua tools/test_online_comment_likes.lua`
- `texlua tools/test_shelf_group_recovery.lua`
- `texlua tools/test_readtime_recovery.lua`
- `texlua tools/test_store_repair.lua`
- `texlua tools/test_store_shared.lua`
- `texlua tools/test_extension_catalog.lua`
- `texlua tools/test_extension_download.lua`
- `texlua tools/test_extension_install.lua`
- `texlua tools/test_digest_stream.lua`

Release ZIP 必须只有一个 `miuread.koplugin/` 根目录，插件版本必须为 `5.8.0-beta.22`，Schema 必须为 135。
