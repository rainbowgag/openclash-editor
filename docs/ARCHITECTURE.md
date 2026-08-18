# OpenClash Visual Editor — 架构说明

> 本文件是项目的长期设计文档。短期任务状态看 HANDOFF.md，开发规则看 AGENTS.md。

## 1. 定位与形态

在 OpenWrt 路由器的 LuCI 中提供 OpenClash 配置的可视化编辑器：

- 批量粘贴订阅节点链接（VLESS / VMess / Hysteria2 / Trojan / Trojan-Go / Shadowsocks / SOCKS5），浏览器端转成 Clash YAML 节点；
- 按「内网 IP → 节点」自动/手动生成设备分流规则（rules 里的 SRC-IP-CIDR 规则）；
- 通过「预览 → 校验 → 备份 → 应用 → 重启 OpenClash」的安全流程修改 OpenClash 当前使用的 YAML 配置；
- 额外提供「口令绑定」：为设备分配固定 IP 槽位，新设备扫码/输口令即绑定，portal 自动弹窗。

安装形态：纯脚本文件直接铺到路由器（无编译、无架构二进制），发布物是 tar.gz，经 GitHub raw 或自建镜像（yy.yaml.uk）分发。

## 2. 组件图

~~~mermaid
flowchart LR
  subgraph Browser["浏览器（LuCI 页面）"]
    V["luci/view/openclash_editor/*.htm 模板"] --> JS["www/converter.js + editor-common.js (ES5, 无构建)"]
  end
  JS -->|"POST 草稿 JSON"| C["luci/controller/openclash_editor.lua (Lua 5.1 兼容)"]
  C -->|"ruby backend.rb <cmd> <args>"| B["backend.rb (Ruby 单文件 CLI)"]
  B --> Y["OpenClash YAML 配置 (openclash.config.config_path)"]
  B --> S["状态文件 /etc/openclash/openclash-editor-*.json"]
  C -->|"启动/重启"| OC["/etc/init.d/openclash"]
  C -->|"nft/iptables 重定向 + probe 页面"| P["portal-watch.sh + procd init + hotplug"]
  P -->|"轮询 DHCP lease / Wi-Fi station"| S
~~~

## 3. 目录结构

| 路径 | 职责 |
|------|------|
| backend.rb | Ruby 后端：YAML 读取/行级修改/差异、节点转换、规则生成、槽位与 QR 逻辑、状态持久化。唯一直接改 YAML 的地方 |
| luci/controller/openclash_editor.lua | LuCI 控制器：注册菜单与约 25 个 JSON 接口、参数校验、调度后端、预览校验/应用/回滚/重启 |
| luci/view/openclash_editor/{nodes,rules,slots}.htm | 三个 LuCI 模板页：节点管理、设备规则与应用、口令绑定 |
| www/converter.js | 浏览器端节点链接解析/转换（各协议 → Clash 节点对象） |
| www/editor-common.js | 共享工具：草稿存储（localStorage）、fetch 封装、IP/CIDR 计算、表格渲染 |
| www/editor.css | 页面样式 |
| portal-watch.sh | 门户服务主体：probe 文件、hosts/bind.lan、uhttpd/nginx 接管、nft/iptables 重定向、轮询未绑定设备 |
| openclash-editor-portal.init / .hotplug | procd 服务与 lan 接口 hotplug 触发器 |
| install.sh / mirror-install.sh / uninstall.sh / update.sh | 安装、镜像安装、卸载、版本检查与在线更新 |
| deploy/install-selector.sh | 镜像入口：让用户选择「口令绑定版(scan) / 手动绑定 IP 版(manual-ip)」后拉取对应通道安装脚本 |
| deploy/yy.yaml.uk-openclash-editor.conf | 镜像服务器 nginx 站点配置（http 80 + https 9443） |
| test_*.rb / test_*.js / test_*.sh | 后端/前端/门户的测试脚本（详见 §7） |
| docs/、scripts/release.sh、AGENTS.md、HANDOFF.md | 项目记忆与开发工具 |

## 4. 关键设计决策

1. **Ruby 后端是 YAML 的唯一修改者**。Lua 控制器只做 HTTP 入口、参数校验与进程调度；所有 YAML 读写、差异、状态都在 backend.rb。理由：Ruby+Psych 是 OpenClash 已依赖的运行时；JSON 化的 CLI 让后端可独立测试、可被任意前端调用。
2. **文本级 YAML 手术，而非重新 dump**。backend.rb 通过 replace_nodes / replace_device_rules / replace_anchor_names 在原文行级替换，保留用户 YAML 的注释、字段顺序与未知字段。这是本项目最重要的正确性约束。
3. **预览-应用两阶段 + sha256 token**。apply 必须携带与预览文件哈希一致的 token，防止旧预览被误应用、防止 OpenClash 配置路径切换后误写。
4. **先备份后替换 + 失败回滚**。应用前 cp -p 生成时间戳备份（.editor-backup-时间戳）；任一环节失败（含槽位落盘失败）都会恢复原文件并告知备份位置。
5. **纯脚本、零架构依赖**。无编译产物；前端 ES5、后端仅标准库、shell 全部 POSIX；对 Lua 5.1 / 旧版 LuCI / uhttpd / nginx / nft / iptables 均有兼容层或双实现。
6. **槽位状态独立持久化**。/etc/openclash/openclash-editor-slots.json 与主状态分离，portal 只读它，避免与用户 OpenClash 配置耦合；测试可用环境变量覆盖所有路径。
7. **门户修改全部可逆**。portal-watch.sh setup/cleanup 幂等，对 uhttpd index、nginx locations、hosts、probe 文件、防火墙规则的所有改动都有备份与恢复路径。
8. **内置直连槽位永久存在**。口令 000 的直连槽位（固定当前 LAN 网段 .254、规则 DIRECT）由 read_slots 自动并入、reset 后重建，预览/修复/绑定各路径特判放行；前端禁止其删除、改口令与改节点。相关常量集中在 backend.rb 顶部（DIRECT_SLOT_ID / DIRECT_SLOT_CODE / DIRECT_NODE）。

## 5. 主要数据流

### 流程 A：节点导入 → 预览 → 应用

1. 浏览器粘贴链接，converter.js 转成节点对象，保存在 localStorage 草稿（key: openclash-editor-draft-v3）；
2. 用户编辑规则/勾选「路由器代理节点」后点预览，POST 草稿 JSON 到 visual-editor-preview；
3. 控制器校验大小/JSON，写 /tmp/openclash-editor-request.json，执行 ruby backend.rb preview <file>；
4. 后端读取 OpenClash 当前 YAML，行级替换 anchors/nodes/rules，写 /tmp/openclash-editor-preview.yaml，返回差异摘要与数量统计；
5. 控制器用 ruby -ryaml 再校验预览文件可解析，sha256sum 预览文件得到 token 并返回 {token, preview, diff}；
6. 用户确认后 POST visual-editor-apply（带 token）；
7. 控制器核对 token 与预览文件哈希一致 → 备份正式配置 → 替换 → slots-apply-pending 落盘槽位 → 失败回滚 → 后台延迟重启 OpenClash。

### 流程 B：口令绑定（portal）

1. 管理页为节点创建槽位（固定 IP、口令、目标节点、MAC 可选）：slots-create / slots-plan；
2. portal-watch.sh 每 3 秒轮询 DHCP lease 与 Wi-Fi station，找出「未绑定」的 MAC，写入 nft/iptables，把该设备的 80 端口流量重定向到 /cgi-bin/luci/oec；
3. 新设备连网 → 探针请求被重定向 → 弹窗显示口令输入页（bind.lan / oec / oeb 入口）；
4. 输入口令 POST → slot-code-bind：校验口令 → 绑定 MAC/IP/节点 → 更新槽位状态与设备规则 → 触发 dnsmasq 重载/OpenClash 重启；
5. 换绑：管理员在页面点「允许换绑」开 10 分钟窗口，新设备可直接替换原 MAC。

## 6. 关键路径与状态文件

| 路径 | 用途 |
|------|------|
| /etc/openclash/config/config.yaml（或 uci openclash.config.config_path） | OpenClash 正式配置 |
| /tmp/openclash-editor-preview.yaml | 预览产物（唯一被允许写入的「正式」副本） |
| /tmp/openclash-editor-request.json | 预览请求草稿 |
| /tmp/openclash-editor-preview.sha256 | 预览 token（apply 时校验） |
| /etc/openclash/openclash-editor-state.json | 节点/规则/网络状态（编辑器主状态） |
| /etc/openclash/openclash-editor-slots.json | 槽位状态（绑定 MAC/IP/口令/节点） |
| /usr/share/openclash-editor/ | 安装目录：backend.rb、update.sh、VERSION、portal-watch.sh、EDITION、SOURCE_URL 等 |
| /etc/init.d/openclash-editor-portal、/etc/hotplug.d/iface/99-openclash-editor-portal | portal 服务与 lan hotplug |
| /tmp/openclash-editor-qr/ | QR token（10 分钟 TTL） |

## 7. 测试体系

- 本机（Windows 开发机，有 Node）：sh scripts/release.sh check → node --check www/*.js + node test_converter.js（协议转换回归）；
- 路由器 / 带 OpenClash 的 Linux（root）：ruby test_backend.rb /usr/share/openclash-editor/backend.rb，可用 TEST_NETWORK_CIDR / TEST_START_IP / OPENCLASH_CONFIG_PATH 等环境变量覆盖；test_reset.rb、test_slots.rb、test_network.rb 等按需执行；
- 真机验收清单（发布前）：安装 → 导入各协议节点 → 预览差异 → 应用 → OpenClash 重启 → 建槽位 → 扫码绑定 → 换绑/解绑 → 恢复初始配置。

## 8. 发布流程（现状，待固化）

1. 更新 VERSION、README（如需）、luci 视图里的 ?v= 缓存号；
2. sh scripts/release.sh all（check → 打包 tar.gz）；
3. 上传镜像服务器 /www/wwwroot/openclash-editor/<channel>/（channel：scan / manual-ip），更新 SHA256SUMS；
4. push origin/main，GitHub raw 自动生效；
5. （可选）固件集成：launch_ax6000_110m_build.py 把插件 tar 拷入 AX6000 构建机，随固件发布。

## 9. 🔴 待明确事项（后续必须先定）

1. **分支/发布策略**：当前 main 与 codex/qr-device-binding-test 同点；feature 分支如何并入 main、发布是否必须从 main、由谁 push。
2. **镜像布局与发布自动化**：yy.yaml.uk 上 channel 目录的准确布局、SHA256SUMS 更新方式、是否脚本化一键上传。
3. **版本规则**：版本号递增规则（2.3.0 → 2.4.0?）、test/manual 通道与正式版关系；luci/view 里 ?v=2.2.9 这类缓存号必须与 VERSION 同步（目前滞后）。
4. **测试环境**：是否搭建无真机的模拟环境（伪 OpenClash 配置 + stub uci/dhcp），还是继续以真机为主。
5. **固件集成归属**：launch_ax6000_110m_build.py 目前在工作区根目录、未入库；是否纳入本仓库维护。
6. **兼容性边界**：明确支持的最低 OpenWrt / LuCI 版本（代码里已有大量 legacy 兼容层，需要显式声明测试范围）。

## 10. 阶段规划（多会话路线）

- **阶段 1 ✅（本会话）**：项目记忆（AGENTS/ARCHITECTURE/HANDOFF）+ 开发骨架 + scripts/release.sh。
- **阶段 2**：测试与验证体系——整理全部 test_*.rb/js 的执行方式，补齐缺失覆盖，固化真机验收清单到脚本/文档。
- **阶段 3**：发布流程固化——明确镜像布局、SHA256SUMS、分支与版本规则，落地为脚本与 check-list。
- **阶段 4**：功能迭代——一次会话一个功能（候选：新协议支持、槽位/QR 增强、UI/UX、性能），每个功能独立会话并更新 HANDOFF。
- **阶段 5**：固件集成流程——把 AX6000 固件构建中的插件打包步骤搬进仓库脚本，与 release.sh 打通。
