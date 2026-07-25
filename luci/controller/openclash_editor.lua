module("luci.controller.openclash_editor", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local uci_model = require "luci.model.uci"

local test_path = "/tmp/openclash-editor-preview.yaml"
local request_path = "/tmp/openclash-editor-request.json"
local token_path = "/tmp/openclash-editor-preview.sha256"
local preview_source_path = "/tmp/openclash-editor-preview-source"
local pending_state_path = "/tmp/openclash-editor-preview-state.json"
local state_path = "/etc/openclash/openclash-editor-state.json"
local backend_path = "/usr/share/openclash-editor/backend.rb"
local update_path = "/usr/share/openclash-editor/update.sh"
local version_path = "/usr/share/openclash-editor/VERSION"

local function get_source_path()
	local configured = uci_model.cursor():get("openclash", "config", "config_path")
	if not configured or configured == "" then return "/etc/openclash/config/config.yaml" end
	return configured
end

local function backup_path(source, suffix)
	local directory = source:match("^(.*)/[^/]+$") or "."
	local basename = source:match("([^/]+)$") or "config.yaml"
	return directory .. "/." .. basename .. suffix
end

local function shellquote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function index()
	if not fs.access(get_source_path()) then return end
	local page = entry({"admin", "services", "openclash", "visual-editor"},
		template("openclash_editor/nodes"), _("Node Editor"), 85)
	page.leaf = true
	page.acl_depends = { "luci-app-openclash" }
	local rules_page = entry({"admin", "services", "openclash", "visual-editor-rules"},
		template("openclash_editor/rules"), _("Rule Editor"), 86)
	rules_page.leaf = true
	rules_page.acl_depends = { "luci-app-openclash" }
	local qr_page = entry({"admin", "services", "openclash", "visual-editor-qr"},
		template("openclash_editor/qr"), _("扫码绑定"), 87)
	qr_page.leaf = true
	qr_page.acl_depends = { "luci-app-openclash" }
	entry({"admin", "services", "openclash", "visual-editor-state"}, call("action_state")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-preview"}, call("action_preview")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-apply"}, call("action_apply")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-reset"}, call("action_reset")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-update-check"}, call("action_update_check")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-update"}, call("action_update")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-qr-create"}, call("action_qr_create")).leaf = true
	entry({"openclash-editor-bind"}, call("action_qr_bind")).leaf = true
	entry({"oeb"}, call("action_qr_bind")).leaf = true
end

local function reply(ok, data)
	data = data or {}
	data.ok = ok
	http.prepare_content("application/json")
	http.write(json.stringify(data))
end

local function require_post()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		reply(false, { error = "该操作只接受 POST 请求" })
		return false
	end
	return true
end

local function run_backend(command)
	local output = sys.exec("ruby " .. shellquote(backend_path) .. " " .. command .. " 2>&1")
	local parsed = json.parse(output)
	if not parsed then return nil, "后端没有返回有效 JSON", output end
	return parsed
end

local function validate_yaml(path)
	local cmd = "ruby -ryaml -e 'YAML.load_file(ARGV[0], aliases: true)' " .. shellquote(path) .. " 2>&1"
	local output = sys.exec(cmd)
	local status = sys.call(cmd .. " >/dev/null 2>&1")
	return status == 0, output
end

local function state_impl()
	local result, err, details = run_backend("state")
	if not result then return reply(false, { error = err, details = details }) end
	http.prepare_content("application/json")
	http.write(json.stringify(result))
end

function action_state()
	local ok, err = xpcall(state_impl, debug.traceback)
	if not ok then reply(false, { error = "读取配置失败", details = err }) end
end

local function qr_create_impl()
	local node_name = (http.formvalue("node") or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if node_name == "" then return reply(false, { error = "请输入已有节点名称" }) end
	if #node_name > 256 then return reply(false, { error = "节点名称过长" }) end
	local reload_openclash = http.formvalue("reload") == "1" and "1" or "0"
	local result, err, details = run_backend("qr-create " .. shellquote(node_name) .. " " .. reload_openclash)
	if not result then return reply(false, { error = err, details = details }) end
	if not result.ok then return reply(false, result) end
	reply(true, result)
end

function action_qr_create()
	if not require_post() then return end
	local ok, err = xpcall(qr_create_impl, debug.traceback)
	if not ok then reply(false, { error = "生成二维码失败", details = err }) end
end

local function qr_bind_page(title, body, tone)
	local color = tone == "ok" and "#08783e" or tone == "warn" and "#9a5a00" or "#b42318"
	http.prepare_content("text/html; charset=utf-8")
	http.write("<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
	http.write("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
	http.write("<title>" .. util.pcdata(title) .. "</title>")
	http.write("<style>body{margin:0;background:#f4f7fb;color:#15254b;font:16px/1.65 sans-serif}.box{max-width:560px;margin:9vh auto;padding:28px;background:#fff;border-radius:18px;box-shadow:0 12px 40px #15254b22}.state{border-left:6px solid " .. color .. ";padding-left:18px}h1{font-size:26px;margin:0 0 16px}.btn{display:block;width:100%;box-sizing:border-box;margin-top:24px;padding:15px;border:0;border-radius:10px;background:#2867e8;color:#fff;font-weight:700;font-size:17px}code{word-break:break-all}</style>")
	http.write("</head><body><main class=\"box\"><div class=\"state\"><h1>" .. util.pcdata(title) .. "</h1>" .. body .. "</div></main></body></html>")
end

local function qr_bind_impl()
	local token = http.formvalue("t") or http.formvalue("token") or ""
	if not token:match("^[0-9a-f]+$") or #token ~= 32 then
		return qr_bind_page("二维码无效", "<p>链接格式不正确，请返回管理页面重新生成。</p>", "error")
	end

	if http.getenv("REQUEST_METHOD") ~= "POST" then
		local result, err, details = run_backend("qr-info " .. shellquote(token))
		if not result or not result.ok then
			local message = result and result.error or err or details or "二维码不可用"
			return qr_bind_page("二维码不可用", "<p>" .. util.pcdata(message) .. "</p>", "error")
		end
		local reload_text = result.reload_openclash and
			"<p>确认后会写入固定 DHCP 租约和设备规则，并自动重启 OpenClash 使规则生效。</p>" or
			"<p>确认后会写入固定 DHCP 租约和设备规则；需要稍后手动重新载入 OpenClash。</p>"
		local form = "<p>目标节点：<strong>" .. util.pcdata(result.node) .. "</strong></p>" ..
			reload_text ..
			"<form method=\"post\"><input type=\"hidden\" name=\"t\" value=\"" .. util.pcdata(token) .. "\">" ..
			"<button class=\"btn\" type=\"submit\">确认绑定这台设备</button></form>"
		return qr_bind_page("扫码绑定设备", form, "warn")
	end

	local remote_address = http.getenv("REMOTE_ADDR") or ""
	local result, err, details = run_backend("qr-bind " .. shellquote(token) .. " " .. shellquote(remote_address))
	if not result or not result.ok then
		local message = result and result.error or err or details or "绑定失败"
		return qr_bind_page("绑定失败", "<p>" .. util.pcdata(message) .. "</p>", "error")
	end
	local next_step = result.reload_openclash and
		"<p>OpenClash 正在后台重启，网络可能短暂中断，请等待约 30 秒。</p>" or
		"<p>请在 OpenClash 中重新载入配置后生效。</p>"
	if result.reconnect_required then
		next_step = next_step .. "<p>该设备已有固定地址，请断开并重新连接一次 Wi-Fi。</p>"
	end
	local body = "<p>设备 <code>" .. util.pcdata(result.mac) .. "</code> 已绑定到：</p>" ..
		"<p><strong>" .. util.pcdata(result.node) .. "</strong>（" .. util.pcdata(result.ip) .. "/32）</p>" .. next_step
	qr_bind_page("绑定成功", body, "ok")
end

function action_qr_bind()
	local ok, err = xpcall(qr_bind_impl, debug.traceback)
	if not ok then qr_bind_page("绑定失败", "<p>" .. util.pcdata(err) .. "</p>", "error") end
end

local function preview_impl()
	local payload = http.formvalue("payload") or ""
	if #payload == 0 then return reply(false, { error = "没有收到草稿数据" }) end
	if #payload > 2097152 then return reply(false, { error = "草稿数据过大" }) end
	if not json.parse(payload) then return reply(false, { error = "草稿 JSON 格式错误" }) end
	if not fs.writefile(request_path, payload) then return reply(false, { error = "无法写入临时请求" }) end
	local result, err, details = run_backend("preview " .. shellquote(request_path))
	if not result then return reply(false, { error = err, details = details }) end
	if not result.ok then return reply(false, result) end

	local valid, validation = validate_yaml(test_path)
	if not valid then return reply(false, { error = "YAML 校验失败", details = validation }) end
	local token = sys.exec("sha256sum " .. shellquote(test_path) .. " | cut -d' ' -f1"):gsub("%s+$", "")
	fs.writefile(token_path, token)
	fs.writefile(preview_source_path, result.source_path or get_source_path())
	local generated = fs.readfile(test_path) or ""
	reply(true, {
		token = token,
		preview = generated,
		diff = result.diff or "",
		test_path = test_path,
		node_count = result.node_count,
		rule_count = result.rule_count
	})
end

function action_preview()
	if not require_post() then return end
	local ok, err = xpcall(preview_impl, debug.traceback)
	if not ok then reply(false, { error = "后端执行异常", details = err }) end
end

local function apply_impl()
	local source_path = get_source_path()
	local requested = http.formvalue("token") or ""
	local expected = (fs.readfile(token_path) or ""):gsub("%s+$", "")
	local actual = sys.exec("sha256sum " .. shellquote(test_path) .. " 2>/dev/null | cut -d' ' -f1"):gsub("%s+$", "")
	local preview_source = (fs.readfile(preview_source_path) or ""):gsub("%s+$", "")
	if requested == "" or requested ~= expected or requested ~= actual then
		return reply(false, { error = "预览已失效，请重新生成预览" })
	end
	if preview_source == "" or preview_source ~= source_path then
		return reply(false, { error = "OpenClash 当前配置文件已切换，请重新生成预览" })
	end
	local valid, validation = validate_yaml(test_path)
	if not valid then return reply(false, { error = "应用前校验失败", details = validation }) end
	local stamp = os.date("%Y%m%d-%H%M%S")
	local backup = backup_path(source_path, ".editor-backup-" .. stamp)
	if sys.call("cp -p " .. shellquote(source_path) .. " " .. shellquote(backup)) ~= 0 then
		return reply(false, { error = "创建备份失败" })
	end
	local staged = source_path .. ".editor-new"
	if sys.call("cp " .. shellquote(test_path) .. " " .. shellquote(staged)) ~= 0 or
		sys.call("mv " .. shellquote(staged) .. " " .. shellquote(source_path)) ~= 0 then
		return reply(false, { error = "应用配置失败，正式配置未被替换", backup = backup })
	end
	if fs.access(pending_state_path) then
		sys.call("cp " .. shellquote(pending_state_path) .. " " .. shellquote(state_path))
	end
	fs.remove(token_path)
	fs.remove(preview_source_path)
	reply(true, { message = "配置已应用，但尚未重启 OpenClash", backup = backup })
end

function action_apply()
	if not require_post() then return end
	local ok, err = xpcall(apply_impl, debug.traceback)
	if not ok then reply(false, { error = "后端执行异常", details = err }) end
end

local function reset_impl()
	local result, err, details = run_backend("reset")
	if not result then return reply(false, { error = err, details = details }) end
	if not result.ok then return reply(false, result) end
	fs.remove(token_path)
	fs.remove(preview_source_path)
	reply(true, { message = "已恢复无节点和设备规则的初始配置", backup = result.backup })
end

function action_reset()
	if not require_post() then return end
	local ok, err = xpcall(reset_impl, debug.traceback)
	if not ok then reply(false, { error = "恢复初始配置失败", details = err }) end
end

local function version_is_newer(latest, current)
	local latest_parts, current_parts = {}, {}
	for part in tostring(latest):gmatch("%d+") do latest_parts[#latest_parts + 1] = tonumber(part) end
	for part in tostring(current):gmatch("%d+") do current_parts[#current_parts + 1] = tonumber(part) end
	local count = math.max(#latest_parts, #current_parts)
	for index = 1, count do
		local left = latest_parts[index] or 0
		local right = current_parts[index] or 0
		if left > right then return true end
		if left < right then return false end
	end
	return false
end

function action_update_check()
	local current = (fs.readfile(version_path) or "dev"):gsub("%s+$", "")
	local latest = sys.exec("sh " .. shellquote(update_path) .. " check 2>/dev/null"):gsub("%s+$", "")
	if latest == "" then return reply(false, { error = "无法连接 GitHub 检查版本", current = current }) end
	reply(true, { current = current, latest = latest, available = version_is_newer(latest, current) })
end

function action_update()
	if not require_post() then return end
	local log_path = "/tmp/openclash-editor-update.log"
	local status = sys.call("sh " .. shellquote(update_path) .. " update >" .. shellquote(log_path) .. " 2>&1")
	local output = fs.readfile(log_path) or ""
	if status ~= 0 then return reply(false, { error = "更新失败", details = output }) end
	local version = (fs.readfile(version_path) or "unknown"):gsub("%s+$", "")
	reply(true, { message = "更新成功", version = version, details = output })
end
