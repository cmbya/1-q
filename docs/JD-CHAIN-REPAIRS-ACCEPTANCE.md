# 京东链路修复：本地整合验收

基线 main f7659d20ae655fbeca7d061d813f1154cfe665bf（Build67.1）。仅本地修复；无提交/推送/Actions/发布/真实账户或付费请求。
备份 /vol2/@appshare/Ekko/.hermes/cache/scratch/before-jd-chain-repairs-20261104-075356.tar，226条目已核对。

## 整合结果
- 手机结构化列表与同订单卡明确下单标签合并，仍缺日期则跟随真实唯一同订单详情链接补取，在日期筛选前执行。不借用物流/签收时间；PC缺dateSubmit没有证据时不猜字段。
- 手机跟随实际next链接：最多10页、20日期详情、20物流详情、总60秒、每页12秒，始终明确limited。PC原10页/20详情/30秒保留。
- 旧单刷新接通校验后sourceURL，不再依赖首页；认证详情必须匹配确切订单与运单。
- 空运单外层按有效字段回退内层，冲突拒绝；保留StatusName/Content，统一明确业务标签，售后服务不再因裸服务关键词误排。
- 同文档同订单多响应合并拆包、去重节点，不再首个有号响应立即返回，未完成请求不冒充完整。
- 手机读取/刷新末统一CAS保存轮换Cookie，代次、同raw pt_pin保护，剔除thor防止暗中切PC；verify、失败、取消、切号不保存。
- 独立成功订单保留，认证/风控停止、身份冲突隔离。报告区分无号/失败/未读，日志补六项闭集有界分类。
- 候选仅内存携带本次previewDetail，JD确认不再次联网。父任务已补TrackingRefreshService.applyMallPreview并接通ShipmentStore/UI。精确身份/carrier/代次/lease/事务保护，无时间新旧比较；既有后台/指定渠道保留且不隐式查询。
- 合并保留UUID、用户备注/取件码/提醒/历史/手动完成恢复，拒绝归档与签收降级。无轨迹仅关联、不计成功；无已知轨迹的未查询京东默认运输状态在列表、组件、快捷指令提示物流状态未核实，JSON枚举不变。

## 实际验证
- Python unittest discover scripts/test*.py：144通过；原有54源码/正则探针和UI源码检查通过。
- node --test scripts/test_jd_chain_js.mjs scripts/test_jd_30day_js.mjs scripts/test_jd_review_repairs_js.mjs：23通过0失败。生产内嵌JS合成页面测试，少数native断言仅源码契约。
- node scripts/test_jd_in_app_js.mjs：原有合成检查通过。
- python3 -B scripts/verify_ipa.py --self-test：5通过，仅校验器自测，非新IPA。
- git diff --check、Python AST、项目/工作流YAML通过。
- XCTest方法定义659→694，净增35。Linux无Swift/Xcode，新增/更新原生测试未编译运行；Build67历史659通过不能作为本轮证据。
- SharedPickupStore、MallDirectClient、TaobaoTrackingClient、KDYZMSync、ShipmentShortcutService、UAPITrackingClient、TminiTrackingClient与基线逐字节一致。
- 两项旧源码检查精确化：导航回调不保留原始WebKit错误；删除旧标识按完整token匹配，不误伤jdDetailFailed新指标。

## 尚未验收
- 手机近30天全部购物订单不保证：缺页面真实next链接不猜分页；无可信标签/详情链接仍missingDate，真机9笔能否补齐未知。
- 12秒后才出现的包裹响应不保证覆盖；等待有界窗口增加读取延迟，预算耗尽诚实报告部分。
- 登录恢复、服务端会话过期/风控、系统HTTPS universal-link外跳仍需真机验证，不使用私有WebKit API。
- 关联保存与预览合并为两个安全事务；后者失败保留关联并明确报告，不声称全量原子导入。
- 未提交/推送/编译，无本轮新IPA。后续需授权macOS完整构建与设备验收。
