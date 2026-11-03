# 拼多多 Cookie 直连与旧京东兼容

参考 Lyybutterflies/dsh-parcel-tracker 585111e14563a35ea62fb062aad9b0675739c79b，MIT；保留源码许可。

- 拼多多读取正常 HTML 的 `window.rawData`，订单身份与真实运单精确匹配，利用 shippingId 读取 shipping.traces；不伪造 anti_content。
- 固定第一页、最多八个候选订单，不承诺全量。订单不在本页、未知格式或无轨迹明确失败。
- HTTPS、固定主机/路径、拒绝重定向、Cookie 域/路径/过期校验、控制符防注入、2MB 响应限制；不自动重试或切换 UAPI。
- 网页登录及 SecureField Cookie 导入都先验证订单访问，再保存 device-only Keychain。Cookie 不进入 JSON、日志或聊天；登录页继续只允许拼多多域。
- 保留淘宝、UAPI、通用 MallDeliveryState 和历史来源展示。旧京东入口、PC/网页直连及观察器已经删除；新后台尚未接入。
- 历史 `originPlatform=jd`、platformOrderID、platformLogisticsURL、轨迹、备注、取码、UUID 及备份结构不变。自动/仅商城刷新明确失败，不触发付费 fallback；显式 UAPI 选择仍可用。
- 旧京东钥匙串既不读取也不删除或迁移；历史诊断事件保留兼容，不清日志。

## 验证边界

本轮只授权本地清理和离线检查，不提交、推送或运行 CI。Swift/Xcode 不可用，XCTest 已更新但未执行；Python 源码契约不是 Swift 编译或设备测试。登录、Keychain、真实订单及 iOS UI 仍待验收。
