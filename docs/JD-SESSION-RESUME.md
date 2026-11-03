# 京东网页登录恢复与显式换账号

## 入口语义

- **继续网页登录**：读取本机钥匙串中尚未过期的手机 Cookie，保留 Secure、HttpOnly、expiry 等属性，注入新的独立 `WKWebsiteDataStore.nonPersistent()`，先打开官方手机订单页；缺少／过期的手机凭据才直接打开登录页。服务端认定失效时仍由官方页面要求手动登录或验证。恢复不等于保证会话仍有效。
- **切换账号（全新手机网页）**：使用空的独立临时 store，不注入任何旧账户 Cookie；取消或验证失败不会替换原钥匙串和已提交的订单读取 context。
- **电脑版 Cookie**：有有效 `thor` 时，普通继续按钮只解释当前 PC 会话可直接读取，不打开空手机登录页，也不转换为 `pt_key/pt_pin`。即使 PC 快照还带有手机 Cookie，也不会隐式转换。改用手机网页登录必须显式切换。

恢复有意不直接借用 `MallBrowserContext.store(for: .jd)`：该全局 live store 尚无 generation／账户标记，直接复用可能带入未知或被页面变更过的账户。当前采用用户允许的安全替代：从保存快照恢复到隔离 store；登录页内存及 localStorage 不跨这次重开恢复。成功验证并保存后，才将新 store 提交给后续订单／物流读取。同一 sheet 被暂时遮盖／外跳再返回时保留原 WebView，不重建或清空。

## 提交与清理边界

1. 打开网页捕获 `MallSession.generation`；setup、navigation、capture、verify 检查原代次。
2. 保存时禁用可见网页交互及导航，停止可见页加载，实际订单验证使用同一隔离 store；验证前后要求 `pt_pin` 唯一且一致，允许 token 轮转，不接受中途换账户。
3. 现有 `MallSession.withGeneration` 原子边界中先 `save(...expectedGeneration:)`，成功才 `commitJDContext()`。旧任务不能覆盖较新登录／清除后的会话或发布其旧 context。
4. 取消按钮销毁 WebView 并取消 browser 所持验证任务；sheet 实际 `onDismiss` 统一清理。保存过程中禁用手势关闭，但取消按钮仍可取消。
5. 京东不再把 sheet／父页面临时 `onDisappear` 当作注销；平台改变、明确清除及实际关闭仍清理。拼多多的入口、凭据及直连订单读取保持原路径。
6. 不自动发短信、不存 App 账号密码、不请求远端 logout，不添加持久实体或无码工作台。

## 近30天报告

`MallImportClient.fetchOrderReport()` 只用于京东，接 `JDInAppClient` 的 PC／mobile report。UI 无论候选是否为空都展示 `report.message`，因此扫描、筛选、无码、缺日期、范围外及截断提示不会被通用空结果覆盖。只对真实运单生成可勾选候选；仍由用户确认才导入。

临时模式按筛选模块的上海日历日近30天、购物订单所有状态（含已签收）说明，明确排除外卖／秒送／虚拟／服务类；未知日期及分页／详情／时间预算限制不宣称全量。拼多多仍走原 `fetchOrders()`，不依赖京东报告类型。

## 外跳与日志：已做与未保证

- 保留平台 HTTPS、host、端口、userinfo 校验；京东 `targetFrame == nil` 一律取消，不再把新窗请求盲目装入主框架；不调用 `UIApplication.open`。
- 官方公开枚举文档（只读核查）：<https://developer.apple.com/documentation/webkit/wknavigationactionpolicy>，其 JSON <https://developer.apple.com/tutorials/data/documentation/webkit/wknavigationactionpolicy.json> 列出 `cancel`、`allow`、`download`，未列出 `allowWithoutTryingAppLink`；该 case 独立文档返回404。故没有使用未经核实 case、私有枚举 raw value 或假定的 iOS17 接口。
- **不能保证消除所有 HTTPS universal link 外跳**：许可 HTTPS 仍使用公开 `.allow`。UI 和注释不宣称已根治；这需要后续真机观察和可验证公开 API 方案。
- 登录 WebKit 网络错误仅转为固定 `.network`、`.timeout` 或取消类型；日志仅闭集事件／原因及白名单网络码，不输出任意 NSError domain、URL、cookie、响应或页面文本。

## 回归与证据范围

新增 XCTest：手机恢复先订单、属性保留、显式切换不注入旧凭据、PC 不转换（含混合快照）、缺失／过期、排除过期与跨站 Cookie、安全错误分类；UI session 测试补取消候选不写原会话、新代次拒绝旧提交。

本次离线 sourceguard 先得到缺失 resume policy／report UI 的两个失败，再实现后通过目标集合：

```sh
python3 -m unittest scripts.test_jd_import_ui_contract scripts.test_jd_cookie_login_contract scripts.test_jd_review_repairs_contract scripts.test_jd_session_continuity_contract
# 20 tests OK

git diff --check
# 无错误
```

日常 Skill 目录未列出 TDD/systematic-debugging，遵守档位未绕过读取；按失败回归→实现→目标回归执行。Linux 下未编译、未运行 XCTest、未调用真实登录 API、未自行提交／推送／触发 Actions。sourceguard 仅检查源码契约，不是 iOS 编译或真机证明。父任务负责集成 CI；仍需真机验证保存→关闭→重开、切换取消、外跳返回、会话失效和验证流程。
