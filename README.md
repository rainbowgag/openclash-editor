# OpenClash Visual Editor

一个运行在 OpenWrt LuCI 中的 OpenClash 配置可视化编辑器，用于批量导入节点、生成设备分流规则并安全地修改 `/etc/openclash/config/config.yaml`。

## 功能

- 批量转换 VLESS、VMess、Hysteria2/Hy2 和 SOCKS5 节点
- 可按“名称前缀 + 起始数”批量重命名本次转换的节点
- SOCKS5 支持 `IP:端口:用户名:密码`、`socks5://用户名:密码@IP:端口`、`用户名:密码@IP:端口`
- 支持 VLESS Reality、TLS、WS、gRPC，以及 VMess HTTP 伪装传输
- 可选写入 `dialer-proxy: 中转`
- UI 将 `pr.proxies` 显示为“路由器代理节点”；列表为空时默认把新导入的首个节点加入其中
- 默认自动为新节点匹配设备规则，也可取消勾选只添加节点
- 自动检测 OpenWrt LAN 地址和 CIDR，并生成对应网段的设备规则
- 支持手动覆盖规则网段和自动分配起始 IP
- 手动输入内网 IP 和节点名称补充规则
- 批量生成设备规则时支持一键全选或取消全部节点
- 检查重复内网 IP、重复节点名称和无效节点引用
- 读取并折叠显示已经应用的节点和规则
- 节点列表支持按名称即时搜索，规则列表支持按节点名称或内网 IP 即时搜索
- 节点管理、设备规则与预览应用分为两个独立页面
- 可修改已添加节点的名称，并同步修改所有关联规则
- 删除节点时删除关联规则，或手动输入替代节点迁移规则
- 手动修改每条规则的目标节点
- 修改规则成功后弹出明确提示
- 删除规则前二次确认
- 删除规则后自动复用释放的最小内网 IP
- 一键恢复到无节点、无设备规则的初始配置（自动备份）
- 自动检测 GitHub 新版本并在页面中一键更新
- 先生成 `/tmp` 测试副本并显示差异，再备份和应用正式配置
- 配置差异由 Ruby 后端直接生成，不依赖固件是否预装 `diff`/`diffutils`
- 不自动重启 OpenClash

## 一键安装

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

- 已安装 OpenClash，并存在 `/etc/openclash/config/config.yaml`
- 带 Lua 兼容层的 LuCI
- Ruby、Ruby YAML 和 Psych（OpenClash 通常已经安装）
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
/etc/openclash/config/.config.yaml.editor-backup-YYYYMMDD-HHMMSS
```

“恢复初始配置”也会先创建 `.config.yaml.before-reset-YYYYMMDD-HHMMSS` 备份；它只清空节点、`pr.proxies` 名称和 `SRC-IP-CIDR` 设备规则，保留其他 OpenClash 配置与基础规则。

应用后不会自动重启 OpenClash，避免未经确认中断当前网络。

## 许可证

[MIT](LICENSE)
