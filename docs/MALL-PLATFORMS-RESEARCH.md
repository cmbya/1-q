# 京东、拼多多、抖音商城接入：源码调研与范围

## 已有保证
保留已真机验证的淘宝流程、旧备份及记录身份、备注/取件码/提醒和UAPI规则。商城失败不自动转UAPI。不绕过验证码，不伪造签名，不导出Cookie或原始账号响应。不因新增平台放宽已有域名保护。

## 京东
旧直连实现已删除；保留历史数据与明确失败边界，新后台尚未接入。不使用旧网页接口作为回退。

## 拼多多
参考 Granter-z/parcly pdd_connector.dart，以及 Halo0sama/ExpressAssistant docs/PDD_REAL.md、PddTraceFetcher.kt。
- 登录 https://mobile.yangkeduo.com/login.html
- 订单 https://mobile.yangkeduo.com/orders.html
- 详情 order.html?order_sn=<订单号>，按页面实际物流链接进入goods_express页。
- 订单接口 aristotle/order_list_v4；上游真机记录指出POST正文含SDK动态anti_content，无签名GET的page被忽略，只能当首屏种子，不能宣称完整分页。
- 使用正常网页登录和页面自身SDK，不实现/绕过风控签名，遇挑战交用户处理。

## 抖音：阻碍
已读 Lyybutterflies/dsh-parcel-tracker lib/platforms/douyin.js：作者明确记录默认端点无登录请求返回status_code=1、Url does not match；可自定义端点+通用解析不构成有效买家物流实现。不能照搬后标为已接入。
GitHub多组定向搜索尚未找到足够证据的个人买家订单+轨迹完整链路。商家订单开放接口不适用于本用户。不得猜测接口或交付仅登录空入口充数。

## 当前实施及验收边界
淘宝、拼多多 Cookie 直连和显式 UAPI 保留；本轮不实现新后台，不提交推送、不触发 CI。源码/正则检查不代表 Swift 编译、登录或 iOS 真机验证。
