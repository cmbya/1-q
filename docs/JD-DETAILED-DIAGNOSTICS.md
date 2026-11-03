# 京东安全详细诊断（本地实现）

## 入口与内容
沿用设置→本地诊断日志查看、复制、导出。须启用记录；日志仍限500条/512KiB。

京东新增：
- 用户操作开始/成功/失败：手动登录页、订单验证、读取可导入订单、单票查询、本地导入写入。
- 阶段：credential、jdCookieInjection、jdOrdersPage、jdOrdersParse、jdLogisticsPage、jdLogisticsParse、jdPageDOM、jdSessionSave。
- 页面导航阻止/网络失败/进程终止、脚本失败、桥接结构/身份拒绝、DOM是否识别；合成解析成功后记录订单/包裹数量。
- 主页面和已识别订单/物流fetch、XHR的HTTP状态；系统URL错误仅允许固定标准错误码，如-1001超时、-1009断网、-1202证书问题。其他数值丢弃。
- PC Cookie直连同样记录订单／物流阶段、HTTP／响应字节数、标准网络码及解析／身份错误；Cookie格式失败在credential阶段，钥匙串保存失败在jdSessionSave阶段。业务code=3固定归authentication，其他未知业务拒绝固定归unsupported，不记录原始message或业务码。
- 业务拒绝、JSON/结构不符、登录失效、需验证、无轨迹、身份冲突、超时、取消、安全保存等固定原因。

每项京东客户端操作使用自己的随机operation别名关联内部事件；UI操作和客户端操作目前各自成组，不宣称与外层tracking事件共享同一个operation。不会把临时未知结构直接当空成功。主流程正常轮询DOM只记录首个未识别与最终识别结果，事件类型在一次操作中最多20次，避免异常网页冲掉最终原因。

## 隐私边界
不记录密码、Cookie、token、验证码、原始NSError描述/userInfo、完整URL、订单号/单号/页面正文或完整响应。未知服务端业务码只记录business，不原样回显。HTTP状态是标准状态整数，不等同于物流平台业务码；页面主动请求能观察到的状态才能记录，不能保证获取所有WebKit内部资源错误。

## 验证范围
新增源码契约先RED后GREEN；Node执行真实嵌入脚本合成响应，覆盖安全诊断标签/HTTP以及敏感数据过滤。新增JDDiagnosticsTests 4项：网络脱敏、解析/保存分类、重复终止/洪泛上限、实际client前置失败记录。当前Linux无Swift/Xcode，这些XCTest未运行；离线检查不能替代iOS日志导出或真实京东页面验收。

本轮不触发真实登录、短信、付费查询、提交推送或构建；已移除时间拦截的代码保持不变，拼多多原查询链路不修改。
