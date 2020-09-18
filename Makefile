LUA_MYCFLAGS := ""
LUA_PACKAGE_PATH := "package.path = package.path .. \";testcase/?.lua;\";"
ROOT_DIR := $(shell pwd)

lua : 
	wget https://www.lua.org/ftp/lua-5.4.0.tar.gz && \
	tar -xvf lua-5.4.0.tar.gz && \
	cd ./lua-5.4.0/src/ && \
	make linux MYCFLAGS=$(LUA_MYCFLAGS) && \
	cd $(ROOT_DIR) && \
	ln -s ./lua-5.4.0/src/lua lua

all : \
	lua

clean:
	cd lua-src/lua-5.3.4/src/ && make clean
