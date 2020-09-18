LUA_MYCFLAGS := ""
ROOT_DIR := $(shell pwd)
LUA_VER := "5.4.0"

lua : 
	wget https://www.lua.org/ftp/lua-$(LUA_VER).tar.gz && \
	tar -xvf lua-$(LUA_VER).tar.gz && \
	cd ./lua-$(LUA_VER)/src/ && \
	make linux MYCFLAGS=$(LUA_MYCFLAGS) && \
	cd $(ROOT_DIR) && \
	ln -s ./lua-$(LUA_VER)/src/lua lua

all : \
	lua

clean:
	cd $(ROOT_DIR) && \
	rm -rf lua*
