# JD mobile 链修复：交付范围与验收边界

## 已实现
- 结构化订单先和同订单卡显式下单标签合并；仍缺日期时，仅沿该卡实际存在、唯一、确切同订单 ID、trade.m.jd.com `/order/*detail*` 的链接读取日期页。日期页必须同时有唯一明确订单号和唯一明确下单标签；日期补取在 `report.consider` 之前。无可信日期仍计 missingDate，不用物流/签收日期。
- 页面实际出现的 `下一页` / `rel=next` 同站订单列表链接可以继续读取；去重、循环检测，最多 10 页，日期详情最多 20 次、物流详情最多 20 次，总预算 60 秒，每个页面最多 12 秒。
- 旧单刷新新增 `query(orderID:trackingNumber:sourceURL: String? = nil)`，严格经 `Shipment.logisticsEntry`，无 URL 使用既有公开物流入口；不再要求当前首页含该单；真实认证详情必须匹配确切订单及运单。
- JS 修复空顶层 carriageInfo 遮蔽 group.orderCarriageInfo；冲突运单身份拒绝；保留 StatusName + Content；去掉裸“服务”误伤售后。
- 同文档、同订单多响应累积包裹和去重轨迹；native 不在首个有号响应返回，等待有界捕获窗口，仍在进行的已知请求不当完成；结构化空响应仍是暂定证据。禁止恢复整页物流 DOM。
- 正常 fetch/query 在 operation 末仅一次读取 live cookie 并调用既有 saveRotated：原快照 CAS、generation、同 raw pt_pin；verify 不保存，失败/取消/切号不保存，锁内无 await。每页读取前后也检查账号一致。
- 单订单详情错误保留其他已接受候选；认证/风控停止并标 stoppedReason；冲突撤销相关订单候选；失败计数调用 report.recordDetailFailure，不直接递增导致分类交叉。

## 跨文件接口（由其他代理负责）
- `JDOrderImportReport.recordDetailFailure(orderID:)`、`detailFailed`、`stoppedReason`、append 携带 previewDetail 已接入。
- 调用方务必把 Shipment.sourceURL 继续传给 JDInAppClient.query；不要在 MallWebClient 层丢弃它。

## 未交付/不得宣称
- **近 30 天全部购物订单尚不能保证**：没有可证实的 mobile 历史分页协议/总量证据。没有真实 next link 就停止，report.limited 始终 true；不能因无 next link 当完整。
- 真机 9 笔缺 dateSubmit 不代表这次已补成功；如果页面不提供可验证同订单卡标签/详情 link，仍会报告缺失。没有请求真实账户。
- 12 秒全捕获窗口和 60 秒 operation 预算是安全/延迟权衡；大量订单不会一次读全；窗口之后才发出的分次包裹请求仍不能保证覆盖。
- 链接只使用公开 WKWebView.load；没有私有 WebKit 枚举/API，也不承诺杜绝所有 universal-link 外跳。
- 当前环境无 Swift/Xcode。新增 XCTest 仅定义、未编译/执行；JS 的 native 合约断言只是源代码结构检查，不是原生集成测试。

## 离线证据
- 先运行 `node --test scripts/test_jd_chain_js.mjs`：原始代码 7 测试全失败（exit 1），日志 `/vol2/@appshare/Ekko/.hermes/cache/terminal-output/out-1793750194-2637670-9a70.log`。
- 修复后运行 `node --test scripts/test_jd_chain_js.mjs scripts/test_jd_30day_js.mjs scripts/test_jd_review_repairs_js.mjs && node scripts/test_jd_in_app_js.mjs`。最终结果见执行回报（所有嵌入生产 JS，用合成 fixture，无外网）。
- 两个要求的专用 Skill 均被当前日常档拒绝，未换入口/绕过/切组。
