# 商城实现边界

当前可用代码路径见 [拼多多 Cookie 直连](MALL-DIRECT-COOKIE.md)。`MallWebClient.swift` 只保留拼多多平台定义、隔离浏览器上下文、会话校验、通用协议和解析工具；不再包含网页查询引擎或 JavaScript 观察器。拼多多订单获取及刷新由 `MallDirectClient` 执行，登录 UI 由 `MallImportView` 保留。

旧京东网页和 PC 直连实现、探针、选择器及专属测试/脚本已删除。Shipment 中的历史订单关联与公开链接清洗函数仅用于历史数据兼容，不是查询入口。新后台协议不在本轮实现范围。
