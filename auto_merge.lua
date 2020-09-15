local function execute_command(command, ...)
	local handle = io.popen(string.format(command, ...), "r")
	local t = {}
	for line in handle:lines() do
		table.insert(t, line)
 	end
	local tbl_rc = {handle:close()}

	if tbl_rc[1] ~= true then
		print("execute_command|%s", string.format(command, ...))
		for k, v in pairs(tbl_rc) do
			print("k(%s) v(%s)", k, v)
		end
	end
	return t, tbl_rc
end

local function string_split(str, sep, func)
	local sep, fields = sep or ":", {}
	local pattern = string.format("([^%s]+)", sep)

	if func then
		string.gsub(str, pattern, function(c)
			fields[#fields+1] = func(c) 
		end)
	else
		string.gsub(str, pattern, function(c)
			fields[#fields+1] = c 
		end)
	end
	return fields
end

local function print_response(t)
	print("--------------- print_response -- begin")
	print(table.concat(t, "\n"))
	print("--------------- print_response -- end")
end

-- 从指定 url 获取 svn log, 并以 {revision = xx, author = xx} 格式的序列返回
local function get_log(svn_path, begin_revision)
	local t = {}
	for _, v in ipairs(execute_command("svn log %s -r%s:HEAD -q", svn_path, begin_revision)) do
		-- 去除 svn log 分割线
		if v == "------------------------------------------------------------------------" then
			goto continue
		end
		
		local tbl_field = string_split(v, "|")
		if #tbl_field ~= 3 then
			return false, string.format("invalid log: %s", v)
		end

		-- revision(rxxx )
		local revision = tonumber(tbl_field[1]:match("r([0-9]*) "))
		-- author( xxx )
		local author = tbl_field[2]:match(" (%g*) ")
		if not revision or not author then
			return false, string.format("invalid revision or author: %s", v)
		end

		table.insert(t, {revision = revision, author = author})
		::continue::
	end

	return true, t
end

--
local function revert_dir(workdir)
	execute_command("svn revert --depth infinity %s", workdir)
end

--
local function update_dir(workdir)
	execute_command("svn update %s", workdir)
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

	local tbl_merge_response = execute_command("svn merge ^%s -c%s %s --accept 'postpone'", svn_relative_to_root_path, revision, workdir)
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
		print(op, file)
		if not tbl_merged_item_op[op] then
			return false, string.format("error|merge|invalid merged item|%s|%s", tbl_merge_response[i], op)
		end

		-- 记录冲突文件并还原
		if op == 'C' then
			table.insert(tbl_conflicts, file)
			execute_command("svn revert %s@", file) -- 当文件路径中包含 @ 字符时, 需要在未尾也加上 @
			print(string.format("revert %s", file))
		else
			table.insert(tbl_normal, file)
		end

		::continue::
	end

	if #tbl_normal > 0 then
		local r = execute_command("svn commit -m\"merge from %s %s\" %s", svn_relative_to_root_path, revision, workdir)
		for _, v in ipairs(r) do
			print(string.format("commit %s", v))
		end
	end
	return true, tbl_conflicts
end

--
local config_file = select(1, ...)
local begin_revision = tonumber(select(2, ...))
local config = require(config_file)
if not config then
	error(string.format("Failed to require %s", config_file))
end

local svn_url = config.svn_url
local svn_relative_to_root_path = config.svn_relative_to_root_path
local workdir = config.workdir
local report_file = config.report_file
local tbl_exclude_author = config.exclude_author
local svn_path = string.format("%s%s", svn_url, svn_relative_to_root_path)
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

local function check_exclude_author(author)
	for _, v in ipairs(tbl_exclude_author) do
		if author == v then
			return true
		end
	end

	return false
end

revert_dir(workdir)
update_dir(workdir)
local success, msg = get_log(svn_path, begin_revision)
if success then
	local tbl_log = msg
	for _, v in ipairs(tbl_log) do
		--
		print(string.format("merge revision = [%s], author = [%s]", v.revision, v.author))
		if v.revision <= begin_revision then
			goto continue
		end

		if check_exclude_author(v.author) then
			print(string.format("Skip|exclude_author(%s)|revision(%s)", v.author, v.revision))
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

					local relative_to_root_path = conflicts_file:match(string.format("^%s(.*)$", workdir))
					table.insert(tbl_final_report[v.author][v.revision], relative_to_root_path)

					f:write(string.format("%s|%s|%s\n", v.author, v.revision, relative_to_root_path))
				end

				f:close()
			end
		end
		::continue::
	end

	-- 输出最终报告
	local f = io.output()
	for author, v1 in pairs(tbl_final_report) do
		f:write(string.format("%s\n", author))
		for revision, tbl_relative_to_root_path in pairs(v1) do
			f:write(string.format("\t merge %s %s\n", svn_relative_to_root_path, revision))
			for _, relative_to_root_path in ipairs(tbl_relative_to_root_path) do
				f:write(string.format("\t\t%s\n", relative_to_root_path))
			end
		end
	end
	f:close()
else
	error(msg)
end
