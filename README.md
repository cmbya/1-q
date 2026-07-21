# 快递管家（ParcelKeeper）

一个只给自己用的 iPhone 快递记录 App。核心操作是：**复制运单号 → 打开 App → 点击系统粘贴按钮 → 确认并保存**。

## 已完成

- 使用 SwiftUI 编写的原生 iPhone App
- 使用系统 `PasteButton` 读取用户主动粘贴的文字
- 从整段短信或聊天内容中提取运单号
- 自动识别顺丰、京东、圆通、极兔、EMS，并对中通、申通、韵达、德邦做规则判断
- 快递公司识别不确定时允许手动修改
- 本地保存、搜索、删除、归档及重复运单拦截
- 运输中、派送中、待取件、已签收、异常等状态管理
- 备注与取件码
- 本地定时提醒
- JSON 备份导出与导入
- GitHub Actions 自动生成 Xcode 工程并编译无签名 IPA

## 在 GitHub 编译

1. 新建一个 GitHub 仓库。
2. 将本压缩包里的所有文件上传到仓库根目录，注意 `.github/workflows/build.yml` 不能漏掉。
3. 打开仓库的 **Actions** 页面。
4. 选择 **Build Unsigned IPA**。
5. 点击 **Run workflow**。
6. 编译完成后，在本次运行页面底部下载 `ParcelKeeper-unsigned` 构建产物。

构建产物中的 IPA 是**无签名版本**，需要使用你自己的 Apple 签名方式重新签名后安装到 iPhone。这样做可以避免把证书和密码写进公开仓库。

## 本地打开工程

项目使用 XcodeGen 管理工程文件：

```bash
brew install xcodegen
xcodegen generate
open ParcelKeeper.xcodeproj
```

项目最低系统版本为 iOS 17，产品显示名称为“快递管家”，默认 Bundle ID 为：

```text
com.dinghao.ParcelKeeper
```

要安装到自己的设备时，可以在 Xcode 中把 Bundle ID 改成你自己的唯一标识，并选择自己的 Team。

## 关于实时物流查询

这一版先把最重要的录入、保存和提醒做稳定。实时物流轨迹并不是 iPhone 系统自带的数据，需要接入第三方快递查询 API，并配置对应账号或密钥。当前界面不会伪造物流信息；后续接入 API 时，可以在现有数据模型上增加轨迹时间线和后台更新。

## 目录

```text
ParcelKeeper/
├── .github/workflows/build.yml
├── project.yml
├── README.md
└── ParcelKeeper/
    ├── App/
    ├── Models/
    ├── Services/
    ├── Views/
    └── Resources/
```
