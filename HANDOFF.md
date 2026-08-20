# HANDOFF — OpenClash Visual Editor 交接

## Stopped here
真机验证已完成（Kwrt / mediatek filogic，root@192.168.100.1，Ruby 3.4.9）。

- ruby test_slots.rb 与 test_reset.rb 均通过；修正测试断言：直连规则需带 /32、rules: 定位与缩进，绑定/改节点用例改为选取用户槽位而非排在最前的直连槽位。
- 真机安装后：slots 自动出现永久直连槽位（000 / 192.168.100.254 / DIRECT / permanent=true）；slots-repair 后在 /etc/openclash/config/config.yaml 顶部写入 SRC-IP-CIDR,192.168.100.254/32,DIRECT，rule_ok=true。
- 模拟口令 000 绑定（临时租约 02:11:22:33:44:55 @ 192.168.100.100）成功：uci 生成 dhcp.oce_slot_000000000001.ip=192.168.100.254，槽位 locked=true；解绑清理正常。
- 对直连槽位执行删除 / 改口令 / 改节点均返回“不能删除 / 不能修改”；reset 单测验证直连槽位与 DIRECT 规则保留。
- 当前分支 codex/qr-device-binding-test @ VERSION 2.3.0；正式发布前建议再做一次真实手机端到端验收。

## Next
- 发布 test/正式版（scripts/release.sh all，并同步 README 依赖与版本说明）。
- 真实手机连 Wi-Fi 输入 000 做一次端到端人工验收。

## Blocker
无阻塞。
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
