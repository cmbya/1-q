# 日志链路修复（本地，未提交）

- `syncKDYZM` 在前置检查前记录开始，成功或失败只记录一次终止；读取、凭据、快照、关联、lease、事务保存、展示使用固定 stage。
- `TrackingRefreshService` 外层包住取消、初始 snapshot、lease、身份/状态校验；后台使用传入的同一 operation，日志只保存随机 alias。
- 后台新建、续查、轮询、快照、合并、保存阶段有开始/结束或失败。终态快照失败保留 typed 原 reason/stage，cleanup 独立 reason，清理失败不再声称已清除。身份和 generation 检查保持。
- quota、rateLimited、network、authentication、noTrace、parse、accounting、configuration、storage、busy 分开；事件时间倒退与查询时间倒退分别为 olderEvent / olderQuery。
- schema=1 增加 optional stage，原 schema=1 无 stage 可读；原有 500 条/512 KiB 上限、alias 映射上限、保护写入、备份排除、白名单不变。
- KDYZM 最新同时间节点逐条交给 `recipientCollected(events:)`，不拼接独立节点造成条件范围串扰。

验证范围：Linux 仅执行 Python 源码契约；`DiagnosticChainTests.swift` 为真实 XCTest，需 macOS/Xcode 执行，未在本机编译或运行。没有调用真实服务、提交、推送或触发 CI。网络前后阶段采用父 service 最小切分，没有改变后端协议及 UAPI/Tmini 客户端。
