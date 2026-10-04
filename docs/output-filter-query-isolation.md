# 输出筛选与额度查询隔离

## PiMac

- 工具输出搜索新增「仅匹配行」，同一行的多个匹配只输出一次，保留原始 Unicode 文本。
- 搜索菜单支持独立复制和导出匹配行；顶部复制／导出仍保存完整原始输出。
- 筛选只覆盖当前开头／尾部预览，受 128 KiB、2000 行、1000 个匹配上限约束，不承诺全文搜索。
- 筛选时暂停尾部跟随；关闭搜索恢复正常输出。筛选期间匹配导航禁用，避免将原始坐标应用于筛选后的文本。
- 清除原生搜索选区只折叠搜索拥有的选区，不覆盖用户随后建立的手动选区。

## account-usage extension

- 共享缓存网络查询默认最多 120 秒（不含锁等待），通过独立模块 `withDeadline` 统一管理。
- 查询函数接收组合取消信号；Codex 与 Gemini 查询向底层传递该信号。
- 不遵守取消的 adapter 也不能无限占用 namespace lease；超时／取消后释放锁，不写入迟到结果。
- `readBoundedJson` 对每次 reader read 同时等待取消信号。自定义 reader 即使忽略 cancel，也不会让调用者永久等待；迟到异常被观察，清理不会掩盖原始异常。
- 查询超时参数在文件操作和网络请求前校验。缓存命中、强制刷新合并和旧缓存格式保持不变。

## 回归验证

- Swift 测试覆盖 Unicode／CRLF 匹配行去重及原生选区所有权。
- extension 测试覆盖卡住的 reader、迟到失败、查询超时、锁释放、迟到结果隔离、参数校验和取消信号传递。
- 运行 `swift test`、Swift 格式检查、extension typecheck／lint／format／test、fast extension、PiCompatibility 与 DevWatcher 测试。

未改变服务端协议；未进行真实账户网络验证或 GUI 人工验收。
