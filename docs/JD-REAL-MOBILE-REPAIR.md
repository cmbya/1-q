# 京东真实手机入口与自然分页修复（本地）

基线 `739ac670b9d14490884f7c1095908101f020f951`，备份 `/vol2/@appshare/Ekko/.hermes/cache/scratch/before-jd-real-mobile-20261104-092000.tar`（234条目核对）。未提交/推送/Actions/编译，无新IPA，无真实账号请求。

## 修复和证据

- 列表JSON直接保留`orderDetailLink.url`为临时dateURL；Swift与JS同时支持真实`/order/n_detail_jdm.shtml?deal_id=`，多身份参数/无值重复参数/异单/敏感链接拒绝。
- 被动捕获`order_detail_m`，只接受当前详情URL、请求body.orderId、响应body.orderCommonVo.orderId三方一致。读取原始summaryList唯一明确下单标题的字符串content，规范br后走严格日期解析。不凭createTime猜日期。
- native dateOnly桥不再丢弃结构化orderDate；返回前重验当前URL与会话账号。原DOM日期回退保留，不恢复整页物流DOM。
- 当前公开OrderInfo默认可能折叠摘要，只显示第一行；实际getSummaryList原样复制title/content，故结构化读取不依赖展开详情按钮。
- 手机列表同一个WKWebView连续监听页面自然请求，按原请求page/pageSize与闭集业务上下文匹配顺序合并，准确订单ID去重；未知或错序响应不覆盖已验证列表。
- 使用源码证实的唯一活动.taro_page，先滚至离底>400解除Taro锁，再滚到底<400，页面自己发下一页，不构造请求/签名/调用React内部对象。连续页、重复、tab改变、短/空页、容器无法解锁均有边界；不能把totalNum当全局总数。
- 列表最多10页/200去重订单/20秒、停滞3秒；整个原有60秒/20日期详情/20物流详情预算保留。受限始终limited；分页未收尾不保存轮换Cookie。验证登录只看首个列表、不自动翻页。
- 日志增加原有闭集hasLink/hasDate/round计数与安全补日期失败原因，不输出URL/账号/订单响应。

## 可核验公开来源

1. https://jstatic.3.cn/order/js/5.83c444a16e0a3454edec.js
   - orderDetailLink.url的订单卡点击、pageNum/pageSize与useReachBottom业务门控。
2. https://jstatic.3.cn/order/js/4.3173f100f21f3d983983.js
   - getSummaryList直接复制title/content；OrderInfo消费orderCommonVo.orderId/summaryList并折叠展示。
   - getSummaryList偏移253201（UTF-8解码后原字符串），请求orderId由deal_id优先取得。
3. https://jstatic.3.cn/order/js/14.b890f3cbaa0b12f47c11.js
   - getPageContainer对应.taro_page；真实scroll回调距离>400重置锁，<400触底。
4. https://jstatic.3.cn/order/js/app.ec9129b371c78607d8eb.js
   - 列表路由onReachBottomDistance=400。

父任务匿名重新读取原静态资产，独立文本核对了以上前三处关键片段。没有执行整站远端JS或访问账户接口。

## 回归证据

- 新真实入口3项先失败→通过；详情响应测试先无orderDate失败→通过；自然分页4项先失败→通过；错格式后续响应不覆盖测试先失败→通过。
- `python3 -B -m unittest discover -s scripts -p 'test*.py'`：146通过，原54源码/正则探针通过。
- `node --test scripts/test_jd_real_mobile_js.mjs scripts/test_jd_mobile_paging_js.mjs scripts/test_jd_chain_js.mjs scripts/test_jd_30day_js.mjs scripts/test_jd_review_repairs_js.mjs`：33通过0失败。
- `node scripts/test_jd_in_app_js.mjs`、Python AST、git diff --check通过。
- XCTest定义694→695；Linux没有Swift/Xcode，未编译或执行，不能复用Build69历史通过作为本轮证据。
- 11个被保护的存储/PC/策略/平台/付费/时间合并相关文件与HEAD字节一致，本轮生产仅改JDInAppClient。

## 未验证/不能承诺

- 当前仍无用户账号真实详情响应，无法保证9笔均有明确下单标签，未知继续报告缺失，不虚构日期。
- WKWebView当前Taro容器尺寸、React实际提交时序和带账号第2/3页仍需原生/真机验证，合成容器通过不是线上端到端。
- 列表最多20秒、整个60秒，页面无响应或容器不足以解锁停止并报告部分，不能宣称全30天全量。
- 服务端风控/会话过期和HTTPS外跳仍未证明已解决。
