# UAPI / Tmini 查询缓存已停用

UAPI、Tmini 共享查询客户端不再调用 `PaidTrackingCache.identity`、`lookup` 或 `store`。每次通过配置、运单与权限校验的有效查询都会发出一次网络请求，普通重复查询也一样；不以历史成功结果代替本次失败，不自动重试、不自动切换收费渠道。UAPI 的 `refresh` 仍只是上游参数，不影响本地行为。

详情页已移除“忽略缓存”按钮、二次确认分支及 TTL 文案。页面明确提示每次查询联网、可能计费，并通过 `TrackingRefreshService.resolvedChannel` 显示实际默认渠道；不可解析时显示“不可用”。

## 保留的收费与安全保障

- 启用同意、设备内 Keychain 密钥、配置 generation 失效与请求前后复验保持不变。
- UAPI 手机尾号验证、按票 Keychain 保存/复用/清除流程保持不变；请求回显的密钥/尾号仍在结果中隐藏。
- UAPI 账单快照来自响应头，保持 generation 与请求开始时间排序，不作本地余额推算。
- Tmini 每次 dispatch 前持久记账，单次按 4 积分估算；本地记账失败不发送请求。失败请求仍保留 dispatch 记账，收费以平台为准。
- HTTPS、禁重定向、无网络缓存、超时/体积限制、固定安全错误、运单身份及状态合并校验保持不变。
- UAPI 只用最新时间轨迹中的明确收件人实际领取事实纠正陈旧 `in_transit` 等字段；即使 `is_completed=false` 或粗状态字段互相矛盾，也允许该窄事实优先。没有该事实时矛盾仍拒绝。通用签收、驿站代签、快递员揽件、条件句、催取指令及更旧的已领取事件不触发这条纠偏；运单、时间、数量、同时间冲突与响应体边界校验不跳过。

## 历史兼容，不清理用户数据

`PaidTrackingCache` 暂保留旧格式 API 与测试兼容代码；`ShipmentPhoneStore` 的修改/清除仅调用其 `mutatePhone` 做对应运单设备私有旧 Keychain 身份的删除及空值回读，不再进入缓存目录或文件锁。同值保存也清理历史 secret；清理或回读失败时不修改主尾号，delete/import 退休日志继续负责重试。查询客户端的旧 `cache:` / `ignoreCache:` 注入标签保留但完全忽略，默认不实例化缓存。

本次不删除、不迁移、不覆盖用户历史 `PaidTrackingCache/success-v1.json` 或业务数据。历史缓存损坏、超限或旧缓存身份 Keychain 不可用不再阻断客户端查询，也不会被查询自动修复。尾号修改/清除仍遵循原有安全生命周期，而非全局清理。

## 验证范围

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_paid_cache_contract.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_audit_high_contract.py
git diff --check
```

源码契约先在旧实现观察 RED（4 项中 3 失败），移除后 GREEN。Python 仅检查源码，不是 Swift 编译或 XCTest。

已更新真实 XCTest：`PaidTrackingCacheTests` 验证重复查询逐次派发、Tmini 4 积分累计、UAPI 账单更新、失败不返回旧成功；`AuditHighRegressionTests` 验证损坏/超大历史缓存与失败旧缓存 Keychain 均不阻断请求，文件字节不变；`UAPITrackingClientTests` 增加最新实际领取与反例。

本轮遗漏修复另以 `scripts/test_pickup_omissions_contract.py` 先观察 4/4 RED，再实现并与 paid-cache、audit-medium-core 契约联合运行，14/14 GREEN。新增 XCTest 覆盖粗状态矛盾优先级（含 false completed）、响应边界、独立 event 条件作用域、缓存路径不可用/不创建目录/历史文件不变、只清对应运单 secret、删除不生效及回读失败；原 delete/import 退休重试隐私验证保留。`MallDeliveryState.recipientCollected(events:)` 逐独立事件判定，单事件跨逗号的条件句防护不放宽；调用方必须只传最新时间组。以上仍仅是源码契约已运行，XCTest 未运行。

本地无 Swift/Xcode，以上 XCTest 未执行；编译、XCTest、AppIntents/UI 及设备 Keychain/跨进程行为需后续获准的 macOS/iOS 验证。本任务未构建、未提交推送、未请求真实 API 或账号。
