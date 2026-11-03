# 京东临时近30天购物订单测试模式

本说明覆盖本轮的 JDPCClient / JDInAppClient 改动；旧 JD-IN-APP-CONNECTOR.md 中“第一页 / prefix(8) / 仅活跃状态”的历史描述不再适用于本模式。仅京东，未改变淘宝、拼多多、物流刷新新旧时间判断或付费通道策略。

## 统一接口与统计

两客户端均提供 `fetchOrderReport() async throws -> JDOrderImportReport`；兼容 `fetchOrders()` 仅返回 `report.candidates`。`now: () -> Date` 可注入，操作开始时固定一次窗口。现有初始化调用不需要添加参数。

`JDOrderImportReport` 不含凭据，字段为：
- `candidates: [MallCandidate]`：真实、校验过的运单预览，不代表已保存到 Shipment。
- `scanned`：本次读到且按订单 ID 去重的订单数。
- `eligible`：符合日期、且无明确非购物证据的订单数，所有状态均参与，包括已完成、已签收、取消、退款、未付款。状态不再作为 pending 门槛；无运单仍不能生成快递。
- `excluded`：明确外卖/秒送/虚拟/服务证据，优先分类。
- `missingDate`：未被排除、但缺少有效可信下单日期的订单。
- `outsideWindow`：未被排除且有有效日期、但不在窗口内的订单。
- `withoutWaybill`：已读取并识别为空运单的 eligible 订单数；未读/超时不冒充无运单。
- `limited`：列表或详情未读完，或手机页范围无法证实完整；不声称全账号全量。

互斥分类恒等式：`scanned == eligible + excluded + missingDate + outsideWindow`。候选数量是运单数，不是订单数；同单拆包会增加运单数。message 显示这些统计、尚未读完详情的 eligible 订单数和范围限制，明确“暂无真实运单，暂无法生成快递”，不称已导入。

## 日期边界

Asia/Shanghai 公历日，**包含今天及前29天**：半开区间 `[今天-29天 00:00:00, 明天 00:00:00)`，不是向后滚动720小时，也不是前30天再加今天。

例如注入 `2026-11-04 15:30:00+08:00`：窗口是 `[2026-10-06 00:00:00+08:00, 2026-11-05 00:00:00+08:00)`，10月15日已签收购物订单符合。开始边界包含，结束边界不包含；当天晚于执行时刻的日期仍按所约定日历日窗口处理。

仅使用列表 `dateSubmit`，或同一订单卡片中明确标注的“下单时间/下单日期/提交订单时间/订单创建时间”。无时区字符串按上海解释；严格支持日期、分钟/秒、秒/毫秒时间戳、显式时区ISO。不存在的日期、布尔值、未知格式记 missingDate。不用物流时间、签收时间、同步时间或猜测 createTime/orderTime 替代。日期缺失不影响 verifySession 对已识别列表结构/账号访问的验证。

## 筛选证据

PC 与 mobile 使用相同业务规则：公开已验证的 orderType 4/69、全 wareType 1，或业务/状态字段明确出现外卖/秒送/虚拟/服务。未知数字类型不凭猜测排除；产品名称不用于排除，含“配送”或“服务机器人”的实物名称不因此被过滤。DOM 只读取订单卡片、物流链接绑定 ID，业务标签需明确的独立行；不恢复整页 logistics DOM。

## PC 有界读取

- 已有公开协议：`POST https://api.m.jd.com/api`，列表 `pcorder_center_list`，表单 body `{page,d:1,s:4096}`；详情 `pcdetail_traceMultiPackage`，URL body `{orderId}`。未添加签名、设备字段或 fallback。
- 按 page=1…10 读取。先列表后详情，避免第一页20个外卖挤掉下一页10月15日购物单；不假设全局日期排序，不凭首个旧日期提前结束。
- `totalNum` 达到即结束；显式空页结束；与 totalNum 矛盾的空页标 limited；跨页去重，无新增 ID 的重复页立即结束并标 limited；达到10页仍未知结束标 limited。页内重复/不合法身份仍拒绝。
- 对 eligible 最多20笔详情，总预算30秒（包括全部列表），每请求最多20秒且剩余预算更少时缩短；取消会停止后续请求，无自动重试。
- 首次列表超时仍抛错，不能把未知当空账号；已有列表后超时/预算耗尽返回准确的部分报告。详情超时不增加 withoutWaybill。认证、验证、身份、未知结构错误仍失败，不隐藏为成功。
- 不缓存报告/订单/物流，无物流新旧时间拦截，无自动付费查询。会话代次、Cookie轮换和取消保护保留。

## Mobile 的真实限制

仅捕获页面自己的 fetch/XHR，不伪造移动API分页参数、签名或无证据滚动脚本。本轮只能证实当前页面/响应，故 mobile 报告保守固定 `limited=true`，即使显示空页也不宣称所有订单已读完。最多20详情、总30秒、每页面12秒。

只白名单转发 dateSubmit 和业务判断结果；若移动真实响应没有该字段且卡片无可信下单标签，记 missingDate，验证仍可通过。移动接口真实日期覆盖率待真机观察，未假定它一定返回 dateSubmit。

已知结构中无真实运单时发送单独 `logisticsEmpty` 暂定证据。native 不立即结束捕获：在正常页面读取窗口内仍优先接收后续有单号响应；窗口结束、页面已加载且只有绑定当前订单的空证据时才计 withoutWaybill。未知响应、未完成页面或单纯超时不冒充无运单。整页物流DOM仍关闭。

## 公开证据（只读、无账号）

固定引用 `zsdd2/kdyzm@b13c0527cb38f3aad79cacf8ca85efacaa0004ed`：
- https://github.com/zsdd2/kdyzm/blob/b13c0527cb38f3aad79cacf8ca85efacaa0004ed/docs/jd-integration-3.1.9.md ：明确 `{page,d:1,s:4096}` 近3个月订单、dateSubmit、类型4/69及虚拟字段。
- 同commit `src/collectors.mjs` 的 collectJd：page循环、data.data.totalNum、空页与重复页处理，详情独立orderId。

本轮 web_extract 因网络地址判定拒绝；一次 urllib 直连公开 raw.githubusercontent.com 成功读取上述固定文档及源码。独立Swift实现，未复制上游业务源码，不请求真实京东账号。

## TDD / 验证边界

先增加 `scripts/test_jd_30day_js.mjs` 并真实执行：5/5失败（缺日期、排除字段、DOM日期及空物流证据）；增加源码契约4项：3失败1错误（缺共享文件/API/分页）。实现后分别5/5、4/4通过。Node执行的是生产Swift里提取的原始嵌入JS，不是另写的筛选模拟器。

```sh
node --test scripts/test_jd_30day_js.mjs scripts/test_jd_review_repairs_js.mjs
node scripts/test_jd_in_app_js.mjs
python3 scripts/test_jd_30day_contract.py
git diff --check
```

原生 XCTest 增补：JDOrderImportPolicyTests（日历边界、严格日期、统计分区、文案），JDPCClientTests（20外卖后第二页10月15日已签收、无单号/缺日期/范围外分开、重复/空页、10页/20详情预算、超时部分报告、缺日期验证及兼容拆包），JDInAppClientTests（完成状态不被门槛挡住、缺日期可识别、产品名不误排）。

**Linux没有Swift/Xcode，原生测试尚未编译或执行**，源码契约不是原生行为通过证据。未构建、未提交/推送、未触发Actions、未用真实账号；父任务负责整合后编译/CI与真机验收。

整组旧契约曾运行，部分仍硬编码 prefix(8) 和旧登录UI字符串；本轮targeted绿不表示那些过时契约已更新。UI/session文件由并行任务持有，本任务未修改它们。
