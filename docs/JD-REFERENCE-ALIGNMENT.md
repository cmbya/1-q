# 京东按参考项目对齐：本地修复记录

基线 main `3fc8bee1fc720ed640ce652ab9432f7fd93887ce`（Build70.1）。
备份 `/vol2/@appshare/Ekko/.hermes/cache/scratch/before-jd-reference-alignment-20261104-104628.tar`，238条目已核对。
本轮获授权本地修复，未提交/推送/触发Actions/发布/使用真实账号/付费请求。

## 固定来源与真实对照

### Parcly（手机网页路径）

https://github.com/Granter-z/parcly/blob/0e4c7739205b368ab9bed3299f963a3e6fd9cf91/lib/platform/connectors/jd_connector.dart

- 214–252：打开订单列表，注入fetch/XHR，先消费已捕获响应。
- 255–279：没有可解析订单才执行DOM兜底与登录落点检查。
- 494–534：根据响应中的orderList/tracePointVOList/carriageId识别内容，不把请求页码作为订单结构有效性的前提。
- 633–644：JSON外包字符串先解码一层，再解码对象，读取body.orderList。
- 648–652：忽略非Map项，逐条识别订单。
- 684–709：progressInfo.progressLink、orderDetailLink.url及物流入口的sku/shop/state参数。
- 463–486：手机物流body.carriageId/carrier/tracePointVOList(createTime,wlStateDesc)。

https://github.com/Granter-z/parcly/blob/0e4c7739205b368ab9bed3299f963a3e6fd9cf91/lib/platform/connectors/jd_trace_parser.dart#L6-L31

- 缺progressLink时，已观察到的originOrderStatus、skuId、shopId、orderType构造公开物流页参数。字段仅取当前订单，不自行造状态。

### kdyzm（PC Cookie路径）

https://github.com/zsdd2/kdyzm/blob/b13c0527cb38f3aad79cacf8ca85efacaa0004ed/src/collectors.mjs#L618-L713
https://github.com/zsdd2/kdyzm/blob/b13c0527cb38f3aad79cacf8ca85efacaa0004ed/docs/jd-integration-3.1.9.md

- thor PC会话，不将pt_key当PC凭据。
- POST api.m.jd.com/api；列表appid=order-jd-com/functionId=pcorder_center_list，表单body={page,d:1,s:4096}；详情appid=details-jd-com/functionId=pcdetail_traceMultiPackage，URL body={orderId}。
- dateSubmit属于PC列表证据；processTimeInfo.submitDate属于PC详情证据，不据此断言手机接口也有。
- 父任务实际读取固定采集器618–713行并逐项核对现有JDPCClient：现有请求方式与以上对应，本轮未改PC代码，更未把手机凭证自动换成PC接口。

## 本轮最小修复

1. 响应先解码：支持一层JSON字符串外包；非对象、解码失败不再在大catch中混称JSON错误。
2. 手机允许按已证实响应结构捕获订单，不把functionId猜测作为唯一入口。仍限制HTTPS/JD域、主frame、当前订单页及桥接白名单字段，原始响应/凭证不出页面。
3. 请求分页元数据为null/array/无法解析、首次观察page2/3时，当前合法列表可以返回，只关闭不可信的自动翻页。已建立连续页上下文后错序/跨标签/模糊身份仍不能混入已验证集合。
4. 忽略非Map列表项；非空原列表没有任何有效Map时不能宣称真实空列表。原生身份格式/同单号歧义等校验保留。
5. 验证会话在收到合法列表后先验证当前URL/实时账号并返回，不因无DOM卡片、分页或其他请求仍在进行而失败。读取已有结构化结果后DOM脚本不可用只限制范围、不抛弃已识别列表。物流多响应合并不改。
6. 缺progressLink时，按参考的真实字段补齐公开物流入口参数，经原有入口/订单身份校验。非空但不合法的入口不做静默改写。
7. 新增闭集诊断responseDecode/responseSchema/scriptProcessing，区分解码、结构和内部处理异常，不输出任意错误信息/URL/订单字段；无可用结果时保留该原因而非一律unsupported。

## 没有声称完全照搬的部分

- Flutter/Android不能直接当Swift/iOS运行，采用参考协议/解析行为的独立实现，没有复制GPL源码。
- 用户要求30天购物全部状态，与两个参考默认筛选不同；保留明确的本项目筛选，不因参考默认排除签收/退款而违背用户要求。
- 保留已识别精确订单/运单、代次、CAS、手动完成、数据完整性与隐私约束。
- 不恢复参考中写出原始私密订单JSON的调试代码，不恢复已证明会混入推荐物流的全页轨迹DOM扫描。
- 保留之前已证实公开页面的受限滚动能力，但其成败不决定当前页识别或会话验证。不能保证全账号/全30天完整。

## 实际验证证据

- 新参考行为JS回归：先6项全部失败，再6通过；补物流参数用例先失败，修复后合计7通过。
- 验证快路径/闭集诊断源码检查先2失败后通过；已读列表不因DOM失败丢失的源码检查先失败后通过。
- Python unittest discover：148项通过；54源码/正则探针通过；AST和git diff --check通过。
- 原始生产内嵌JS六套：40项通过0失败；原有fetch/XHR及隐私脚本通过。合成数据不代表真实账号响应。
- 新增JDReferenceWebKitTests：2项离线WebKit脚本→消息桥→原生解析测试定义；新增1项日志分类原生测试。XCTest方法总定义695→698。
- 当前Linux没有Swift/Xcode，3项新增原生测试及全套原生测试均未执行。WebKit测试用loadHTMLString与模拟fetch，无账号，无外部业务请求；不能等同真实JD页面端到端。
- 11个PC/共享存储/付费/时间合并/淘宝拼多多相关文件与HEAD逐字节一致。

## 尚未验证

完整诊断只能定位到桥接前parse，不能证明用户真实失败一定就是双层JSON或null请求体；修复的是参考明确支持、旧实现缺失且已复现的行为。
手机页面真实响应形态、验证保存恢复、日期补取、自然分页和外跳仍需原生构建及设备验收。不存在本轮新IPA，不得拿Build70历史695项通过冒充本轮通过。
