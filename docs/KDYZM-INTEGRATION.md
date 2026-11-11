# 取件助手后台（kdyzm）iOS 客户端

## 使用

1. 后台管理员先配置可由手机访问、具有系统受信任证书的 HTTPS origin（例如 `https://pickup.example.com:8443`），添加后台实际支持的购物平台账号并完成采集。iOS 不索取管理员密码或购物平台 Cookie。平台选项不代表对应采集器已经可用，以后台实际采集状态为准。
2. 管理员生成一次性绑定码，可授权持续家人组或旧明确账号范围。
3. App「设置 → 物流查询 → 取件助手后台」，输入地址和绑定码，点「预检授权范围」，核对服务地址、家人、账号及是否包含未来账号，再点「确认授权并绑定」。不能覆盖已绑定设备，须先解绑。绑定码只保留于当前页面内存，离开页面清空。
4. 点击「读取授权账号」查看全部平台授权；点击同步后台快照导入全部授权平台实际返回的运单，包括淘宝、拼多多、京东、抖音，以及符合 v1 合约的未来平台；不按平台白名单排除。淘宝和拼多多直连入口已从默认构建停用，源码保留；后台同步仍可用。同步仅 GET `/v1/snapshot`，不会请求全账号采集。
5. 运单详情「刷新物流（按默认渠道）」及现有 AppIntents 对有后台绑定的票请求单订单刷新任务。排队/冷却不是成功，提示稍后继续读取同一任务；不自动转付费 UAPI。显式选择 UAPI／Tmini 的原功能保留；仅平台刷新优先后台绑定，报告独立列出后台派发数。后台不支持或采集失败不自动回退付费渠道。未绑定且来源不受支持的旧运单仍明确失败，不自动转付费。
6. 「撤销设备并解绑」先 DELETE 当前设备，再 GET 快照验证 401 后清除本机钥匙串。撤权/验证失败保留凭据便于重试；「仅本机解绑」是独立二次确认选项，**不会撤销后台设备**，需管理员随后处理。

## 安全与数据约定

- 独立实现参照 `zsdd2/kdyzm` 固定提交 `b13c0527cb38f3aad79cacf8ca85efacaa0004ed` 的 PROTOCOL.md、store/service/sync-jobs 接口 schema；未复制后台实现，无新依赖。
- HTTPS origin 不允许路径（根 `/` 可规范化）、用户名密码、query、fragment。可用内网地址，不自动信任自签证书。ephemeral session 无 Cookie、缓存、URL credential store；拒绝所有 redirect，每次请求及资源超时均裁剪至剩余预算（最多 12 秒），流式限制 2,000,000 字节。token 仅发送到 credential 中固定 origin。
- baseURL/token/deviceID/generation 为一个原子 Keychain JSON item，ThisDeviceOnly、不同步 iCloud，写入和删除均回读；不写偏好、普通文件、JSON 备份或日志。错误仅本地白名单文案，不回显服务端 message、原响应或底层 URL 错误。
- schemaVersion 仅接受 1。新 `familyIds` 字段即使为空也严格按该集合或 `legacyAccountIds` 授权，不把动态 accounts 列表当额外权限。历史订单转组后当前账号数组为空仍可导入。重复 ID、scope 越界、订单与运单 account/family 冲突均整批拒绝。
- stable binding 是 origin/accountID/orderID/shipmentID；平台来源和平台订单号来自订单本身，不从当前账号推导历史归属。已绑定票若平台/平台订单身份变化则拒绝晚到结果。仅唯一规范化单号且同承运商时补关联已有本地票；非手工来源还必须匹配平台及订单，已有淘宝直连关联不自动改为后台。两个账号或平台同号不合并，所有平台共同参与歧义检测。没有运单的订单跳过并计数，不伪造单号。hidden/deleted/缺席不删除本地票。
- 已有 UUID、备注、非空个人取件码、分组、位置、提醒保留；已有空取件码仅从非空远端值补齐，同时更新关联 PickupRecord，校验同组未完成记录重复码；缺失/空值不清除。新票可带后台标题、取件码、站点。领取状态优先读取后台 v1 `pickupCompletion`：`manualOverride=pending` 优先于自动领取，`picked` 或 `autoPicked=true` 表示已领取；旧快照兼容 `picked=true`，再按本次最新有效轨迹识别明确领取语句。有效 v1 状态为未领取时，不用本地文字推断覆盖后台决定。普通 signed 不代表本人已领取。确认领取时同步完成关联取码记录，已导入的错误未完成记录也会修复；历史记录保留。快照同步不会冒充单票查询而修改 lastQueriedAt。
- 本机手动完成或恢复未完成保存在可选 `PickupRecord.completionOverride`，恢复后后台自动完成不覆盖该记录；后台同步不会撤销本机已完成。旧数据/备份缺失该字段仍可读取，但旧版未记录手动恢复的来源，无法区分其与旧版误导入的未完成状态，升级后必要时可再次手动恢复。操作只影响本机，不上传后台。
- 毫秒时间显式换算。仅 logisticsState=ok、有节点、有成功时间才更新轨迹；领取决策可独立于轨迹缓存更新。保留原节点、原历史，截断有明显提示；empty/error/unavailable 不清轨迹、不记查询成功。单票还校验 job/order/account、当前票及任务关联，实际事务写回后才记成功查询时间。
- 网络不持有 flock/运单 lease。短提交时获取既有 lease、SharedPickupStore.transaction，复核本地身份与 credential generation；解绑期间和旧 credential 晚到结果拒绝。AppIntents 与 App 共用刷新服务；widget 仅共享可选值类型，旧备份兼容。同步/成功刷新重载 widget，既有前台 reload 和提醒对账保留。
- 不上传本地操作，不主动轮询购物平台。单次任务轮询默认 12 秒预算，等待 retryAt 超预算即返回；持久化待处理 job ID，后续按钮继续 GET，任务消失时清关联并让用户下次手动重试。后台 cooldown 在该固定版本表示队列满而非已排队，客户端不自动再次 POST。

## 复核修正

- 归档票整票跳过，不补关联或更新元数据。同步允许唯一手工票补后台关联，但严格保留显式 UAPI override；自动快照不覆盖已有其他来源物流。用户明确选择平台刷新可更新关联票物流，不改 override。
- 本次有效物流结果不与本地缓存比较新旧；同时间文字冲突也使用本次结果，transit 可替换待取件，已签收保护保留。新票即使空轨迹也按 signed/arrived 映射物流状态；取码记录独立采用领取判定，明确已领取可在无缓存时完成，单有 signed 不完成取码记录。
- 取件码最多 80 字、站点 200 字、标题 500 字、承运商 120 字，导入文本不接受控制字符。格式或同组未完成记录重复码失败，SharedPickupStore.transaction 整批回滚，不部分持久化；已领取历史记录不会因复用旧取件码而阻塞导入。
- 预检 scope 校验 ID 唯一、accountIds 与 accounts 一致、family scope 一致，避免重复 ForEach ID；token 严格匹配 `pcd_[A-Za-z0-9_-]+`（长度上限 280，兼容测试 token）。有效期显示改用显式 Date 解包，避免可选推导含混；尚未编译验证。
- 默认后台刷新失败会保留安全白名单 lastRefreshError 并写短枚举诊断；无服务端原文或 token。每个 HTTP（包括最终 snapshot）使用剩余 12 秒预算，资源超时同样裁剪。
- 同步仅持受全部平台远端绑定/单号影响的本地票 lease。身份变化、新同号票仍拒绝；无关淘宝新增不取消。底层 lease 无人为查询数量上限，但依赖文件描述符；不再为整库开描述符。
- 兑换成功但本机保存失败可能遗留后台设备：请管理员在后台撤销后生成新码；客户端不自动重试原一次性码，也不声称本地失败撤销了远端。
- 新增 XCTest 覆盖归档、UAPI override、空轨迹状态、补码/重复、同时间冲突、状态不降级、scope/token 和请求剩余 timeout；新增 Python 源码契约。当前无 swift/xcodebuild，XCTest **未跑**；源码契约不能替代编译或网络时限真机验证。

- 全平台回归新增在 `KDYZMTests.swift` / `KDYZMNetworkTests.swift`：淘宝、拼多多、京东、抖音及未来平台导入/重放/无单号计数，跨平台同号和授权隔离，平台订单身份冲突，全部平台历史与本地字段保留，通用任务刷新、批量后台计数和 401 不回退付费。复用完整的既有 UAPI mock，未新增 AIKeyStore mock。来源展示按实际平台，后台关联但无轨迹不冒称成功来源。`syncKDYZM` 保持原通用方法名。

## 限制与验证

**同步零订单不保证购物账号没有订单。** 后台可能尚未采集、账号过期、授权不含对应历史家人、平台未提供运单或上游失败；请在后台检查采集状态。快照不代替实时平台采集回执。

本轮先编写 XCTest（URL、scope、重复/关联、用户字段、旧模型、Keychain generation、错误白名单、redirect delegate、任务状态、失败/空/旧轨迹等），并先运行辅助 Python source contract 得到缺少实现的 RED，再实现到 GREEN。Python 只验证源码约束，**不是 Swift 编译、XCTest 或真机联调**。

执行：`python3 scripts/test_kdyzm_contract.py`、`python3 scripts/test_removed_platform_contract.py`、`git diff --check`。
当前 Linux 无 Swift/Xcode，未运行 Swift XCTest、构建、签名、CI 或真实后台/购物账号联调。交付后仍需在获授权 macOS 环境用项目既有 ParcelKeeper scheme 编译并执行全部 XCTest；特别核验 Swift 并发诊断、系统 Keychain、AppIntent hosting、真机 TLS/取消和提醒生命周期。不能将源码辅助检查宣传为这些验证已通过。

