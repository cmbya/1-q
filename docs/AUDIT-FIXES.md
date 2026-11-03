# 本轮审计修复交付记录

范围：2 高、8 中、1 低，共 11 项；仅本地工作树。未 commit、push、构建或使用真实付费账号。

## 修复清单

| 编号 | 级别 | 修复及关键文件 |
| --- | --- | --- |
| H1 | 高 | 将“完成取件”指令与“已完成取件”事实分开，驿站代收保留待取件。`MallDeliveryState.swift` |
| H2 | 高 | 强制刷新只绕过缓存命中复用，不绕过缓存完整性检查；损坏/超大缓存必须在付费请求前失败。`UAPITrackingClient.swift`、`TminiTrackingClient.swift` |
| M1 | 中 | 物流刷新和快捷指令不再重新打开人工完成记录；仍可完成待取记录，显式恢复入口及错误身份拒绝保留。`TrackingRefreshService.swift`、`ShipmentShortcutService.swift` |
| M2 | 中 | 尾号真实变更/清除先在缓存锁内删除并验证随机身份令牌，再写权威凭据；A→B→A 不复活旧缓存，同值保存可复用。删除和导入退休清理沿用该路径及原有持久日志，失败可重试。`PaidTrackingCache.swift`、`ShipmentPhoneStore.swift` |
| M3 | 中 | 后台终态结果过旧/冲突/不可用时，在回滚事务之外清理匹配任务，显示固定诊断且本次不重复 POST；清理验证身份、任务 ID、generation，合并也验证 generation。`KDYZMSync.swift`、`TrackingRefreshService.swift` |
| M4 | 中 | 主 App 完成按钮携带展示时记录，在事务内比较完整记录，拒绝编辑、移组、关联或完成周期变化后的旧按钮。`ShipmentStore.swift`、`PickupView.swift` |
| M5 | 中 | 切换共享存储后等待提醒对账并返回告警；繁忙和只读目标拒绝，离开设置页不会误更新 UI 或中止已开始的持久对账。`ShipmentStore.swift`、`SharedStorageSettingsView.swift` |
| M6 | 中 | Cookie 先逐项结构/域名验证，再过滤过期项，并确认有效登录凭据；过期统计 Cookie 不影响有效会话，外域、畸形及控制字符仍拒绝。`MallWebClient.swift` |
| M7 | 中 | 移除订单日期与独立时间续行，涵盖同一行日期、下一行时间；不吞乘车字段。`TrainTicketRecognition.swift` |
| M8 | 中 | 淘宝试验页退出后取消 Cookie 初始化并禁止再加载/捕获；拆卸和关闭幂等，Task 中显式 self 兼容 Swift 5 捕获规则。`TaobaoTrialView.swift` |
| L1 | 低 | 未签收组件复位携带所选快递 ID 和自动/手动模式，事务中比较后才清除偏好；旧 intent 缺参明确拒绝，不重置新选择。`PendingShipmentSelection.swift`、`PendingShipmentWidget.swift` |

## 兼容与复查

- 更新 `TrackingRefreshTests`：有同码待取记录时保留人工完成、物流仍可更新；错单号仍拒绝且业务数据不部分写入。
- 更新 `MallWebClientTests` 登录 fixture，补齐 `pdd_user_id`，保留外域拒绝与真实失败路径。
- 所有显式 `ShipmentPhoneStore(keys:)` 测试构造均注入临时目录缓存及内存 KeyStore，不依赖实际 App Group 或 Keychain。仅构造生产默认服务不触发缓存 I/O；修改尾号的测试路径均已注入。
- 复查 `reconnectSharedStorage` 调用已使用 await；新增 XCTest 没有在 XCTest 同步 autoclosure 内 await。
- 确认存储初始化确有“快递”“餐饮”两个默认分组；旧按钮移组测试改用 `XCTUnwrap`，不依赖强解包。
- 复查锁序为 tracking lease → dataset → paid cache；缓存尾号修改闭包不反向获取 dataset/lease；导入退休日志仅在成功清理后移除条目，失败保留重试。
- 新增 4 个 `Audit*Tests.swift`，程序统计共 **19 个 XCTest 方法**：高 2、中核心 8、中 UI 6、低 3；这是声明数，不是执行数。
- 新增 4 个 `test_audit_*contract.py`，并同步已有缓存/平台契约。低项与 fixture 隔离契约先运行得到 3 FAIL（RED），修复后进入全量 GREEN；这是静态契约 RED/GREEN，不是 Swift TDD 执行证据。

## 实际本地验证与边界

最终执行：

```text
python3 -B -m unittest discover -s scripts -p 'test_*contract.py'
  Ran 36 tests — OK（源码/正则契约）
python3 -B scripts/test_recognition_review_rules.py
  PASS: 54 source/regex probes
python3 -B scripts/test_review_ui_contract.py
  PASS UI source contracts, not SwiftUI/device tests
python3 -B scripts/verify_ipa.py --self-test
  Ran 5 tests — OK（构造的自测样本，不是新构建 IPA）
git diff --check
  无输出，退出码 0
```

环境未安装 Swift 或 Xcode（`swift` / `xcodebuild` 均未发现），没有安装工具链。Swift/XCTest **未编译、未执行**；Swift 语法、actor、协议、Equatable、参数调用和旧测试语义仅作源码复查，不等同于编译成功。未验证真实 WebKit/通知生命周期、设备并发、实际 Keychain/App Group 授权、付费网络服务或真实 IPA 签名/安装。发布前仍需获授权的 macOS/Xcode XCTest 和真机验证。

工具限制：patch 的说明提供 V4A，但实际调用 schema 仅接受 `path/old_string/new_string`；本轮现有文件采用兼容定点替换，没有整文件覆盖。
