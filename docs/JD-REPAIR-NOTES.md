# 京东／商城审查修复证据

## 范围与限制

- 基线：`15600c25ff68d84956153e02b378486bdf64805d`。
- 本分工只修改京东／商城服务、`MallImportView`、对应测试和 `scripts/test_jd*`；未修改 `TrackingRefreshService.swift`，其代次落库集成由并行分工完成。
- 没有进行真实账号请求、登录、短信、付费调用、提交、推送或构建。环境检查未找到 `swift` / `xcodebuild`。
- 日常 Skill 目录没有列出 TDD／systematic-debugging Skill，未越级读取；实际采用先失败回归再实现的验证顺序。

## 已修问题

### 1. 物流详情 DOM 的归属不可信

旧实现从整页 `innerText` 提取时间节点：当前订单号和一个运单号，加上“猜你喜欢”内不带第二运单号的较新签收节点，会被组合为同一包裹。

没有可信页面物流容器的证据，因此没有猜测 CSS，也没有增加推荐词黑名单充当归属证明。京东物流详情的整页 DOM 兜底现为 `recognized:false`；官方网页触发的结构化物流响应仍可使用。若页面只提供无法归属的 DOM，将返回不支持而非更新错误轨迹。订单列表 DOM 和页面安全验证识别未取消。

新增 Node fixture 执行从 Swift 原文提取的生产 JS，覆盖：整页伪正常详情拒绝、推荐签收污染拒绝、不同订单拒绝、结构化正常响应接受、拆包各自轨迹。

### 2. PC 结构化备用与无号响应

JS 支持 `trackGroupInfo.orderCarriageInfo` 备用字段，与 Swift PC 解析器保持一致。无号包裹不冒充真实运单；全部无号时不发送已识别的物流响应，继续等待后续结构化响应／快照。没有恢复不可信 DOM 扫描。

### 3. Cookie 轮换与显式保存

- `JDPCClient.verifySession()` 返回实际验证后的 Cookie 快照；UI 保存 `fresh` 而非原始粘贴值。
- 验证本身不偷偷写已保存会话，避免用户取消后会话已被替换。
- 订单读取／查询完成后，对现有保存会话执行 `saveRotated(_:replacing:expectedGeneration:)`，在同一锁内核对显式代次及原 Cookie 快照，才写入轮换值并回读验证。
- 旧请求不能覆盖新登录、注销或另一请求已保存的新轮换。轮换值不进入日志。
- 保留原来的 Keychain 裸 Cookie 数组 JSON；未加入新外层格式或多账户设计。

### 4. 会话代次与原子业务提交

可供刷新服务调用的接口：

```swift
MallSession.generation(for: platform) -> UUID
MallSession.withGeneration(platform: platform, expected: generation) {
    // 同步业务提交；不允许 await
}
```

平台代次是静态共享的，并由 `NSRecursiveLock` 保护。读取、显式保存／清理、轮换比较保存及原子业务提交共用该锁；不跨 `await`。

- 显式保存／清理写入成功，或写入／回读失败而无法确认实际状态，均推进该平台代次。
- 校验未通过、过时代次被拒绝，没有发生写入，不推进代次。
- 成功轮换不推进显式代次；轮换写入发生不确定失败则推进代次。
- 查询返回前检查代次；订单预览记住来源代次；确认导入在锁内检查并写业务记录。浏览器登录和 Cookie 保存同样检查原代次。
- 清理旧网页数据只操作已分离的旧上下文，避免 `await` 返回后清掉刚建立的新登录上下文。
- PDD 只接入通用会话代次保护，未重做其协议。

### 5. 登录上下文和诊断并发

官方移动网页登录继续使用新的非持久上下文，不注入旧 PC Cookie；验证固定走该移动上下文。移动入口不发布 `thor`，避免随后误选 PC 连接器。

`JDDiagnostics` 的 `ended` 和 `eventCounts` 原先无锁；现将 begin/event/finish/fail 的检查、计数及终止提交放入同一锁，终止后不能重新开启阶段。

## TDD 与本地结果

先新增回归、未修改实现时：

- `node --test scripts/test_jd_review_repairs_js.mjs`：7 例，6 失败、1 通过；直接复现整页污染、嵌套备用缺失、空号提前响应。
- `python3 scripts/test_jd_review_repairs_contract.py`：5 例全部失败；属于源码契约失败，不是 Swift 原生行为验证。

修复后定向验证：

- `node --test scripts/test_jd_review_repairs_js.mjs`：7/7 通过，执行实际嵌入 JS。
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_jd*contract.py' -v`：24/24 通过，包含既有 JS fetch/XHR、身份约束、秘密过滤与固定诊断标签检查。
- `git diff --check`：通过。

新增但未执行的 XCTest：Cookie 响应轮换返回、嵌套承运信息、显式 save/clear 代次、已写后抛错／回读不一致、轮换比较保存不覆盖新登录／注销、旧 JSON 读取、并发清理与原子提交互斥、诊断事件洪泛与竞争终止。Linux 无 Apple 工具链，以上 Swift 文件未编译，Keychain／WebKit／Swift 并发原生行为仍需用户后续授权在 Apple 环境验证；本次没有启动构建。
