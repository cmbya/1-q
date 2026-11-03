# 付费物流查询本地成功缓存

Tmini / UAPI 在各自共享客户端入口使用 `PaidTrackingCache`，因此 App、单票快捷指令和批量刷新采用同一规则。仅成功解析且身份匹配的完整 `UAPITrackingResult` 写入，`queryInfo` 保留完整历史。运输中／待揽收／未知／异常 2 小时，派送中 30 分钟，待取件 6 小时，已签收 7 天，从原 `queriedAt` 计算，边界时刻即过期；未来时间/时钟回拨不命中。命中不修改原查询时间、不联网、不更新 UAPI 服务账单快照、不增加 Tmini 派发数或 4 积分估算。UAPI 的 `refresh: true` 只是上游参数，不绕过本地缓存。无付费 fallback、无重试。

## 身份与持久化

- 分别隔离渠道、完整合法运单号、UAPI 请求承运商、配置 generation 和随机尾号身份令牌。
- 启用/停用、保存/删除密钥旋转 generation；先校验配置再读缓存；网络后和缓存写入前后复验配置。晚到数据只可能保留在旧 generation，不能作为新配置结果使用。
- 尾号不写入缓存 JSON，也不保存尾号的低熵 hash。使用现有 `AIKeychainStore` 设备内、不备份、不同步的服务保存当前尾号上下文和随机 UUID；上下文变更旋转 UUID，即使 A→B→A 也不恢复旧身份。缓存文件仅包含随机 UUID。Keychain 服务名仅散列运单号，不含尾号/密钥及其 hash；同票不同承运商共享尾号版本，使尾号变更能使所有承运商缓存身份失效。
- 网络返回可能回显的 UAPI 密钥/尾号及 Tmini 密钥会在结果文本中隐藏。
- 独立 App Group `PaidTrackingCache/success-v1.json`，不属于业务导入/导出数据；目录排除系统备份。文件原子写入并设置设备文件保护；跨进程短时 flock 仅覆盖缓存与尾号身份操作，不跨网络，不持业务 dataset 锁。原每票 lease 保留。
- 最多 256 条、8 MB；写入清理过期记录并淘汰最旧记录。请求起始时间与结果查询时间都不得倒退覆盖已存新结果。
- JSON 损坏、超限、锁/Keychain/读写错误显式报固定安全错误，不将其当 cache miss 后静默付费。可在明确确认后人工移除独立缓存文件恢复；移除后下一次可能收费。不存在自动清空恢复。详情页新增各渠道“忽略缓存，立即查询（可能扣积分）”，二次确认后仅本次跳过有效期缓存；正常刷新、快捷指令和批量仍优先缓存。到期不会自动查询。忽略缓存不跳过身份/配置/lease校验，不自动切换渠道；成功替换缓存，失败保留原缓存并明确报错，不以旧缓存假报本次成功。损坏文件仍可能使成功后的缓存保存失败，不自动覆盖损坏数据。

## 展示与计数

服务 Bool 返回值仍表示“新增签收”，可选 `cacheFeedback` 提供本次命中反馈。详情页和两种单票快捷指令提示本地缓存、未联网/未新增收费并显示原成功时间；批量报告单列缓存命中，并从原渠道派发计数扣除命中。业务合并仍执行原身份、时间和状态防回退校验，缓存命中不保证一定能覆盖当前业务数据。

## 离线验证

`ParcelKeeperTests/PaidTrackingCacheTests.swift` 的 7 个 XCTest 覆盖双渠道完整结果、TTL 边界、未来时间、隔离身份、尾号轮换、不泄露尾号、旧响应、损坏、Tmini 4 积分、UAPI 账单不变及失败不缓存。旧客户端测试改用隔离缓存及伪 Keychain；解析器多次响应测试显式旋转测试配置以避免命中遮挡预期网络响应。

本地可执行：

```sh
python3 -m unittest discover -s scripts -p 'test_*contract.py'
python3 scripts/test_recognition_review_rules.py
git diff --check
```

Python 仅是源代码契约检查，不是 Swift 编译或 XCTest。Linux 无 Xcode/Swift；Swift 编译、XCTest、设备跨进程锁、系统备份排除和 AppIntents/UI 实机表现仍需在获准的 macOS/iOS 环境验证。本任务不构建、不提交推送、不发送真实收费请求。
