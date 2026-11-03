# 京东双登录与订单／物流连接器（本地开发）

## 用户入口
设置 → 京东导入（试验）：
1. **账号网页登录京东**：打开京东官方手机HTTPS登录页，用户自行选择页面提供的账号密码／短信等方式并完成安全验证。App不保存密码，不自动发短信，不保证平台始终提供特定登录方式。
2. **导入Cookie**：粘贴本人京东电脑版订单页的完整Cookie值，格式为`name=value; name=value`，必须含非空`thor`，不要求`pin`；不接收curl、整组请求头或只有`pt_key/pt_pin`的手机凭据。严格格式校验后访问实际订单，成功才保存本机京东专属Keychain；验证失败不触碰原Keychain会话。

网页登录使用全新非持久WebKit上下文，不带入已有PC Cookie或旧网页账号；验证使用同一新上下文，避免验证成旧账号。Keychain保存成功后才替换京东共享网页上下文，取消不替换。拼多多仍使用原直连客户端和原Cookie方式，淘宝不重做。

## 两条读取链路
统一入口`JDInAppClient(cookies:)`提供verifySession、fetchOrders、query；不因其中一条失败自动改走另一条。

### PC Cookie
存在适用于`https://api.m.jd.com/api`的thor时，派发独立`JDPCClient`。
- 列表：POST固定HTTPS主机／路径，functionId为pcorder_center_list，appid为order-jd-com，表单body含page=1、d=1、s=4096。
- 物流：同入口POST，functionId为pcdetail_traceMultiPackage，appid为details-jd-com，查询body只含orderId。单票不要求出现在第一页，但返回的真实运单号必须唯一匹配；若响应另含orderId则必须一致。
- 不添加签名、设备token、UUID或PassKey。复用现有AISecureNetwork拒绝重定向；Cookie不进全局Cookie jar，域、路径、有效期及头注入检查。
- 每次读取第一页，最多8笔活跃实物订单详情，总预算30秒；单票20秒。每个请求有超时与主动取消，取消后不发后续请求；无自动重试或付费fallback。
- 解析orderList、multiPackageTrackInfoList、carriageInfo及每包裹orderTrackShowList；服务／虚拟、取消／已完成等不作为新快递。无真实单号不拿订单号顶替，拆包不混轨迹，重复／错配拒绝。当前没有无运单订单工作台。
- 401或业务code=3归登录失效，403/429归需验证；未知JSON／结构归解析失败，不当空成功。响应接收后检查大小5MiB（复用网络层不是流式内存硬上限）。验证返回轮换后的fresh Cookie供用户确认保存；后续读取／查询仅在显式会话代次和原快照仍匹配时保存轮换值。长期有效性需实测。

### 官方手机网页
- 页面：`https://plogin.m.jd.com/login/login`、`https://trade.m.jd.com/order/orderlist_jdm.shtml`。
- App前台WebKit，document-start捕获页面自身fetch/XHR，字段白名单投递native。物流详情无可信容器证据，因此停用整页DOM物流兜底，避免推荐区节点混入；订单列表DOM及安全验证识别保留。无Cookie／原始响应JS桥；未知结构不能当0订单。
- 当前第一页，最多8个详情，总预算30秒；单票列表+详情20秒，每页12秒。缺席历史订单明确失败，不猜身份；不能在后台执行WebKit时明确不支持。

已有backendBinding继续使用后台；显式UAPI/Tmini选择不变。物流新旧时间拦截不恢复。两条链路均保留详细安全诊断：阶段、固定原因、HTTP及白名单网络错误码、数量；不输出Cookie、密码、完整URL、订单或单号、原始响应。见`JD-DETAILED-DIAGNOSTICS.md`。

## 公开行为参考与许可
- `Granter-z/parcly@0e4c7739205b368ab9bed3299f963a3e6fd9cf91`：登录与前台网页读取行为。
- `zsdd2/kdyzm@b13c0527cb38f3aad79cacf8ca85efacaa0004ed`：docs/jd-integration-3.1.9.md、src/collectors.mjs、test/jd-collector.test.mjs：PC Cookie与协议字段。上游说明只验证PC Cookie，不把pt_key等价为thor。
- 独立Swift实现，不复制GPL或自定义非商业许可源码。

## 验证边界
源码契约按Cookie解析、PC路由／读取、双入口、账号隔离和请求截止分别先失败后通过。新增JDCookieLoginTests、JDPCClientTests的XCTest定义，涵盖请求参数、拆包、错配、失效、未知结构、重定向、大小与取消。Node执行原移动嵌入JS合成响应／隐私检查。

Linux无Swift/Xcode，**没有编译Swift或运行新增XCTest，也未使用真实账号**。PC客户端真实网络行为及两个入口登录成功、保存后重开、账号切换、真实拆包均待获授权构建及用户真机验收。本轮没有提交、推送、构建、短信或付费查询。
