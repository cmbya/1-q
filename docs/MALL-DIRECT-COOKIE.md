# 京东/拼多多 Cookie 直连修复

参考固定版本：Lyybutterflies/dsh-parcel-tracker 585111e14563a35ea62fb062aad9b0675739c79b，MIT。不是根据猜测拼接接口。

- 京东：PC网关 POST 表单 body=JSON，列表取orderType/status，逐订单查多包裹，刷新必须精确匹配运单；不可只取第一包裹。
- 拼多多：正常HTML window.rawData，订单提取shippingId等，goods_express读取shipping.traces；不用伪造anti_content。
- 刷新从WebView迁移到固定HTTPS网络请求；无重定向、无自动重试、无UAPI回退；旧平台来源/订单ID兼容。
- 现阶段为了获取网关必要参数，每次刷新先重取第一页列表；订单不在本页时明确失败，不宣称全量。
- 网页登录可保留作为Cookie获取手段；新增App内SecureField粘贴Cookie值，严格拒绝请求头/curl/控制符/重复键；订单访问验证后才写device-only Keychain，不落JSON/日志。
- Cookie仍会过期；用户须更新。绝不向聊天发送Cookie。
- 本轮用户已授权提交推送和完整CI测试编译交付IPA。无真实登录或付费API查询授权。Swift本机不可执行，测试先写、最终CI实跑，源码辅助检查不能充数。
