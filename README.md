# 快递管家（ParcelKeeper）1.1

一个只给自己用的 iPhone 快递记录 App。核心操作是：**复制运单号或整段物流信息 → 打开 App → 点击智能粘贴 → 确认并保存**。

## 1.1 更新

- 修复点击粘贴后偶尔出现白屏、页面没有内容的问题：改用单一数据驱动的 `sheet(item:)` 路由，不再先打开空 Sheet 再等待数据。
- 粘贴过程增加忙碌状态，防止连续点击造成重复弹窗或页面竞争。
- 粘贴失败时可以直接手动输入运单号。
- 支持一次识别多个运单并批量导入。
- 支持从整段淘宝、京东、拼多多物流文字中提取：
  - 运单号
  - 快递公司
  - 平台来源
  - 取件码
  - 待取件、派送中、已签收、异常等状态
  - 驿站或快递柜文字
- 加强手机号、订单号、身份证号等误识别过滤。
- 手动修改运单号时会重新判断快递公司。

## 已有功能

- SwiftUI 原生 iPhone App
- 系统 `PasteButton`，只有主动点击时才读取剪贴板
- 本地保存、搜索、删除、归档及重复运单拦截
- 运输中、派送中、待取件、已签收、异常等状态管理
- 备注与取件码
- 本地定时提醒
- JSON 备份导出与导入
- GitHub Actions 编译无签名 IPA

## 在 GitHub 编译

1. 新建 GitHub 仓库。
2. 将压缩包里的所有文件上传到仓库根目录，注意 `.github/workflows/build.yml` 不能漏掉。
3. 打开仓库的 **Actions** 页面。
4. 选择 **Build Unsigned IPA**。
5. 点击 **Run workflow**。
6. 编译完成后，在本次运行页面底部下载 `ParcelKeeper-unsigned`。
7. GitHub 下载的是一层 Artifact ZIP，解压后里面才是 `ParcelKeeper-unsigned.ipa`。

IPA 是无签名版本，需要用自己的 Apple 签名方式重新签名后安装。

## 关于淘宝、京东、拼多多账号直连

这三个平台的开放接口主要面向商家、服务商和经过审核的开放平台应用，需要 App Key、密钥、授权范围和服务端回调。普通个人 App 不能只做一个网页登录，就合法、稳定地读取消费者账号的全部待收货订单。

本项目不保存淘宝、京东、拼多多密码，也不通过 WKWebView 抓取登录 Cookie 或解析私有页面。那种方式容易触发风控、随页面改版失效，也有账号安全风险。

更稳妥的后续路线：

1. 申请平台正式开放权限后通过 OAuth 接入；或
2. 接入正规快递查询 API，通过运单号自动刷新轨迹；或
3. 增加订单/物流截图识别，不需要交出账号密码。

## 本地打开工程

项目使用 XcodeGen 管理工程：

```bash
brew install xcodegen
xcodegen generate
open ParcelKeeper.xcodeproj
```

最低系统版本为 iOS 17，Bundle ID 默认为：

```text
com.dinghao.ParcelKeeper
```
