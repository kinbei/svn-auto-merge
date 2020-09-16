local config = {
	svn_cmd = 'svn --username \"xxx\" --password \"xxx\" --no-auth-cache',
	svn_url = "", -- svn url 地址
	svn_relative_to_root_path = "", -- 分支目录(相对于 svn url 的路径)
	workdir = "", -- 本地 svn 目录
	report_file = "", -- 冲突报告日志
	exclude_author = {"xxxxxx", }, -- 需要排除的作者, 支持多个
	last_merged_revision_store = "/path_to_last_merged_revision", -- 程序用于保存最后已经合并过的版本号
}
return config