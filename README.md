# OpenClash Visual Editor

一个运行在 OpenWrt LuCI 中的 OpenClash 配置可视化编辑器，用于批量导入节点、生成设备分流规则并安全地修改 `/etc/openclash/config/config.yaml`。

## 功能

- 批量转换 VLESS、VMess、Hysteria2/Hy2 节点链接
- 支持 VLESS Reality、TLS、WS、gRPC
- 可选写入 `dialer-proxy: 中转`
- 独立控制节点是否加入 `pr.proxies`
- 自动按 `192.168.100.2/32` 起始生成设备规则
- 手动输入内网 IP 和节点名称补充规则
- 检查重复内网 IP、重复节点名称和无效节点引用
- 读取并折叠显示已经应用的节点和规则
- 删除节点时删除关联规则，或手动输入替代节点迁移规则
- 手动修改每条规则的目标节点
- 删除规则前二次确认
- 先生成 `/tmp` 测试副本并显示差异，再备份和应用正式配置
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

## 一键更新

重新执行安装命令即可覆盖更新插件文件。正式 OpenClash 配置、编辑器状态和自动备份不会被删除。

## 一键卸载

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/rainbowgag/openclash-editor/main/uninstall.sh)"
```

卸载脚本只删除插件文件，保留 OpenClash 配置、编辑器状态和历史备份。

## 依赖与适用范围

- 已安装 OpenClash，并存在 `/etc/openclash/config/config.yaml`
- 带 Lua 兼容层的 LuCI
- Ruby、Ruby YAML 和 Psych（OpenClash 通常已经安装）
- 当前设备规则网段为 `192.168.100.0/24`，可用主机地址为 `.2` 至 `.254`

## 安全机制

预览只写入：

```text
/tmp/openclash-editor-preview.yaml
```

点击应用时会再次校验 YAML，并在下面的目录创建带时间戳的隐藏备份：

```text
/etc/openclash/config/.config.yaml.editor-backup-YYYYMMDD-HHMMSS
```

应用后不会自动重启 OpenClash，避免未经确认中断当前网络。

## 许可证

[MIT](LICENSE)
