# HANDOFF — OpenClash Visual Editor 交接

## Stopped here
本会话完成「项目记忆 + 开发骨架」：新建 AGENTS.md、docs/ARCHITECTURE.md、HANDOFF.md、scripts/release.sh，更新 .gitignore/.gitattributes。
当前分支 codex/qr-device-binding-test @ VERSION 2.3.0（与 origin/main 同点 8b87893），除两个未跟踪的 6115 诊断脚本外工作树干净。
开发机（Windows）：有 Node 24 / Git / Python，无 Ruby、Lua（相关检查在 scripts/release.sh 中自动跳过）；真机验证在 AX6000。

## Next
进入阶段 2（测试与验证体系）：跑通 node test_converter.js 与 scripts/release.sh check；在真机执行一次完整验收清单（安装 → 各协议导入 → 预览 → 应用 → 重启 → 槽位扫码绑定 → 换绑/解绑 → 恢复初始配置），把结果与命令固化进 AGENTS.md。

## Blocker
无。注意：正式发布（push origin/main + 镜像更新）需真机验收，本会话未做。

---

## 最近完成

- 2026-08-18：搭建项目记忆与骨架
  - 新建 AGENTS.md（定位/技术栈/命令/约定/禁用事项）
  - 新建 docs/ARCHITECTURE.md（模块图、7 条关键设计决策、两条数据流、路径表、测试体系、发布流程、待明确事项、阶段规划）
  - 新建 HANDOFF.md（本文件）
  - 新建 scripts/release.sh：check（语法检查 + 前端单测）与 pack/all（打发布 tar.gz），支持 CHANNEL 环境变量
  - .gitignore 增加 dist/；.gitattributes 增加 *.md text eol=lf
  - 本机验证：scripts/release.sh check 通过（node --check 全部 JS + node test_converter.js 通过）

- 项目既有状态（本会话调研结论，供参考）
  - 主开发线 2.3.0：QR/口令绑定 + 槽位 + captive portal（portal-watch.sh + procd + nft/iptables）
  - 旧分支 codex/manual-ip-version @ 1.6.3-manual.1（openclash-editor-manual worktree）为「手动绑定 IP 版」，已不活跃
  - 发布物历史：outputs/openclash-editor-1.6.2-manual.* 与 1.7.0-test.*.tar.gz；deploy_stage/2.3.0 为最新发布暂存
  - 固件集成：工作区根目录 launch_ax6000_110m_build.py（AX6000/immortalwrt-mt798x 构建，含 ruby/ruby-yaml/ruby-psych）
