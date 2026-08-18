# HANDOFF — OpenClash Visual Editor 交接

## Stopped here
本会话实现「内置直连槽位」：口令 000 的永久直连槽位（固定当前 LAN 网段 .254、规则 DIRECT），reset 后仍存在，前端锁定不可删除/改口令/改节点。
当前分支 codex/qr-device-binding-test @ VERSION 2.3.0（与 origin/main 同点 8b87893），除两个未跟踪的 6115 诊断脚本外工作树干净。
改动：backend.rb（直连槽位常量/自动并入/reset 重建/各路径特判）、slots.htm（永久槽位展示与锁定）、rules.htm（DIRECT 规则只读保护）、editor-common.js（.254 不参与自动分配）、test_slots.rb / test_reset.rb 适配。
开发机（Windows）：有 Node 24 / Git / Python，无 Ruby、Lua；JS/视图语法检查与 node test_converter.js 已通过。

## Next
真机验证（AX6000，root）：先跑 ruby test_slots.rb 与 ruby test_reset.rb（/tmp 路径，不动正式配置），再安装后人工验收：口令 000 绑定设备 → 设备拿到网段 .254 且直连；001+ 槽位正常；删除/改口令/改节点对直连槽位报错；恢复初始配置后直连槽位与 DIRECT 规则仍在。

## Blocker
本机无 Ruby，Ruby 单测与语法检查未在本机执行（已在 backend.rb 用静态复核）；真机验收必须在下个会话完成后再考虑发布。

---

## 最近完成

- 2026-08-19：内置直连槽位（口令 000）
  - backend.rb：新增 DIRECT_SLOT_ID=000000000001 / CODE=000 / NODE=DIRECT；read_slots 自动并入直连槽位并持久化；direct_slot_ip 计算当前网段 .254（自动避开网关并夹取到网段内）；reset 后重建槽位与 DIRECT 规则；slot_code! 放行 000；apply/repair/bind/preview/normalize 各路径对 DIRECT 特判；删除/改口令/改节点对直连槽位拒绝；分配 IP 时保留 .254
  - slots.htm：直连槽位置顶、显示「直连槽位 · 固定直连」徽标、无勾选/改口令/改节点/删除按钮，仅保留复制口令与解绑；页面文案说明 000 用法
  - rules.htm：DIRECT 规则只读展示（不可修改/删除/批量选择）；手动添加规则与自动分配均避开直连槽位 IP
  - editor-common.js：recalculateNextIp 把槽位 IP 计入已占用（含直连槽位 .254）
  - test_slots.rb / test_reset.rb：适配直连槽位计数并新增保护断言
  - 视图/JS 语法检查（node --check 提取脚本）全部通过；后端为静态复核，待真机跑单测

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
