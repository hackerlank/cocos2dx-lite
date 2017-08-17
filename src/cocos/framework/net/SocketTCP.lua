--[[
@ref https://github.com/chukong/quick-cocos2d-x/blob/master/framework/cc/net/SocketTCP.lua
]]
local SOCKET_TICK_TIME = 0.1            -- check socket data interval
local SOCKET_RECONNECT_TIME = 5         -- socket reconnect try interval
local SOCKET_CONNECT_FAIL_TIMEOUT = 3   -- socket failure timeout

local STATUS_CLOSED = "closed"
local STATUS_NOT_CONNECTED = "Socket is not connected"
local STATUS_ALREADY_CONNECTED = "already connected"
local STATUS_ALREADY_IN_PROGRESS = "Operation already in progress"
local STATUS_TIMEOUT = "timeout"

local scheduler = require ("cocos.framework.scheduler")
local socket    = require("luasocket.socket")

local SocketTCP = class("SocketTCP")

SocketTCP.EVENT_DATA = "SOCKET_TCP_DATA"
SocketTCP.EVENT_CLOSE = "SOCKET_TCP_CLOSE"
SocketTCP.EVENT_CLOSED = "SOCKET_TCP_CLOSED"
SocketTCP.EVENT_CONNECTED = "SOCKET_TCP_CONNECTED"
SocketTCP.EVENT_CONNECT_FAILURE = "SOCKET_TCP_CONNECT_FAILURE"

SocketTCP._VERSION = socket._VERSION
SocketTCP._DEBUG = socket._DEBUG

function SocketTCP.getTime()
    return socket.gettime()
end

function SocketTCP:ctor(__host, __port, __retryConnectWhenFailure)
    cc.load('event'):bind(self)

    self.host = __host
    self.port = __port
    self.tickScheduler = nil            -- timer for data
    self.reconnectScheduler = nil       -- timer for reconnect
    self.connectTimeTickScheduler = nil -- timer for connect timeout
    self.name = 'SocketTCP'
    self.tcp = nil
    self.isRetryConnect = __retryConnectWhenFailure
    self.isConnected = false
end

function SocketTCP:setName( __name )
    self.name = __name
    return self
end

function SocketTCP:setTickTime(__time)
    SOCKET_TICK_TIME = __time
    return self
end

function SocketTCP:setReconnTime(__time)
    SOCKET_RECONNECT_TIME = __time
    return self
end

function SocketTCP:setConnFailTime(__time)
    SOCKET_CONNECT_FAIL_TIMEOUT = __time
    return self
end

function SocketTCP:connect(__host, __port, __retryConnectWhenFailure)
    print('> connect', __host, __port)
    if __host then self.host = __host end
    if __port then self.port = __port end
    if __retryConnectWhenFailure ~= nil then self.isRetryConnect = __retryConnectWhenFailure end
    assert(self.host or self.port, "Host and port are necessary!")
    -- printInfo("%s.connect(%s, %d)", self.name, self.host, self.port)
    self.tcp = self:createSocket()
    self.tcp:settimeout(0)
    self.tcp:setoption("tcp-nodelay", true)  --去掉优化

    local function __checkConnect()
        local __succ = self:_connect()
        if __succ then
            self:_onConnected()
        end
        return __succ
    end

    if not __checkConnect() then
        -- check whether connection is success
        -- the connection is failure if socket isn't connected after SOCKET_CONNECT_FAIL_TIMEOUT seconds
        local __connectTimeTick = function ()
            --printInfo("%s.connectTimeTick", self.name)
            if self.isConnected then return end
            self.waitConnect = self.waitConnect or 0
            self.waitConnect = self.waitConnect + SOCKET_TICK_TIME
            if self.waitConnect >= SOCKET_CONNECT_FAIL_TIMEOUT then
                self.waitConnect = nil
                self:close()
                self:_connectFailure()
            end
            __checkConnect()
        end
        self.connectTimeTickScheduler = scheduler.scheduleGlobal(__connectTimeTick, SOCKET_TICK_TIME)
    end
end

function SocketTCP:send(__data)
    assert(self.isConnected, self.name .. " is not connected.")
    return self.tcp:send(__data)
end

function SocketTCP:close( ... )
    --printInfo("%s.close", self.name)
    self.tcp:close();
    if self.connectTimeTickScheduler then scheduler.unscheduleGlobal(self.connectTimeTickScheduler) end
    if self.tickScheduler then scheduler.unscheduleGlobal(self.tickScheduler) end
    self:dispatchEvent({name=SocketTCP.EVENT_CLOSE})
end

-- disconnect on user's own initiative.
function SocketTCP:disconnect()
    self:_disconnect()
    self.isRetryConnect = false -- initiative to disconnect, no reconnect.
end

function SocketTCP:isSupportIpv6()
    local ipv6 = false
    local client = socket.connect("www.baidu.com", 80)
    if not client then return ipv6 end

    local ip = client:getsockname()
    if string.find(ip, ":") ~= nil then
        ipv6 = true
    end

    return ipv6
end

function SocketTCP:createSocket(  )
    if self:isSupportIpv6() then
        return socket.tcp6()
    end
    return socket.tcp()
end

--------------------
-- private
--------------------

--- When connect a connected socket server, it will return "already connected"
-- @see: http://lua-users.org/lists/lua-l/2009-10/msg00584.html
function SocketTCP:_connect()
    local __succ, __status = self.tcp:connect(self.host, self.port)
    -- print("SocketTCP._connect:", __succ, __status)
    return __succ == 1 or __status == STATUS_ALREADY_CONNECTED
end

function SocketTCP:_disconnect()
    self.isConnected = false
    self.tcp:shutdown()
    self:dispatchEvent({name=SocketTCP.EVENT_CLOSED})
end

function SocketTCP:_onDisconnect()
    --printInfo("%s._onDisConnect", self.name);
    self.isConnected = false
    self:dispatchEvent({name=SocketTCP.EVENT_CLOSED})
    self:_reconnect();
end

-- connecte success, cancel the connection timerout timer
function SocketTCP:_onConnected()
    --printInfo("%s._onConnectd", self.name)
    self.isConnected = true
    self:dispatchEvent({name=SocketTCP.EVENT_CONNECTED})
    if self.connectTimeTickScheduler then scheduler.unscheduleGlobal(self.connectTimeTickScheduler) end

    local _tick = function()
        --检测是否有可读的socket
        local recvt, sendt, status = socket.select({self.tcp}, nil, 0)
        if #recvt <= 0 then
            return
        end

        while true do
            -- if use "*l" pattern, some buffer will be discarded, why?
            local __body, __status, __partial = self.tcp:receive("*a")  -- read the package body
            -- print("body:", __body, "__status:", __status, "__partial:", __partial)
            if __status == STATUS_CLOSED or __status == STATUS_NOT_CONNECTED then
                self:close()
                if self.isConnected then
                    self:_onDisconnect()
                else
                    self:_connectFailure()
                end
                return
            end
            if  (__body and string.len(__body) == 0) or
                (__partial and string.len(__partial) == 0)
            then return end
            if __body and __partial then __body = __body .. __partial end
            self:dispatchEvent({name=SocketTCP.EVENT_DATA, data=(__partial or __body), partial=__partial, body=__body})
        end
    end

    -- start to read TCP data
    self.tickScheduler = scheduler.scheduleGlobal(_tick, SOCKET_TICK_TIME)
end

function SocketTCP:_connectFailure(status)
    --printInfo("%s._connectFailure", self.name);
    self:dispatchEvent({name=SocketTCP.EVENT_CONNECT_FAILURE})
    self:_reconnect();
end

-- if connection is initiative, do not reconnect
function SocketTCP:_reconnect(__immediately)
    if not self.isRetryConnect then return end
    printInfo("%s._reconnect", self.name)
    if __immediately then self:connect() return end
    if self.reconnectScheduler then scheduler.unscheduleGlobal(self.reconnectScheduler) end
    local __doReConnect = function ()
        self:connect()
    end
    self.reconnectScheduler = scheduler.performWithDelayGlobal(__doReConnect, SOCKET_RECONNECT_TIME)
end

return SocketTCP