# AGENTS.md — OpenClash Visual Editor

## 项目定位
OpenWrt LuCI 里的 OpenClash 配置可视化编辑器：批量导入订阅节点、自动生成设备分流规则、安全修改 OpenClash 当前 YAML 配置，并支持扫码/口令把设备绑定到固定 IP 槽位（含 captive portal 弹窗）。

## 技术栈
- 后端核心：Ruby + Psych 单文件 CLI（backend.rb，无第三方 gem，JSON 输出）
- LuCI 层：Lua 控制器（兼容 Lua 5.1 / 旧版 LuCI）+ HTML 模板视图（luci/）
- 前端：原生浏览器 JS（ES5、无框架、无构建，www/ 三个文件直接部署）
- 部署/更新/门户：POSIX sh + procd + hotplug + nftables/iptables
- 测试：Node（前端转换器单测）+ Ruby（后端单测，需在路由器或模拟环境）
- 版本与发布：VERSION 文件；发布物为 tar.gz（scripts/release.sh），经 GitHub raw + 自建镜像（yy.yaml.uk）分发

## 命令
- 本地检查（Windows 开发机可用）：sh scripts/release.sh check（Node 单测 + 可用解释器的语法检查）
- 打发布包：sh scripts/release.sh all [输出目录]（默认 ./dist，文件名 openclash-editor-<版本>-<通道>.<序号>.tar.gz）
- 前端单测：node test_converter.js
- 后端单测（路由器上，root）：ruby test_backend.rb /usr/share/openclash-editor/backend.rb
- 语法检查：ruby -c backend.rb、node --check www/*.js、luac -p luci/controller/openclash_editor.lua
- 真机部署：ssh 到路由器执行安装命令（见 README「一键安装」）

## 代码约定
- backend.rb 的所有 stdout 必须是单行 JSON；错误统一 {"ok":false,"error":...,"details":...}；禁止向 stdout 打印日志
- Lua 控制器只做 HTTP/参数校验/调度 ruby，禁止在 Lua 里改 YAML
- YAML 修改必须在原文行级替换（保留注释/顺序/未知字段），禁止整体 dump 重写
- 应用正式配置前必须经过「预览 + sha256 token + 备份 + 可回滚」流程（controller 已强制，勿绕过）
- 前端保持 ES5（var/function），无外部依赖；shell 全部 POSIX sh（set -eu），勿引入 bash 专属语法
- 新增运行时依赖需先在 AGENTS.md 登记并说明理由（目标环境只有 OpenClash 自带运行时）
- 用户可见文案用中文；VERSION 与发布产物、README 同步；提交信息沿用现有风格 type(scope): 描述
- 路径常量集中在 backend.rb 顶部；测试可用环境变量覆盖路径

## 禁用事项
- 禁止把订阅链接、节点明文、任何密钥/凭据提交进仓库（公开仓库）
- 禁止绕过 /tmp 预览 + token 校验直接写正式配置
- 禁止引入 gem/npm 运行时依赖；禁止提交 node_modules/、dist/、deploy_stage/、outputs/
- 禁止破坏 Lua 5.1 / 旧版 LuCI / uhttpd / nftables 兼容性；改动需在 README「依赖与适用范围」同步
- 未经真机验证不发布正式版（test 通道除外）
