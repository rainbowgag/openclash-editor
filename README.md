# OpenClash Visual Editor

一个运行在 OpenWrt LuCI 中的 OpenClash 配置可视化编辑器，用于批量导入节点、生成设备分流规则并安全地修改 OpenClash 当前选用的 YAML 配置。

## 功能

- 批量转换 VLESS、VMess、Hysteria2/Hy2、Trojan/Trojan-Go 和 SOCKS5 节点
- 可按“名称前缀 + 起始数”批量重命名本次转换的节点
- SOCKS5 支持 `IP:端口:用户名:密码`、`socks5://用户名:密码@IP:端口`、`用户名:密码@IP:端口`、`socks://Base64(用户名:密码)@IP:端口#节点名`
- 支持 VLESS Reality、TLS、WS、gRPC，以及 VMess HTTP 伪装传输
- 支持 Trojan/Trojan-Go 的 TCP、WS、gRPC、SNI、ALPN 与跳过证书校验参数
- 可选写入 `dialer-proxy: 中转`
- UI 将 `pr.proxies` 显示为“路由器代理节点”；列表为空时默认把新导入的首个节点加入其中
- 扫码版添加节点时不自动生成设备规则，设备规则由扫码绑定产生
- 自动检测 OpenWrt LAN 地址和 CIDR，并生成对应网段的设备规则
- 支持手动覆盖规则网段和自动分配起始 IP
- 手动输入内网 IP 和节点名称补充规则
- 批量生成设备规则时支持一键全选或取消全部节点
- 检查重复内网 IP、重复节点名称和无效节点引用
- 读取并折叠显示已经应用的节点和规则
- 节点列表支持按名称即时搜索，规则列表支持按节点名称或内网 IP 即时搜索
- 节点和设备规则列表支持多选、按当前搜索结果一键全选与批量删除
- 批量删除节点时自动清理所有关联设备规则，批量删除规则不会删除节点
- 节点管理、设备规则与预览应用、扫码绑定分为三个独立页面
- 可修改已添加节点的名称，并同步修改所有关联规则
- 删除节点时删除关联规则，或手动输入替代节点迁移规则
- 手动修改每条规则的目标节点
- 修改规则成功后弹出明确提示
- 删除规则前二次确认
- 删除规则后自动复用释放的最小内网 IP
- 扫码版转换节点时默认为每个新增节点自动排队创建一个扫码槽位，并与节点、规则一起预览和应用
- 每条设备规则都会自动对应一个扫码槽位；已有规则缺少槽位时，进入扫码绑定页面会自动补齐
- 扫码绑定页面支持选择当前节点并重复创建整组槽位，也保留按单节点和指定数量手动创建
- 每个扫码槽位预先绑定固定 IP、代理节点和永久二维码
- 二维码按整数像素原始尺寸清晰渲染，避免浏览器缩放抗锯齿导致手机相机无法识别
- 首次绑定后槽位自动锁定；不同手机必须由管理员开放一次10分钟换绑授权，成功或超时后自动重新锁定
- 手机刷机或更换后扫描原槽位二维码，会用新 MAC 替换旧 MAC 并继续使用原固定 IP 和代理规则，无需手动清理旧手机
- 槽位绑定时会精准释放该手机的旧 DHCP 动态租约并重启 DHCP 服务，避免重连后仍获取旧 IP
- 管理员允许换绑后，会强制回收槽位 IP 上的旧租约和新手机原来的动态租约，即使旧手机因私有地址变化导致 MAC 与历史记录不一致
- 已绑定设备如仍显示旧 IP，可在槽位列表点击“刷新 IP 租约”修复；不会删除其他设备的 DHCP 租约
- 兼容会在 DHCP 服务重启时输出日志的 x86/OpenWrt 固件，后端响应可从服务日志中提取最终 JSON
- 扫码槽位支持搜索、查看在线状态、修改代理节点、重置泄露的永久二维码、多选、全选和批量删除
- 节点改名会同步更新槽位和规则；删除节点会迁移或删除关联槽位，防止无效引用
- 一键恢复到无节点、无设备规则的初始配置（自动备份）
- 自动检测 GitHub 新版本并在页面中一键更新
- 先生成 `/tmp` 测试副本并显示差异，再备份和应用正式配置
- 配置差异由 Ruby 后端直接生成，不依赖固件是否预装 `diff`/`diffutils`
- 预览确认并应用正式配置后自动重启 OpenClash；扫码绑定是否立即重启由用户选择，默认不勾选

## 一键安装

### 统一选择安装（推荐）

执行下面一条命令后，输入 `1` 安装扫码绑定版，输入 `2` 安装手动绑定 IP 版：

```sh
rm -f /tmp/openclash-editor-install.sh; (curl -fL --resolve yy.yaml.uk:9443:103.27.78.68 --connect-timeout 20 --max-time 120 --retry 2 --show-error -o /tmp/openclash-editor-install.sh 'https://yy.yaml.uk:9443/openclash-editor/install.sh' || curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error -o /tmp/openclash-editor-install.sh 'http://103.27.78.68/openclash-editor/install.sh') && sh /tmp/openclash-editor-install.sh
```

### 扫码绑定正式版

下面的命令直接安装扫码绑定正式版。`--resolve` 可在路由器本地 DNS 暂时不可用时仍然校验证书并下载，安装后的在线更新也会记住该解析地址：

```sh
rm -f /tmp/openclash-editor-scan.sh; BASE_URL='https://yy.yaml.uk:9443/openclash-editor/scan'; (curl -fL --resolve yy.yaml.uk:9443:103.27.78.68 --connect-timeout 20 --max-time 120 --retry 2 --show-error -o /tmp/openclash-editor-scan.sh "${BASE_URL}/install.sh" || { BASE_URL='http://103.27.78.68/openclash-editor/scan'; curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error -o /tmp/openclash-editor-scan.sh "${BASE_URL}/install.sh"; }) && OPENCLASH_EDITOR_BASE_URL="$BASE_URL" OPENCLASH_EDITOR_RESOLVE_IP='103.27.78.68' sh /tmp/openclash-editor-scan.sh
```

### 中国大陆镜像（推荐）

通过 VPS 镜像安装，安装完成后插件的版本检查和在线更新也会继续使用该镜像：

```sh
curl -fL --connect-timeout 20 -o /tmp/openclash-editor-install.sh https://yy.yaml.uk:9443/openclash-editor/install.sh && sh /tmp/openclash-editor-install.sh
```

如果固件没有 `curl`：

```sh
wget -T 20 -O /tmp/openclash-editor-install.sh https://yy.yaml.uk:9443/openclash-editor/install.sh && sh /tmp/openclash-editor-install.sh
```

安装器会优先使用 HTTPS，并依次尝试 `curl`、`wget`、`uclient-fetch`；如果旧版 OpenWrt 的 TLS 库不兼容或当地网络阻断 9443 端口，会自动回退到 HTTP 80 兼容通道。

镜像同时提供 `SHA256SUMS` 文件，可用于核对发布文件完整性。

### GitHub 源

通过 SSH 登录 OpenWrt 后，以 `root` 身份执行：

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/rainbowgag/openclash-editor/main/install.sh)"
```

如果固件没有 `wget`，可以使用：

```sh
sh -c "$(uclient-fetch -qO- https://raw.githubusercontent.com/rainbowgag/openclash-editor/main/install.sh)"
```

安装完成后刷新 LuCI，打开：

```text
服务 -> OpenClash -> Visual Editor
```

也可以直接访问：

```text
http://路由器IP/cgi-bin/luci/admin/services/openclash/visual-editor
```

## 更新

节点管理页面会自动检查版本，发现新版本时显示“立即更新”按钮。也可以重新执行安装命令覆盖更新插件文件。更新不会修改正式 OpenClash 配置、编辑器状态和自动备份。

## 一键卸载

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/rainbowgag/openclash-editor/main/uninstall.sh)"
```

卸载脚本只删除插件文件，保留 OpenClash 配置、编辑器状态和历史备份。

## 依赖与适用范围

- 已安装并选择 OpenClash YAML 配置；插件会从 `openclash.config.config_path` 自动识别实际文件路径和自定义文件名
- 带 Lua 兼容层的 LuCI
- Ruby、Ruby YAML 和 Psych（OpenClash 通常已经安装）
- LuCI 本地二维码组件 `libluci-uqr`（安装器会在缺失时给出安装提示）
- 纯 Lua、Ruby、Shell 和浏览器 JavaScript 实现，不包含 CPU 架构相关二进制；支持 x86_64 与 ARM，已在 aarch64/ARMv8 上实机验证
- 默认通过 `ubus network.interface.lan` 检测网段，失败时回退到 UCI
- 支持 `/1` 至 `/30` IPv4 网段，并自动跳过路由器自身地址和重复规则 IP

## 安全机制

预览只写入：

```text
/tmp/openclash-editor-preview.yaml
```

点击应用时会再次校验 YAML，并在下面的目录创建带时间戳的隐藏备份：

```text
当前配置所在目录/.配置文件名.editor-backup-YYYYMMDD-HHMMSS
```

“恢复初始配置”也会先创建 `.配置文件名.before-reset-YYYYMMDD-HHMMSS` 备份；它只清空节点、`pr.proxies` 名称和 `SRC-IP-CIDR` 设备规则，保留其他 OpenClash 配置与基础规则。

应用正式配置后会延迟启动 OpenClash 后台重启任务，使新规则生效并确保页面先收到成功响应。

扫码槽位的创建、修改和删除会在正式配置旁创建 `.配置文件名.qr-backup-YYYYMMDD-HHMMSS` 备份。二维码入口只接受当前 LAN 网段的访问。

扫码槽位数据保存在 `/etc/openclash/openclash-editor-slots.json`（权限 `600`）。创建槽位时会预写规则；手机重新扫码换绑通常只修改 DHCP 的 MAC，不重复改写 YAML。永久二维码应妥善保管，泄露后可在扫码绑定页面重置。卸载插件时会保留槽位数据、DHCP 固定租约和正式配置，避免卸载操作意外影响现有设备网络。

## 许可证

[MIT](LICENSE)
