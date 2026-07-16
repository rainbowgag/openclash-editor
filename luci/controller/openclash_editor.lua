module("luci.controller.openclash_editor", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local source_path = "/etc/openclash/config/config.yaml"
local test_path = "/tmp/openclash-editor-preview.yaml"
local request_path = "/tmp/openclash-editor-request.json"
local token_path = "/tmp/openclash-editor-preview.sha256"
local pending_state_path = "/tmp/openclash-editor-preview-state.json"
local state_path = "/etc/openclash/openclash-editor-state.json"
local backend_path = "/usr/share/openclash-editor/backend.rb"

local function shellquote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function index()
	if not fs.access(source_path) then return end
	local page = entry({"admin", "services", "openclash", "visual-editor"},
		template("openclash_editor/index"), _("Visual Editor"), 85)
	page.leaf = true
	page.acl_depends = { "luci-app-openclash" }
	entry({"admin", "services", "openclash", "visual-editor-state"}, call("action_state")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-preview"}, call("action_preview")).leaf = true
	entry({"admin", "services", "openclash", "visual-editor-apply"}, call("action_apply")).leaf = true
end

local function reply(ok, data)
	data = data or {}
	data.ok = ok
	http.prepare_content("application/json")
	http.write(json.stringify(data))
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
	local generated = fs.readfile(test_path) or ""
	local diff = sys.exec("diff -u " .. shellquote(source_path) .. " " .. shellquote(test_path) .. " 2>/dev/null")
	reply(true, {
		token = token,
		preview = generated,
		diff = diff,
		test_path = test_path,
		node_count = result.node_count,
		rule_count = result.rule_count
	})
end

function action_preview()
	local ok, err = xpcall(preview_impl, debug.traceback)
	if not ok then reply(false, { error = "后端执行异常", details = err }) end
end

local function apply_impl()
	local requested = http.formvalue("token") or ""
	local expected = (fs.readfile(token_path) or ""):gsub("%s+$", "")
	local actual = sys.exec("sha256sum " .. shellquote(test_path) .. " 2>/dev/null | cut -d' ' -f1"):gsub("%s+$", "")
	if requested == "" or requested ~= expected or requested ~= actual then
		return reply(false, { error = "预览已失效，请重新生成预览" })
	end
	local valid, validation = validate_yaml(test_path)
	if not valid then return reply(false, { error = "应用前校验失败", details = validation }) end
	local stamp = os.date("%Y%m%d-%H%M%S")
	local backup = "/etc/openclash/config/.config.yaml.editor-backup-" .. stamp
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
	reply(true, { message = "配置已应用，但尚未重启 OpenClash", backup = backup })
end

function action_apply()
	local ok, err = xpcall(apply_impl, debug.traceback)
	if not ok then reply(false, { error = "后端执行异常", details = err }) end
end
