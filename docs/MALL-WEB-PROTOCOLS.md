# 京东 / 拼多多正常网页物流模块

## 协议证据与实现边界

通过 `gh api repos/{owner}/{repo}/contents/{path}` 读取以下实际源码，只研究页面地址、字段与行为；本项目的 Swift / JavaScript 独立编写，没有移植 GPL Kotlin/Dart 实现或其宽松的身份回退。

- [Granter-z/parcly jd_connector.dart](https://github.com/Granter-z/parcly/blob/main/lib/platform/connectors/jd_connector.dart)：`order_list_m` 的 `body.orderList`；`orderId`、`wareInfoList[].wareName`；`get_logistics_list_by_order_m` 的 `body.carriageId/carrier/tracePointVOList[].createTime/wlStateDesc`。
- [Granter-z/parcly pdd_connector.dart](https://github.com/Granter-z/parcly/blob/main/lib/platform/connectors/pdd_connector.dart)：`orders` 或 `result.orders`、`order_sn`、`order_goods[].goods_name`。其无签名 GET 分页与订单号回退为运单号的做法不采用。
- [Halo0sama/ExpressAssistant JdListFetcher.kt](https://github.com/Halo0sama/ExpressAssistant/blob/main/app/src/main/java/com/halo/expressassistant/ui/JdListFetcher.kt)：正常订单页 SDK 的 `order_list_m` 响应。
- [JdTrackFetcher.kt](https://github.com/Halo0sama/ExpressAssistant/blob/main/app/src/main/java/com/halo/expressassistant/ui/JdTrackFetcher.kt)：`deal_wuliu_jdm.shtml?dealId=` 入口；其没有运单身份确认的整页 DOM 回退不采用。
- [PddCapture.kt](https://github.com/Halo0sama/ExpressAssistant/blob/main/app/src/main/java/com/halo/expressassistant/ui/PddCapture.kt)、[PddTraceFetcher.kt](https://github.com/Halo0sama/ExpressAssistant/blob/main/app/src/main/java/com/halo/expressassistant/ui/PddTraceFetcher.kt)、[PDD_REAL.md](https://github.com/Halo0sama/ExpressAssistant/blob/main/docs/PDD_REAL.md)：页面 SDK 请求 `aristotle/order_list_v4`；`order.html?order_sn=` → 页面自身“查看物流”只读控件 → `goods_express.html?tracking_number=…&shipping_id=…&order_sn=…`。物流 DOM 是“状态+日期时间”及物流描述，推荐流不属于轨迹。

没有自行构造或猜测商城 API 请求；只加载真实页面、在 document-start 观察页面原本的 fetch/XHR 响应。页面 SDK 决定签名与请求时序，不生成 `h5st` / `anti_content`，不读取 JS Cookie，不绕过验证码，不自动购买/付款/确认收货。

## 已提供接口

`MallPlatform`、`MallCandidate`、`MallTrackingQuerying`、`MallTrackingClient`、`MallSession`、`MallWebError` 和主线程 `MallWebClient`。

- 京东：订单页面 → 首屏响应 → 至多 8 个订单物流页面 → 已知 JSON 字段。必须返回真实 `carriageId` 和有效轨迹；不把订单号当运单号。
- 拼多多：订单页面 → 首屏响应 → 至多 8 个订单详情 → 精确白名单文案的只读物流控件（成功触发后不再点击）→ 物流页。必须 URL 的 `order_sn` 匹配订单，唯一 `tracking_number` 合法，且可见承运商标题包含同一运单号。
- 查询必须将轨迹页真实运单号与用户传入运单号逐字精确比较，不进行去空白/大小写修复；时间按中国时区解析，返回最新有效节点。不从模糊中文自行覆盖用户收件状态。
- 空订单数组只在已识别的订单结构内允许；未知结构、缺少运单或无轨迹明确失败。发生详情失败会整体失败，不把残缺列表伪装成完整同步。

## 安全与生命周期

HTTPS、无 userinfo、仅默认/443 端口；京东只允许 `jd.com` 及其子域，拼多多只允许 `yangkeduo.com` / `pinduoduo.com` 及其子域。没有增加无证据的 `3.cn` 白名单。所有导航都通过域名策略，拒绝新窗口及 App deep link。主 frame bridge 检查当前 URL、发送 frame URL 同 host，并只接收字段完全固定的 `response/url/body` 消息。响应上限 2 MB、URL 上限 8192 字节、每页最多 4 个匹配响应。原文只留在操作内存，清理即删除，不进入日志、备份或诊断。

每次操作创建独立 nonPersistent WKWebView，挂载前台窗口，不共享淘宝或其他商城数据。Cookie 用原生 `WKHTTPCookieStore` 注入；登录 UI 可通过原生 Cookie store 读取后调用 `MallSession.save`。本模块不提供自动 Cookie 导出入口。Keychain service 分平台，load/save/clear 均验证，域、路径边界、过期时间独立匹配，绝不调用限淘宝的 `TaobaoTrialCookie.applies`。

页面观察最多 40 轮，每轮 0.5 秒（另有 WebKit JavaScript 调用与调度耗时），网络请求超时 20 秒。Task 取消在等待/解析间检查并触发 defer：停止加载、移除 bridge/script、移除视图、释放响应。并发复用同一个 engine 被拒绝；App 非前台/无可挂载窗口明确抛 `unsupported` 并要求打开 App，不宣称后台快捷指令可用。

## 明确限制 / 待真机验证

- 首屏订单采样、最多 8 单，无完整分页承诺；不模拟触摸遍历历史订单。
- 当前实现京东只选有真实运单字段的已知 JSON 路径；若网页不触发该接口或需要额外页面参数，报错，不猜端点/退回无身份 DOM。
- 拼多多页面若物流控件、URL、标题或 DOM 改版，失败并保留上层旧数据。已签收订单可能只展示一个节点。
- 多包裹没有自动切换包裹 tab；只返回当前页面可证明身份的包裹。查询其他运单拒绝，不将整页节点套给多个包裹。
- 登录/验证页面需用户在可交互登录 UI 处理，本模块隐藏 observer 不自行处理挑战。
- 本模块未使用真实账号、未做 iOS 真机验证。Linux 本机无 Swift/Xcode；XCTest 已先于实现编写，但尚未编译/运行，最终由父代理授权 CI 执行。

## 测试

`MallWebClientTests.swift` 覆盖域名/协议/端口/userinfo、Cookie host-only/域/path/expiry、独立会话保存读取删除及失败、两平台订单结构、京东轨迹字段/时间/精确运单匹配、拼多多 URL+标题+DOM 身份与推荐流截断、未知结构、恶意 bridge/大小限制、登录/验证分类、非法订单 ID、取消及无会话失败。全部为合成 fixture，不提交任何真实账户响应。WebKit 加载/重定向/超时/进程退出的设备集成行为仍需 iOS 执行验证。
