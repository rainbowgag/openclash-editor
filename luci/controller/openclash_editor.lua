module("luci.controller.openclash_editor", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local uci_model = require "luci.model.uci"
local xml_ok, xml = pcall(require, "luci.xml")
local pcdata = xml_ok and xml.pcdata or util.pcdata

local test_path = "/tmp/openclash-editor-preview.yaml"
local request_path = "/tmp/openclash-editor-request.json"
local token_path = "/tmp/openclash-editor-preview.sha256"
local preview_source_path = "/tmp/openclash-editor-preview-source"
local pending_state_path = "/tmp/openclash-editor-preview-state.json"
local slot_plan_path = "/tmp/openclash-editor-slot-plan.json"
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

local function schedule_openclash_restart()
	if not fs.access("/etc/init.d/openclash") then
		return false, "未找到 /etc/init.d/openclash"
	end
	local command = "(sleep 2; /etc/init.d/openclash restart) >/tmp/openclash-editor-restart.log 2>&1 &"
	if sys.call("sh -c " .. shellquote(command)) ~= 0 then
		return false, "无法启动 OpenClash 后台重启任务"
	end
	return true
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
		template("openclash_editor/slots"), _("口令绑定"), 87)
	qr_page.leaf = true
	qr_page.acl_depends = { "luci-app-openclash" }
	entry({"admin", "services", "openclash", "visual-editor-slots"},
		alias("admin", "services", "openclash", "visual-editor-qr")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-state"}, call("action_state")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-preview"}, call("action_preview")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-apply"}, call("action_apply")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-restart"}, call("action_restart")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-reset"}, call("action_reset")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-update-check"}, call("action_update_check")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-update"}, call("action_update")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slots-list"}, call("action_slots_list")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slots-create"}, call("action_slots_create")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slots-create-many"}, call("action_slots_create_many")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slots-plan"}, call("action_slots_plan")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slot-update"}, call("action_slot_update")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slot-regenerate"}, call("action_slot_regenerate")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slot-rebind"}, call("action_slot_rebind")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slot-refresh-lease"}, call("action_slot_refresh_lease")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slot-delete"}, call("action_slot_delete")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-slots-delete"}, call("action_slots_delete")).leaf = true
	entry({"openclash-editor-bind"}, call("action_qr_bind")).leaf = true
	entry({"oeb"}, call("action_qr_bind")).leaf = true
	entry({"openclash-editor-code"}, call("action_code_bind")).leaf = true
	entry({"oec"}, call("action_code_bind")).leaf = true
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
	if not parsed then
		for line in tostring(output):gmatch("[^\r\n]+") do
			local candidate = json.parse(line)
			if candidate then parsed = candidate end
		end
	end
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

function action_qr_devices()
	local ok, err = xpcall(function()
		local result, backend_err, details = run_backend("qr-devices")
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "读取扫码设备失败", details = err }) end
end

local function qr_device_action(command, require_node)
	if not require_post() then return end
	local mac = http.formvalue("mac") or ""
	local node = http.formvalue("node") or ""
	local reload_openclash = http.formvalue("reload") == "1" and "1" or "0"
	if type(mac) ~= "string" or #mac > 32 then return reply(false, { error = "设备 MAC 地址无效" }) end
	if require_node and (type(node) ~= "string" or node == "" or #node > 256) then
		return reply(false, { error = "请输入已有节点名称" })
	end
	local backend_command = command .. " " .. shellquote(mac)
	if require_node then backend_command = backend_command .. " " .. shellquote(node) end
	backend_command = backend_command .. " " .. reload_openclash
	local result, err, details = run_backend(backend_command)
	if not result then return reply(false, { error = err, details = details }) end
	if not result.ok then return reply(false, result) end
	reply(true, result)
end

function action_qr_change()
	local ok, err = xpcall(function() qr_device_action("qr-device-change", true) end, debug.traceback)
	if not ok then reply(false, { error = "更换代理失败", details = err }) end
end

function action_qr_unproxy()
	local ok, err = xpcall(function() qr_device_action("qr-device-unproxy", false) end, debug.traceback)
	if not ok then reply(false, { error = "取消代理失败", details = err }) end
end

function action_qr_delete()
	local ok, err = xpcall(function() qr_device_action("qr-device-delete", false) end, debug.traceback)
	if not ok then reply(false, { error = "删除扫码设备失败", details = err }) end
end

local function qr_delete_bulk_impl()
	local raw = http.formvalue("macs") or ""
	if type(raw) ~= "string" or #raw > 4608 then
		return reply(false, { error = "批量删除参数无效" })
	end
	local macs = {}
	for mac in raw:gmatch("[^,]+") do
		mac = mac:gsub("^%s+", ""):gsub("%s+$", ""):lower()
		if mac ~= "" then macs[#macs + 1] = mac end
	end
	if #macs == 0 then return reply(false, { error = "请至少选择一台扫码设备" }) end
	if #macs > 256 then return reply(false, { error = "单次最多批量删除 256 台设备" }) end
	local reload_openclash = http.formvalue("reload") == "1" and "1" or "0"
	local result, backend_error, details = run_backend(
		"qr-devices-delete " .. shellquote(table.concat(macs, ",")) .. " " .. reload_openclash
	)
	if not result then return reply(false, { error = backend_error, details = details }) end
	if not result.ok then return reply(false, result) end
	reply(true, result)
end

function action_qr_delete_bulk()
	if not require_post() then return end
	local ok, err = xpcall(qr_delete_bulk_impl, debug.traceback)
	if not ok then reply(false, { error = "批量删除扫码设备失败", details = err }) end
end

function action_slots_list()
	local ok, err = xpcall(function()
		local result, backend_err, details = run_backend("slots")
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "读取扫码槽位失败", details = err }) end
end

function action_slots_create()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local node = http.formvalue("node") or ""
		local count = http.formvalue("count") or "1"
		local prefix = http.formvalue("prefix") or "手机槽位"
		local start_number = http.formvalue("start") or "1"
		if type(node) ~= "string" or node == "" or #node > 256 then
			return reply(false, { error = "请输入已有节点名称" })
		end
		if type(prefix) ~= "string" or #prefix > 256 then
			return reply(false, { error = "槽位名称前缀无效" })
		end
		if not tostring(count):match("^%d+$") or not tostring(start_number):match("^%d+$") then
			return reply(false, { error = "数量和起始编号必须是整数" })
		end
		local command = "slots-create " .. shellquote(node) .. " " .. shellquote(count) ..
			" " .. shellquote(prefix) .. " " .. shellquote(start_number)
		local result, backend_err, details = run_backend(command)
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "创建扫码槽位失败", details = err }) end
end

local function parse_name_list(raw)
	local names = {}
	for name in tostring(raw or ""):gmatch("[^,]+") do
		name = name:gsub("^%s+", ""):gsub("%s+$", "")
		if name ~= "" then names[#names + 1] = name end
	end
	return names
end

function action_slots_create_many()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local raw = http.formvalue("nodes") or ""
		if type(raw) ~= "string" or #raw > 65535 then return reply(false, { error = "节点参数无效" }) end
		local names = parse_name_list(raw)
		if #names == 0 then return reply(false, { error = "请至少选择一个节点" }) end
		if #names > 256 then return reply(false, { error = "单次最多选择 256 个节点" }) end
		local result, backend_err, details = run_backend("slots-create-many " .. shellquote(table.concat(names, ",")))
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "按节点批量创建扫码槽位失败", details = err }) end
end

function action_slots_plan()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local payload = http.formvalue("payload") or ""
		if type(payload) ~= "string" or #payload == 0 or #payload > 1048576 then
			return reply(false, { error = "槽位规划数据无效" })
		end
		if not json.parse(payload) then return reply(false, { error = "槽位规划 JSON 格式错误" }) end
		if not fs.writefile(slot_plan_path, payload) then return reply(false, { error = "无法写入槽位规划请求" }) end
		local result, backend_err, details = run_backend("slots-plan " .. shellquote(slot_plan_path))
		fs.remove(slot_plan_path)
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "规划扫码槽位失败", details = err }) end
end

local function slot_id_action(command, include_node)
	if not require_post() then return end
	local id = http.formvalue("id") or ""
	local node = http.formvalue("node") or ""
	if type(id) ~= "string" or not id:match("^[0-9a-f]+$") or #id ~= 12 then
		return reply(false, { error = "扫码槽位编号无效" })
	end
	if include_node and (type(node) ~= "string" or node == "" or #node > 256) then
		return reply(false, { error = "请输入已有节点名称" })
	end
	local backend_command = command .. " " .. shellquote(id)
	if include_node then backend_command = backend_command .. " " .. shellquote(node) end
	local result, backend_err, details = run_backend(backend_command)
	if not result then return reply(false, { error = backend_err, details = details }) end
	if not result.ok then return reply(false, result) end
	reply(true, result)
end

function action_slot_update()
	local ok, err = xpcall(function() slot_id_action("slot-update", true) end, debug.traceback)
	if not ok then reply(false, { error = "修改扫码槽位失败", details = err }) end
end

function action_slot_regenerate()
	local ok, err = xpcall(function() slot_id_action("slot-regenerate", false) end, debug.traceback)
	if not ok then reply(false, { error = "重置扫码槽位二维码失败", details = err }) end
end

function action_slot_rebind()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local id = http.formvalue("id") or ""
		local enabled = http.formvalue("enabled") or ""
		if type(id) ~= "string" or not id:match("^[0-9a-f]+$") or #id ~= 12 then
			return reply(false, { error = "扫码槽位编号无效" })
		end
		if enabled ~= "0" and enabled ~= "1" then
			return reply(false, { error = "换绑授权参数无效" })
		end
		local result, backend_err, details = run_backend("slot-rebind " .. shellquote(id) .. " " .. shellquote(enabled))
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "修改换绑授权失败", details = err }) end
end

function action_slot_refresh_lease()
	local ok, err = xpcall(function() slot_id_action("slot-refresh-lease", false) end, debug.traceback)
	if not ok then reply(false, { error = "刷新扫码槽位 IP 租约失败", details = err }) end
end

function action_slot_delete()
	local ok, err = xpcall(function() slot_id_action("slot-delete", false) end, debug.traceback)
	if not ok then reply(false, { error = "删除扫码槽位失败", details = err }) end
end

function action_slots_delete()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local raw = http.formvalue("ids") or ""
		if type(raw) ~= "string" or #raw > 8192 then return reply(false, { error = "批量删除参数无效" }) end
		local ids = parse_name_list(raw)
		if #ids == 0 then return reply(false, { error = "请至少选择一个扫码槽位" }) end
		if #ids > 256 then return reply(false, { error = "单次最多批量删除 256 个扫码槽位" }) end
		local result, backend_err, details = run_backend("slots-delete " .. shellquote(table.concat(ids, ",")))
		if not result then return reply(false, { error = backend_err, details = details }) end
		if not result.ok then return reply(false, result) end
		reply(true, result)
	end, debug.traceback)
	if not ok then reply(false, { error = "批量删除扫码槽位失败", details = err }) end
end

local function qr_bind_page(title, body, tone)
	local color = tone == "ok" and "#08783e" or tone == "warn" and "#9a5a00" or "#b42318"
	http.prepare_content("text/html; charset=utf-8")
	http.write("<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
	http.write("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
	http.write("<title>" .. pcdata(title) .. "</title>")
	http.write("<style>body{margin:0;background:#f4f7fb;color:#15254b;font:16px/1.65 sans-serif}.box{max-width:560px;margin:9vh auto;padding:28px;background:#fff;border-radius:18px;box-shadow:0 12px 40px #15254b22}.state{border-left:6px solid " .. color .. ";padding-left:18px}h1{font-size:26px;margin:0 0 16px}.input{display:block;width:100%;box-sizing:border-box;margin-top:16px;padding:15px;border:2px solid #9bbcff;border-radius:10px;background:#fff;color:#15254b;font-size:28px;font-weight:800;text-align:center;letter-spacing:.28em}.btn{display:block;width:100%;box-sizing:border-box;margin-top:18px;padding:15px;border:0;border-radius:10px;background:#2867e8;color:#fff;font-weight:700;font-size:17px}code{word-break:break-all}.hint{color:#65748d;font-size:14px}</style>")
	http.write("</head><body><main class=\"box\"><div class=\"state\"><h1>" .. pcdata(title) .. "</h1>" .. body .. "</div></main></body></html>")
end

local function qr_bind_impl()
	local token = http.formvalue("s")
	if type(token) == "table" then token = token[1] end
	if type(token) ~= "string" or token == "" then
		token = http.formvalue("slot_token")
		if type(token) == "table" then token = token[1] end
	end
	if type(token) ~= "string" then token = "" end
	if not token:match("^[0-9a-f]+$") or #token ~= 32 then
		return qr_bind_page("二维码无效", "<p>链接格式不正确，请返回管理页面重新生成。</p>", "error")
	end

	if http.getenv("REQUEST_METHOD") ~= "POST" then
		local remote_address = http.getenv("REMOTE_ADDR") or ""
		local result, err, details = run_backend("slot-info " .. shellquote(token) .. " " .. shellquote(remote_address))
		if not result or not result.ok then
			local message = result and result.error or (details and details ~= "" and details) or err or "二维码不可用"
			return qr_bind_page("二维码不可用", "<p>" .. pcdata(message) .. "</p>", "error")
		end
		local slot = result.slot or {}
		local bound = slot.mac and slot.mac ~= "" and
			("<p>当前绑定：<code>" .. pcdata(slot.mac) .. "</code></p>") or
			"<p>当前还没有设备占用这个槽位。</p>"
		local summary = "<p>扫码槽位：<strong>" .. pcdata(slot.name or "") .. "</strong></p>" ..
			"<p>固定地址：<strong>" .. pcdata(slot.ip or "") .. "</strong></p>" ..
			"<p>目标节点：<strong>" .. pcdata(slot.node or "") .. "</strong></p>" ..
			bound
		if not result.can_bind then
			local detail = "<p><strong>该槽位已经锁定，当前手机不能替换原设备。</strong></p>" ..
				"<p>请联系管理员，在扫码绑定页面为此槽位点击“允许换绑”，然后于10分钟内重新扫码。</p>"
			return qr_bind_page("槽位已锁定", summary .. detail, "error")
		end
		local notice
		if result.same_device then
			notice = "<p>当前手机就是该槽位已绑定的设备，可以安全地再次确认。</p>"
		elseif result.rebind_allowed then
			local minutes = math.max(1, math.ceil((tonumber(result.rebind_remaining) or 0) / 60))
			notice = "<p><strong>管理员已允许换绑，授权约剩余 " .. minutes .. " 分钟。</strong></p>" ..
				"<p>确认后，这台手机将替换原设备。</p>"
		else
			notice = "<p>这是该槽位的首次绑定。</p>"
		end
		local form = summary .. notice ..
			"<p>完成后请断开并重新连接 Wi-Fi。</p>" ..
			"<form method=\"post\"><input type=\"hidden\" name=\"slot_token\" value=\"" .. pcdata(token) .. "\">" ..
			"<button class=\"btn\" type=\"submit\">确认绑定这个扫码槽位</button></form>"
		return qr_bind_page("扫码绑定", form, "warn")
	end

	local remote_address = http.getenv("REMOTE_ADDR") or ""
	local result, err, details = run_backend("slot-bind " .. shellquote(token) .. " " .. shellquote(remote_address))
	if not result or not result.ok then
		local message = result and result.error or (details and details ~= "" and details) or err or "绑定失败"
		return qr_bind_page("绑定失败", "<p>" .. pcdata(message) .. "</p>", "error")
	end
	local next_step = result.reload_openclash and
		"<p>槽位规则已修复，OpenClash 正在后台重启。</p>" or
		"<p>该扫码槽位原有代理规则继续生效，不需要重复写入规则。</p>"
	if result.reconnect_required then
		next_step = next_step .. "<p>旧 DHCP 租约已经释放。</p>" ..
			"<p><strong>请关闭手机 Wi-Fi 约 5 秒后重新打开</strong>，设备将获取槽位固定地址。</p>"
	end
	local result_node = result.node or (result.slot and result.slot.node) or ""
	local body = "<p>设备 <code>" .. pcdata(result.mac) .. "</code> 已绑定到：</p>" ..
		"<p><strong>" .. pcdata(result_node) .. "</strong>（" .. pcdata(result.ip) .. "/32）</p>" .. next_step
	qr_bind_page("绑定成功", body, "ok")
end

function action_qr_bind()
	local ok, err = xpcall(qr_bind_impl, debug.traceback)
	if not ok then qr_bind_page("绑定失败", "<p>" .. pcdata(err) .. "</p>", "error") end
end

local function code_bind_form(error_message)
	local warning = error_message and error_message ~= "" and
		("<p style=\"color:#b42318;font-weight:700\">" .. pcdata(error_message) .. "</p>") or
		"<p>请输入管理员分配的槽位口令，例如 <strong>001</strong>。</p>"
	local body = warning ..
		"<form method=\"post\" action=\"\">" ..
		"<input class=\"input\" name=\"code\" type=\"text\" inputmode=\"numeric\" pattern=\"[0-9]*\" maxlength=\"6\" autocomplete=\"one-time-code\" autofocus placeholder=\"001\">" ..
		"<button class=\"btn\" type=\"submit\">绑定并连接网络</button></form>" ..
		"<p class=\"hint\">绑定会让当前手机替换该槽位原来的设备，并自动获取槽位固定 IP。请勿把口令交给其他设备使用。</p>"
	qr_bind_page("设备口令绑定", body, error_message and "error" or "warn")
end

local function code_bind_impl()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		return code_bind_form(nil)
	end
	local code = http.formvalue("code") or ""
	if type(code) == "table" then code = code[1] or "" end
	code = tostring(code):gsub("^%s+", ""):gsub("%s+$", "")
	if not code:match("^%d+$") or #code > 6 then
		return code_bind_form("口令格式不正确，请输入纯数字口令。")
	end
	local remote_address = http.getenv("REMOTE_ADDR") or ""
	local result, err, details = run_backend("slot-code-bind " .. shellquote(code) .. " " .. shellquote(remote_address))
	if not result or not result.ok then
		local message = result and result.error or (details and details ~= "" and details) or err or "绑定失败"
		return code_bind_form(message)
	end
	local slot = result.slot or {}
	local body = "<p>当前设备已经绑定到槽位 <strong>" .. pcdata(slot.code or code) .. "</strong>。</p>" ..
		"<p>代理节点：<strong>" .. pcdata(slot.node or "") .. "</strong></p>" ..
		"<p>固定 IP：<strong>" .. pcdata(result.ip or slot.ip or "") .. "</strong></p>" ..
		"<p><strong>路由器会让手机自动重新连接 Wi-Fi。</strong>如果没有自动重连，请手动关闭 Wi-Fi 约 5 秒后再打开。</p>"
	qr_bind_page("绑定成功", body, "ok")
end

function action_code_bind()
	local ok, err = xpcall(code_bind_impl, debug.traceback)
	if not ok then code_bind_form(err) end
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
		rule_count = result.rule_count,
		slot_count = result.slot_count
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
	local slot_result, slot_error, slot_details = run_backend("slots-apply-pending")
	if not slot_result or not slot_result.ok then
		sys.call("cp -p " .. shellquote(backup) .. " " .. shellquote(source_path))
		local message = slot_result and slot_result.error or slot_error or "应用扫码槽位失败"
		return reply(false, {
			error = message .. "；正式 YAML 已回滚",
			details = slot_details or (slot_result and slot_result.details),
			backup = backup
		})
	end
	if fs.access(pending_state_path) then
		sys.call("cp " .. shellquote(pending_state_path) .. " " .. shellquote(state_path))
	end
	fs.remove(token_path)
	fs.remove(preview_source_path)
	local restart_ok, restart_error = schedule_openclash_restart()
	if not restart_ok then
		return reply(true, {
			message = "配置已应用，但 OpenClash 重启任务启动失败",
			warning = restart_error,
			backup = backup
		})
	end
	reply(true, {
		message = "配置与扫码槽位已应用，OpenClash 正在后台重启",
		backup = backup,
		slot_count = slot_result.slot_count,
		removed_slot_count = slot_result.removed_count
	})
end

function action_apply()
	if not require_post() then return end
	local ok, err = xpcall(apply_impl, debug.traceback)
	if not ok then reply(false, { error = "后端执行异常", details = err }) end
end

function action_restart()
	if not require_post() then return end
	local ok, err = xpcall(function()
		local restart_ok, restart_error = schedule_openclash_restart()
		if not restart_ok then return reply(false, { error = restart_error }) end
		reply(true, { message = "OpenClash 正在后台重启" })
	end, debug.traceback)
	if not ok then reply(false, { error = "重启 OpenClash 失败", details = err }) end
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
