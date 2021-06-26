# svn-auto-merge
将指定分支、指定版本的 svn 代码 合并到 指定的另一条分支，并在最后生成冲突文件列表。

- 支持系统    
`Linux`

- 快速开始

(1) 执行以下命令安装环境
```
git clone https://github.com/kinbei/svn-auto-merge
cd svn-auto-merge
git submodule update --init --recursive
make
```

(2) 假设将 A 分支修改合并至 B 分支    
a. 将 B 分支 checkout 到本地目录, 并将路径填写至 `zzz` 的位置    
b. 将 A 分支的 svn url 填写至 `yyy` 的位置    
c. 将 svn 用户名、密码填写至 `xxx` 的位置

```lua
local config = {
		svn_cmd = 'svn --username \"xxx\" --password \"xxx\" --no-auth-cache',
		svn_url = "yyy", -- svn url 地址
		svn_relative_to_root_path = "",
		workdir = "zzz", -- 本地 svn 目录
		report_file = "/path_to_report_file", -- 冲突报告日志
		execlude_rule = {},
		execlude_path = {},
		last_merged_revision_store = "/path_to_last_merged_revision", -- 程序用于保存最后已经合并过的版本号
		commit_log_fmt = [[merge from ${from_svn_relative_to_root_path} ${from_revision}|${from_commit_log}]], -- 合并代码后提交的 svn log 格式
		abort = false, -- 设置为 true 时表示出现冲突则停止继续合并
}
```
将以上内容保存为 `config.lua`   

(3) 第一次合并时, 必须指定 A 分支的版本号 ${REVISION} (将 A 分支 ${BEGIN_REVISION} 至 ${END_REVISION} 合并至 B 分支)
```
lua -e"package.path = package.path .. \";xml2lua/?.lua\"" ./auto_merge.lua "auto_merge" config.lua ${BEGIN_REVISION} ${END_REVISION}
```
注: `END_REVISION`可以不指定, 配置是 HEAD(最新 revision)    


