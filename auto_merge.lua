package.path = "./xml2lua/?.lua;" .. package.path
local xml2lua = require("xml2lua")
local xmlhandler = require("xmlhandler.tree")

local function execute_command(fmt, ...)
	local handle = io.popen(string.format(fmt, ...), "r")
	local t = {}

	for line in handle:lines() do
		t[#t + 1] = line
 	end

	local tbl_rc = {handle:close()}
	if tbl_rc[1] ~= true then
		print(string.format("Error|execute_command|[%s]", string.format(fmt, ...)))
		for _, v in ipairs(t) do
			print(string.format("%s", v))
		end
		for k, v in pairs(tbl_rc) do
			print(string.format("k(%s) v(%s)", k, v))
		end
		assert(false)
	end
	return t, tbl_rc
end

local function svn_command(fmt, ...)
	return execute_command(string.format(_ENV.SVN_CMD .. " " .. fmt, ...))
end

local function string_split(str, sep, func)
	local tbl_fields = {}
	local pattern = string.format("([^%s]+)", sep)

	if func then
		string.gsub(str, pattern, function(c)
			tbl_fields[#tbl_fields + 1] = func(c) 
		end)
	else
		string.gsub(str, pattern, function(c)
			tbl_fields[#tbl_fields + 1] = c 
		end)
	end
	return tbl_fields
end

local function get_log(svn_path, begin_revision)
	local xml_parser = xml2lua.parser(xmlhandler)
	xml_parser:parse( table.concat(svn_command("log %s -r%s:HEAD --xml", svn_path, begin_revision), "\n") )

	local t = {}
	for k, v in ipairs(xmlhandler.root.log.logentry) do
		t[#t + 1] = {revision = tonumber(v._attr.revision), author = v.author, msg = v.msg, date = v.date}
	end

	return true, t
end

--
local function revert_dir(workdir)
	svn_command("revert --depth infinity %s", workdir)
end

--
local function update_dir(workdir)
	svn_command("update %s", workdir)
end

local tbl_merged_item_op = {}
tbl_merged_item_op['A'] = true
tbl_merged_item_op['D'] = true
tbl_merged_item_op['C'] = true
tbl_merged_item_op['U'] = true

--
local function merge(svn_relative_to_root_path, revision, workdir)
	-- 每次 merge 前都执行 update, 防止出现 svn: E195020: Cannot merge into mixed-revision working copy [xxx:xxx]; try updating first
	update_dir(workdir)

	local tbl_merge_response = svn_command("merge ^%s -c%s %s --accept 'postpone'", svn_relative_to_root_path, revision, workdir)
	if #tbl_merge_response <= 0 then
		-- svn merge 没有任何返回, 通常是已经合并过代码
		return true, {}
	end

	-- 检查第一行的返回信息 --- Merging rxxx into '/xxx/':
	local merge_revision = tonumber(tbl_merge_response[1]:match("^%-%-%- Merging r(.*) into .*$"))
	if not merge_revision then
		return false, string.format("error|merge|invalid first line of response|%s", tbl_merge_response[1])
	end

	-- 返回信息的版本不一致
	if merge_revision ~= revision then
		return false, string.format("error|merge|merge_revision not match|%s|%s", merge_revision, revision)
	end

	-- 冲突文件列表
	local tbl_conflicts = {} -- = {{file}, ...}
	-- 非冲突文件列表
	local tbl_normal = {} -- = {{file}, ...}

	-- 从第二行开始获取变更的文件列表
	for i = 2, #tbl_merge_response do
		-- Summary of conflicts: 之后的信息不处理
		if tbl_merge_response[i] == "Summary of conflicts:" then
			break
		end

		local op, file = tbl_merge_response[i]:match("^ *(%a) *(%/.*)$")
		print(string.format("\t%s\t%s", op, file)) -- 打印每个合并操作
		if not tbl_merged_item_op[op] then
			return false, string.format("error|merge|invalid merged item|%s|%s", tbl_merge_response[i], op)
		end

		-- 记录冲突文件并还原
		if op == 'C' then
			tbl_conflicts[#tbl_conflicts + 1] = file
			svn_command("revert %s@", file) -- 当文件路径中包含 @ 字符时, 需要在未尾也加上 @
			print(string.format("\trevert %s", file)) -- 打印回滚的路径
		else
			tbl_normal[#tbl_normal + 1] = file
		end

		::continue::
	end

	if #tbl_normal > 0 then
		svn_command("commit -m\"merge from %s %s\" %s", svn_relative_to_root_path, revision, workdir)
	end
	return true, tbl_conflicts
end

local function write_file(file_name, mode, fmt, ...)
	local f = assert(io.open(file_name, mode), string.format("write_file|file_name(%s)", file_name))
	local success, msg = f:write(string.format(fmt, ...))
	if not success then
		error(msg)
	end
	f:close()
end

local function read_file(file_name, check_file_exist)
	if check_file_exist == nil then
		check_file_exist = true
	end

	local f = io.open(file_name, "r")
	if not f then
		if check_file_exist then
			error(string.format("write_file|file_name(%s)", file_name))
		else
			return ""
		end
	end
	local s = f:read("a")
	if not s then
		error(string.format("read_file|file_name(%s)", file_name))
	end
	f:close()
	return s
end

--
local config_file = select(1, ...)
local config = require(config_file)
local begin_revision = tonumber(select(2, ...) or "")
if not config then
	error(string.format("Failed to require %s", config_file))
end

local svn_url = config.svn_url
local svn_relative_to_root_path = config.svn_relative_to_root_path
local workdir = config.workdir
local report_file = config.report_file
local last_merged_revision_store = config.last_merged_revision_store
local tbl_execlude_rule = config.execlude_rule
local svn_path = string.format("%s%s", svn_url, svn_relative_to_root_path)
local last_merged_revision = tonumber(read_file(last_merged_revision_store, false))
_ENV.SVN_CMD = config.svn_cmd

assert(begin_revision or last_merged_revision, string.format("begin_revision(%s)|last_merged_revision(%s)|you must specify the revision", begin_revision, last_merged_revision))

local tbl_final_report = {} --[[
	= {
		[author] = {
			[revition] = {
					relative_to_root_path,
					...
			},
			...
		},
		...
	}
]] 

local function check_exclude(svn_log_info)
	
	for _, execlude_rule in ipairs(tbl_execlude_rule) do
		for k, _ in pairs(execlude_rule) do
			-- 配置了其它项, 跳过不处理
			if not svn_log_info[k] then
				goto continue_1
			end

			-- 排除规则不匹配
			if svn_log_info[k] ~= execlude_rule[k] then
				goto continue_2
			end

			::continue_1::
		end

		-- 排除规则完全匹配
		-- print(string.format("\tMatch exclude rule|revision(%s)|author(%s)|msg(%s)", execlude_rule.revision, execlude_rule.author, execlude_rule.msg))
		print(string.format("\tSkip|revision(%s)|author(%s)|msg(%s)", svn_log_info.revision, svn_log_info.author, svn_log_info.msg))
		
		if true then
			return true
		end
		::continue_2::
	end

	return false
end

local function get_local_svn_relative_to_root_path(local_path, svn_url)
	local tbl_response = svn_command("info %s", local_path)
	for k, v in pairs(tbl_response) do
		-- URL: http://xxx.xxx
		local svn_relative_to_root_path = v:match(string.format("^URL: %s(.*)$", svn_url))
		if svn_relative_to_root_path then
			return svn_relative_to_root_path
		end
	end

	return nil
end

revert_dir(workdir)
update_dir(workdir)
local success, msg = get_log(svn_path, begin_revision or last_merged_revision)
if success then
	local tbl_log = msg
	for _, v in ipairs(tbl_log) do
		if begin_revision then
			if v.revision < begin_revision then
				goto continue
			end
		else
			if v.revision <= last_merged_revision then
				goto continue
			end
		end

		--
		print(string.format("merge revision = [%s], author = [%s]", v.revision, v.author))

		if check_exclude(v) then
			goto continue
		end

		--
		success, msg = merge(svn_relative_to_root_path, v.revision, workdir)
		if not success then
			error(msg)
		else
			local tbl_conflicts = msg
			if #tbl_conflicts > 0 then
				local f = io.open(report_file, "a") or io.output()

				for _, conflicts_file in ipairs(tbl_conflicts) do
					tbl_final_report[v.author] = tbl_final_report[v.author] or {}
					tbl_final_report[v.author][v.revision] = tbl_final_report[v.author][v.revision] or {}

					-- 获取相对于 svn 分支目录的相对路径
					local relative_to_root_path = conflicts_file:match(string.format("^%s(.*)$", workdir))
					tbl_final_report[v.author][v.revision][#tbl_final_report[v.author][v.revision] + 1] = relative_to_root_path

					f:write(string.format("%s|%s|%s\n", v.author, v.revision, relative_to_root_path))
				end

				f:close()
			end
		end

		::continue::
		write_file(last_merged_revision_store, "w", "%s", v.revision)
	end

	-- 输出最终报告
	local target = get_local_svn_relative_to_root_path(workdir, svn_url)
	local f = io.output()

	if next(tbl_final_report) then
		f:write("------------------------------------------------------------------------\n")
		f:write("Summary of conflicts:\n")
	end

	for author, v1 in pairs(tbl_final_report) do
		f:write(string.format("%s\n", author))
		for revision, tbl_relative_to_root_path in pairs(v1) do
			f:write(string.format("\t merge %s %s to %s\n", svn_relative_to_root_path, revision, target))
			for _, relative_to_root_path in ipairs(tbl_relative_to_root_path) do
				f:write(string.format("\t\t%s\n", relative_to_root_path))
			end
		end
	end
	f:close()
else
	error(msg)
end
