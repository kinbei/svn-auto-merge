local config = {
	svn_url = "", -- svn url 地址
	svn_relative_to_root_path = "", -- 分支目录(相对于 svn url 的路径)
	workdir = "", -- 本地 svn 目录
	report_file = "", -- 冲突报告日志
}
return config