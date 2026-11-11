# 后台快照与领取状态修复

同步快照包含历史运单。物流状态 signed、到站 arrived 和实际领取是不同字段，不能只靠物流状态或取件码是否存在决定待取件。

## 与原版安卓的对照

参照 zsdd2/kdyzm 提交 `d7e0e559b0b0d0f1c9699e1a9a49b789a9b79491`：

- `app-source/pickcode/core/pickcode-core.js` 的 importCompletion 读取 v1 pickupCompletion，手动 pending 优先于 autoPicked，实际 picked 与物流 status 独立。
- `src/pickup-completion.mjs` 将本人签收、用户领取及拼多多/淘宝的结构化出柜/取出证据保存成自动领取结果。安卓直接消费该结果。普通驿站或柜机签收并不自动代表用户取走。
- 修复前 iOS 虽解码 picked，却完全忽略其值；未解码 pickupCompletion，新增 PickupRecord 固定未完成，单票刷新也不更新该记录。文字补判还漏了“签收人凭取货码签收”。

## 当前行为

- 优先采用有效 v1 pickupCompletion，manualOverride=pending 阻止自动完成；manualOverride=picked 或 autoPicked=true 表示领取。有效的未领取决定不会被本地文字覆盖。
- 无 v1 状态的旧快照兼容 picked=true；其余仅从本次成功响应最新的有时间节点补判明确领取语句，包括“签收人凭取货码/取件码签收”。请求、预测、否定、代收和纠错语句不作为本人领取依据。
- 快照新建、更新及单票刷新共用领取判定；已确认领取同步将运单设为已签收、关联取件记录设为完成。旧版误留未完成的记录可通过再次同步修复；完成历史仍保存。
- 本机手动完成/恢复记录在可选 completionOverride 中，恢复未完成不会被后台同步覆盖，已完成也不会被后台自动撤销。旧备份仍可读取；旧版无法追溯手动恢复来源，升级后必要时再恢复一次。
- 本机取件操作不上传后台。备注、非空取件码、位置、分组、提醒继续保留；归档跳过，自动快照保留显式 UAPI/Tmini 渠道选择。已完成历史复用取件码不会阻止导入。
- 有效轨迹仍以本次响应为准，保留历史，不比较跨响应时间。重复快照不重写完成记录时间，单独修复完成状态也计入更新。刷新返回值仍只表示本次运单是否新变为已签收。

## 验证范围

KDYZMPickupRepairTests.swift 覆盖后台完成状态解码与优先级、淘宝凭码签收、新建/旧数据修复、无缓存领取、重复同步、手动恢复及备份兼容、代收与否定语句、取件码复用和单票刷新。

本次仅做源码及静态检查；按用户要求没有启动编译、XCTest、GitHub Actions 或 IPA 发布。新增 Swift 测试尚未执行。
