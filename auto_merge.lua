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

local function hash_table_sort(t, sort_func)
	local array = {}
	for k, v in pairs(t) do
		table.insert(array, {key = k, value = v})
	end
	table.sort(array, sort_func)
	return array
end

local function get_log(svn_path, begin_revision)
	local xml_parser = xml2lua.parser(xmlhandler)
	xml_parser:parse( table.concat(svn_command("log %s -r%s:HEAD --xml", svn_path, begin_revision), "\n") )
	
	local tbl_log = xmlhandler.root.log.logentry
	if #tbl_log <= 0 then
		tbl_log = {tbl_log}
	end

	local t = {}
	for k, v in ipairs(tbl_log) do
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
local function merge(svn_relative_to_root_path, revision, workdir, tbl_execlude_path)
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
	local tbl_revert_path = {} -- 已经 revert 过的 svn 相对路径

	for i = 2, #tbl_merge_response do
		-- Summary of conflicts: 之后的信息不处理
		if tbl_merge_response[i] == "Summary of conflicts:" then
			break
		end

		local op, file = tbl_merge_response[i]:match("^ *(%a) *(%/.*)$")
		if not tbl_merged_item_op[op] then
			return false, string.format("error|merge|invalid merged item|%s|%s", tbl_merge_response[i], op)
		end

		-- 检查排除的路径
		for _, execlude_path in ipairs(tbl_execlude_path) do
			-- 获取相对于 svn 分支目录的相对路径
			local relative_to_root_path = file:match(string.format("^%s(.*)", workdir:gsub("%p","%%%0")))

			if relative_to_root_path:match(execlude_path) then
				-- revert 过父目录, 子目录不再进行 revert
				for _, revert_path in ipairs(tbl_revert_path) do
					if file:match(string.format("^%s(.*)", revert_path:gsub("%p", "%%%0"))) then
						goto continue
					end
				end

				print(string.format("\tSkip|file(%s)", relative_to_root_path))
				svn_command("revert --depth infinity %s@", file) -- 当文件路径中包含 @ 字符时, 需要在未尾也加上 @
				table.insert(tbl_revert_path, file)
				goto continue
			end
		end

		-- 打印合并操作
		print(string.format("\t%s\t%s", op, file))

		-- 记录冲突文件并还原
		if op == 'C' then
			tbl_conflicts[#tbl_conflicts + 1] = file
			svn_command("revert --depth infinity %s@", file) -- 当文件路径中包含 @ 字符时, 需要在未尾也加上 @
			print(string.format("\trevert --depth infinity %s", file)) -- 打印回滚的路径
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
			error(string.format("read_file|file_name(%s)", file_name))
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

local function check_exclude(svn_log_info, tbl_execlude_rule)
	for _, execlude_rule in ipairs(tbl_execlude_rule) do
		for k, v in pairs(execlude_rule) do
			-- 配置了非法字段, 跳过不处理
			if not svn_log_info[k] then
				goto continue_1
			end

			-- 排除规则不匹配
			if svn_log_info[k] ~= v then
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

local function auto_merge(config_file, begin_revision)
	local config = require(config_file)
	assert(type(config) == "table", "Invalid config")
	local svn_url = config.svn_url
	local svn_relative_to_root_path = config.svn_relative_to_root_path
	local workdir = config.workdir
	local report_file = config.report_file
	local last_merged_revision_store = config.last_merged_revision_store
	local tbl_execlude_rule = config.execlude_rule
	local tbl_execlude_path = config.execlude_path
	local svn_path = string.format("%s%s", svn_url, svn_relative_to_root_path)
	local last_merged_revision = tonumber(read_file(last_merged_revision_store, false))
	assert(begin_revision or last_merged_revision, string.format("begin_revision(%s)|last_merged_revision(%s)|you must specify the revision", begin_revision, last_merged_revision))

	_ENV.SVN_CMD = config.svn_cmd

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

			if check_exclude(v, tbl_execlude_rule) then
				goto continue
			end

			--
			success, msg = merge(svn_relative_to_root_path, v.revision, workdir, tbl_execlude_path)
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
						local relative_to_root_path = conflicts_file:match(string.format("^%s(.*)", workdir:gsub("%p","%%%0")))
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
end

local function print_conflicts(config_file)
	local config = require(config_file)
	_ENV.SVN_CMD = config.svn_cmd
	assert(type(config) == "table", "Invalid config")
	local report_file = config.report_file
	local svn_url = config.svn_url
	local svn_relative_to_root_path = config.svn_relative_to_root_path
	local workdir = config.workdir
	local target = get_local_svn_relative_to_root_path(workdir, svn_url)


	local tbl_final_report = {}

	local f = io.open(report_file, "r")
	for line in f:lines() do
		local author, revision, file = line:match("(.*)%|(.*)%|(.*)")
		tbl_final_report[author] = tbl_final_report[author] or {}
		tbl_final_report[author][revision] = tbl_final_report[author][revision] or {}
		tbl_final_report[author][revision][#tbl_final_report[author][revision] + 1] = file
 	end

 	f = io.output()
	if next(tbl_final_report) then
		f:write("------------------------------------------------------------------------\n")
		f:write("Summary of conflicts:\n")
	end

	for author, v1 in pairs(tbl_final_report) do
		f:write(string.format("%s\n", author))
		for _, v2 in pairs(hash_table_sort(v1, function(a, b) return a.key < b.key end)) do -- .key 即为 revision
			local revision = v2.key
			local tbl_relative_to_root_path = v2.value

			f:write(string.format("\t merge %s %s to %s\n", svn_relative_to_root_path, revision, target))
			for _, relative_to_root_path in ipairs(tbl_relative_to_root_path) do
				f:write(string.format("\t\t%s\n", relative_to_root_path))
			end
		end
	end
 	f:close()
end

--
local oper_type = select(1, ...)
local config_file = select(2, ...)
local begin_revision = tonumber(select(3, ...) or "")

local tbl_oper_func = {}
tbl_oper_func["print_conflicts"] = print_conflicts
tbl_oper_func["auto_merge"] = auto_merge
local func = assert(tbl_oper_func[oper_type], string.format("Invalid oper_type(%s)", oper_type))
func(config_file, begin_revision)
