-- Path of Building API Server
-- Non-blocking HTTP/JSON server polled from the main frame loop.
-- Usage: local api = require("APIServer"); api:Start(); -- then call api:Poll() each frame

local socket = require("socket")
local json   = require("dkjson")

local PORT            = 49185
local MAX_CONNECTIONS = 8
local MAX_BODY        = 256 * 1024  -- 256 KB

local M = {}
M.__index = M

function M.new()
	local self = setmetatable({}, M)
	self.routes      = {}   -- {method, pattern, paramNames, handler}
	self.connections = {}   -- {sock, buf}
	self.server      = nil
	self.running     = false
	return self
end

-- Register a route.  Path segments starting with ':' are named captures.
-- handler(req, params) → value  (any JSON-serialisable table or scalar)
function M:Route(method, path, handler)
	local paramNames = {}
	local pattern = "^" .. path:gsub(":([%w_]+)", function(name)
		table.insert(paramNames, name)
		return "([^/]+)"
	end) .. "$"
	table.insert(self.routes, {
		method     = method:upper(),
		pattern    = pattern,
		paramNames = paramNames,
		handler    = handler,
	})
end

function M:Start()
	local srv, err = socket.tcp4()
	if not srv then
		ConPrintf("[API] socket.tcp4 failed: %s", tostring(err))
		return false
	end
	srv:setoption("reuseaddr", true)
	local ok
	ok, err = srv:bind("localhost", PORT)
	if not ok then
		ConPrintf("[API] bind failed: %s", tostring(err))
		srv:close()
		return false
	end
	srv:listen(MAX_CONNECTIONS)
	srv:settimeout(0)
	self.server  = srv
	self.running = true
	ConPrintf("[API] Server listening on http://localhost:%d", PORT)
	return true
end

function M:Stop()
	for _, c in ipairs(self.connections) do pcall(c.sock.close, c.sock) end
	self.connections = {}
	if self.server then self.server:close(); self.server = nil end
	self.running = false
end

-- Call once per frame.
function M:Poll()
	if not self.running then return end

	-- Accept new connections (non-blocking)
	if #self.connections < MAX_CONNECTIONS then
		local client = self.server:accept()
		if client then
			client:settimeout(0)
			table.insert(self.connections, {sock = client, buf = ""})
		end
	end

	-- Read from / respond to active connections
	local dead = {}
	for i, c in ipairs(self.connections) do
		local data, err, partial = c.sock:receive(8192)
		local chunk = data or partial or ""
		if #chunk > 0 then c.buf = c.buf .. chunk end

		if #c.buf > MAX_BODY then
			self:SendResponse(c.sock, 413, {error = "Request too large"})
			table.insert(dead, i)
		else
			local req = self:ParseHTTP(c.buf)
			if req then
				local resp = self:Dispatch(req)
				self:SendRaw(c.sock, resp)
				table.insert(dead, i)
			elseif err and err ~= "timeout" then
				table.insert(dead, i)
			end
		end
	end

	for i = #dead, 1, -1 do
		local c = self.connections[dead[i]]
		pcall(c.sock.close, c.sock)
		table.remove(self.connections, dead[i])
	end
end

-- ── HTTP parsing ─────────────────────────────────────────────────────────────

function M:ParseHTTP(buf)
	local hdrEnd = buf:find("\r\n\r\n", 1, true)
	if not hdrEnd then return nil end

	local hdrBlock = buf:sub(1, hdrEnd - 1)
	local bodyStart = hdrEnd + 4

	local method, rawPath = hdrBlock:match("^(%S+) (%S+)")
	if not method then return nil end

	-- Parse headers
	local headers = {}
	for line in hdrBlock:gmatch("\r\n([^\r\n]+)") do
		local k, v = line:match("^([^:]+):%s*(.+)$")
		if k then headers[k:lower()] = v end
	end

	-- Body
	local contentLen = tonumber(headers["content-length"] or 0)
	local body = ""
	if contentLen > 0 then
		local avail = buf:sub(bodyStart)
		if #avail < contentLen then return nil end  -- wait for more
		body = avail:sub(1, contentLen)
	end

	-- Path + query
	local path, qs = rawPath:match("^([^?]+)%??(.*)$")
	local query = {}
	if qs then
		for k, v in qs:gmatch("([^&=]+)=([^&=]*)") do
			query[self:URLDecode(k)] = self:URLDecode(v)
		end
	end

	local parsedBody = nil
	if #body > 0 then
		parsedBody = json.decode(body)
	end

	return {method=method:upper(), path=path, query=query,
	        headers=headers, body=parsedBody, rawBody=body}
end

function M:URLDecode(s)
	return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	         :gsub("+", " ")
end

-- ── Routing ───────────────────────────────────────────────────────────────────

function M:Dispatch(req)
	-- CORS preflight
	if req.method == "OPTIONS" then
		return self:BuildResponse(204, nil, {
			["Access-Control-Allow-Origin"]  = "*",
			["Access-Control-Allow-Methods"] = "GET,POST,DELETE,OPTIONS",
			["Access-Control-Allow-Headers"] = "Content-Type",
		})
	end

	for _, route in ipairs(self.routes) do
		if route.method == req.method or route.method == "ANY" then
			local captures = {req.path:match(route.pattern)}
			if #captures > 0 or req.path:match(route.pattern) ~= nil then
				local params = {}
				for i, name in ipairs(route.paramNames) do
					params[name] = captures[i]
				end
				local ok, result = pcall(route.handler, req, params)
				if ok then
					local status = 200
					local body   = result
					if type(result) == "table" and result._status then
						status = result._status
						body   = result._body
					end
					return self:BuildResponse(status, body)
				else
					ConPrintf("[API] Handler error: %s", tostring(result))
					return self:BuildResponse(500, {error = tostring(result)})
				end
			end
		end
	end

	return self:BuildResponse(404, {error="Not found", path=req.path})
end

function M:BuildResponse(status, body, extraHeaders)
	local statusText = ({
		[200]="OK", [201]="Created", [204]="No Content",
		[400]="Bad Request", [404]="Not Found",
		[405]="Method Not Allowed", [413]="Payload Too Large",
		[500]="Internal Server Error",
	})[status] or "OK"

	local bodyStr = ""
	if body ~= nil then
		local ok, encoded = pcall(json.encode, body, {indent=false})
		bodyStr = ok and encoded or json.encode({error="Serialisation failed"})
	end

	local lines = {
		string.format("HTTP/1.1 %d %s", status, statusText),
		"Content-Type: application/json",
		"Access-Control-Allow-Origin: *",
		"Connection: close",
		string.format("Content-Length: %d", #bodyStr),
	}
	for k, v in pairs(extraHeaders or {}) do
		table.insert(lines, k .. ": " .. v)
	end
	table.insert(lines, "")
	table.insert(lines, bodyStr)
	return table.concat(lines, "\r\n")
end

function M:SendRaw(sock, raw)
	local sent, total = 0, #raw
	while sent < total do
		local n, err = sock:send(raw, sent + 1)
		if not n then break end
		sent = sent + n
	end
end

function M:SendResponse(sock, status, body)
	self:SendRaw(sock, self:BuildResponse(status, body))
end

-- Helper used by handlers to return a non-200 status
function M.Respond(status, body)
	return {_status = status, _body = body}
end

return M
