# 构建等待优化（本地实现，尚未实测）

保留 macos-15-intel / Xcode16.4 和原 Release 优化设置，不新增编译缓存或 ARM runner。

- test 与 build 无依赖并行，publish 同时依赖两者且明确要求 success。测试失败、取消、跳过或编译失败均不能发布。
- 测试固定创建 iPhone16 / iOS18.5，先 boot，再安装XcodeGen及 build-for-testing；之后 bootstatus 确认就绪，再用相同 destination/DerivedData 执行完整 test-without-building。
- 明确关闭测试并行以使用预热设备，避免克隆冷启动；不删减任何测试。此设置是否影响用例耗时需CI对照，不保证提速。
- 编译、等待就绪、测试执行独立步骤计时；编译输出 showBuildTimingSummary。即使测试失败仍上传日志和可用xcresult。
- Release独立生成IPA并验证，附源码SHA、版本和三文件SHA256清单。发布任务只下载本次运行的artifact，先校验校验和及源码SHA、再复验IPA，不重新编译。
- artifact所有路径统一在build/下，防止上传时最小公共祖先导致下载后层级变化。公开Release仍只附IPA与仅IPA的SHA256清单。
- build_only=true跳过测试且仅保留构建artifact；widget_diagnostics=true仍运行测试但不发布。仅main/master正常模式能发布。

## 验证与待验收

新增 test_build_workflow_contract.py：YAML结构、依赖/权限/发布条件、完整测试命令、设备与构建目录、产物身份验证及全部shell块 bash -n。属于离线契约，不是GitHub表达式执行器或Xcode测试。

本轮未提交推送、未触发Actions。尚需在获授权构建中确认固定runtime存在、预热设备确被测试使用、测试总数/结果、真实发布失败门禁、跨任务产物和总体耗时；测试与Release并行可能多占用runner，排队会影响收益。不能根据静态结果宣称已缩短几分钟。
