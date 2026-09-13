-- First-party bounded diagnostic capture. Plain data only: no formatting,
-- transport, JSON encoder, application metamethods, or retained snapshots.
local Diagnostics = {}
local registry = setmetatable({}, { __mode = 'k' })
local knownTables = { [_G] = '_G' }
for _, name in ipairs({ 'string', 'table', 'math', 'coroutine', 'debug', 'package', 'io', 'os', 'bit', 'jit' }) do
    local value = rawget(_G, name)
    if type(value) == 'table' then knownTables[value] = name end
end
local nativeNames = setmetatable({}, { __mode = 'k' })
for name, value in next, _G do
    if type(name) == 'string' and type(value) == 'function' then
        nativeNames[value] = name
    end
end
local limits = { stringBytes = 512, depth = 3, entries = 20, frames = 64,
    locals = 64, nodes = 1024, totalStringBytes = 8192, encodedBytes = 262144 }

function Diagnostics.registerFunction(fn, metadata)
    if type(fn) == 'function' then registry[fn] = metadata end
end

local function reason(ctx, code)
    ctx.trace.status = 'partial'
    if not ctx.reasons[code] then
        ctx.reasons[code] = true
        ctx.trace.reasons = ctx.trace.reasons or {}
        ctx.trace.reasons[#ctx.trace.reasons + 1] = code
    end
end

-- Reserve conservative JSON bytes, including keys, punctuation and numbers.
-- String contents are charged separately at the maximum escaping expansion.
local function reserve(ctx, bytes)
    if ctx.bytes + bytes > limits.encodedBytes - 1024 then
        reason(ctx, 'payload_limit')
        return false
    end
    ctx.bytes = ctx.bytes + bytes
    return true
end

-- Inspect at most a captured prefix. Returns a complete UTF-8 prefix length,
-- or nil for binary/invalid UTF-8. Never execute tostring on driver values.
local function utf8Prefix(value, truncated)
    local i, size = 1, #value
    while i <= size do
        local a = value:byte(i)
        if a == 0 then return nil end
        local width = a < 128 and 1 or (a >= 194 and a <= 223 and 2
            or (a >= 224 and a <= 239 and 3 or (a >= 240 and a <= 244 and 4 or 0)))
        if width == 0 then return nil end
        if i + width - 1 > size then return truncated and i - 1 or nil end
        for j = 1, width - 1 do
            local b = value:byte(i + j)
            if b < 128 or b > 191 then return nil end
        end
        local b = value:byte(i + 1)
        if (a == 224 and b < 160) or (a == 237 and b > 159)
            or (a == 240 and b < 144) or (a == 244 and b > 143) then return nil end
        i = i + width
    end
    return size
end

local function captureString(ctx, value)
    local allowed = math.min(limits.stringBytes, limits.totalStringBytes - ctx.stringBytes)
    local count = math.min(#value, math.max(0, allowed))
    local prefix = value:sub(1, count)
    local valid = utf8Prefix(prefix, count < #value)
    local node = { type = 'string' }
    if valid then
        prefix = prefix:sub(1, valid)
        count = valid
    else
        node.encoding = 'hex'
        prefix = (prefix:gsub('.', function(c) return string.format('%02x', c:byte()) end))
    end
    if not reserve(ctx, #prefix * 6) then
        return { type = 'unavailable', reason = 'payload_limit' }
    end
    ctx.stringBytes = ctx.stringBytes + count
    node.value = prefix
    if count < #value then
        local code = allowed < limits.stringBytes and 'string_budget' or 'string_limit'
        node.originalBytes, node.truncated, node.reason = #value, true, code
        reason(ctx, code)
    elseif node.encoding then
        node.originalBytes = #value
    end
    return node
end

local function metadataString(ctx, value)
    if type(value) ~= 'string' then return nil end
    local captured = captureString(ctx, value)
    -- Metadata names are text; omit binary names rather than imply hex is a name.
    if captured.encoding or captured.type == 'unavailable' then return nil end
    return captured.value
end

local function sourceInfo(ctx, info)
    if info.what == 'C' or not info.source then return nil end
    local first = info.source:sub(1, 1)
    local kind = first == '@' and 'file' or (first == '#' and 'template' or 'chunk')
    local name
    if first == '@' or first == '#' or first == '=' then
        name = info.source:sub(2, limits.stringBytes + 1)
        if #info.source > limits.stringBytes + 1 then reason(ctx, 'string_limit') end
    else
        name = info.short_src
    end
    name = metadataString(ctx, name)
    if name then return { kind = kind, name = name } end
end

local function functionInfo(ctx, info)
    local registered = registry[info.func]
    local name = registered and registered.functionName or info.name or nativeNames[info.func]
    local origin = registered and registered.functionName and 'registered' or (name and 'debug')
    -- In-memory chunk inference only. Bounded scan; no filesystem access.
    if not name and info.source and info.source:sub(1, 1) ~= '@'
        and info.source:sub(1, 1) ~= '=' and info.linedefined and info.linedefined > 0 then
        local lineNumber = 0
        for line in (info.source:sub(1, 8192) .. '\n'):gmatch('(.-)\n') do
            lineNumber = lineNumber + 1
            if lineNumber == info.linedefined then
                name = line:match('^%s*local%s+function%s+([%w_]+)')
                    or line:match('^%s*function%s+([%w_%.:]+)')
                    or line:match('^%s*local%s+([%w_]+)%s*=%s*function')
                if name then origin = 'inferred' end
                break
            end
        end
    end
    return metadataString(ctx, name), origin, registered
end

local function identity(ctx, value)
    local id = ctx.ids[value]
    if not id then
        ctx.nextId = ctx.nextId + 1
        id = ctx.nextId
        ctx.ids[value] = id
    end
    return id
end

local captureValue
captureValue = function(ctx, value, depth)
    if ctx.nodes >= limits.nodes - ctx.pending then
        reason(ctx, 'node_limit')
        return { type = 'unavailable', reason = 'node_limit' }
    end
    ctx.nodes = ctx.nodes + 1
    if not reserve(ctx, 192) then return { type = 'unavailable', reason = 'payload_limit' } end
    local kind = type(value)
    if kind == 'nil' then return { type = 'nil' } end
    if kind == 'boolean' then return { type = kind, value = value } end
    if kind == 'number' then
        if value ~= value then value = 'nan'
        elseif value == math.huge then value = 'positive_infinity'
        elseif value == -math.huge then value = 'negative_infinity' end
        return { type = kind, value = value }
    end
    if kind == 'string' then return captureString(ctx, value) end
    if ctx.ids[value] then return { type = 'reference', ref = ctx.ids[value] } end
    if kind == 'table' then
        local node = { type = 'table', id = identity(ctx, value) }
        local known = knownTables[value]
        if known then node.knownName = known; return node end
        if depth > limits.depth then
            node.truncated, node.reason = true, 'depth_limit'
            reason(ctx, node.reason)
            return node
        end
        local key, item = next(value)
        local count = 0
        while key ~= nil do
            local code
            if count >= limits.entries then code = 'entry_limit'
            elseif ctx.nodes + 2 > limits.nodes - ctx.pending then code = 'node_limit'
            elseif not reserve(ctx, 32) then code = 'payload_limit' end
            if code then
                node.truncated, node.reason = true, code
                reason(ctx, code)
                break
            end
            -- Reserve the value root before traversing a possibly large key.
            -- Every emitted node, including unavailable markers, counts.
            ctx.pending = ctx.pending + 1
            local capturedKey = captureValue(ctx, key, depth + 1)
            ctx.pending = ctx.pending - 1
            local entry = { key = capturedKey, value = captureValue(ctx, item, depth + 1) }
            node.entries = node.entries or {}
            node.entries[#node.entries + 1] = entry
            count = count + 1
            key, item = next(value, key)
        end
        return node
    end
    if kind == 'function' then
        local info = debug.getinfo(value, 'nSf')
        local name = functionInfo(ctx, info)
        return { type = kind, id = identity(ctx, value), functionName = name,
            source = sourceInfo(ctx, info), definitionLine = info.linedefined > 0 and info.linedefined or nil }
    end
    if kind == 'userdata' or kind == 'thread' or kind == 'cdata' then
        return { type = kind, id = identity(ctx, value) }
    end
    return { type = 'unavailable', reason = 'unsupported_type' }
end

local function collect(ctx, options)
    local started = false
    local boundary = options.boundary or Diagnostics.capture
    local level, count = 2, 0
    while true do
        local info = debug.getinfo(level, 'nSlf')
        if not info then break end
        if not started then
            if info.func == boundary then started = true end
        else
            local registered = registry[info.func]
            local leadingRaise = count == 0 and (info.func == error or info.func == assert)
            if not leadingRaise and not (registered and registered.skip) then
                if count >= limits.frames then reason(ctx, 'frame_limit'); break end
                if not reserve(ctx, 384) then break end
                local name, origin, metadata = functionInfo(ctx, info)
                local kind = ({ Lua = 'lua', C = 'native', main = 'main', tail = 'tail' })[info.what] or 'unknown'
                local frame = { kind = kind, functionName = name, nameOrigin = origin,
                    source = sourceInfo(ctx, info), line = info.currentline > 0 and info.currentline or nil,
                    definitionLine = info.linedefined > 0 and info.linedefined or nil,
                    role = metadata and metadata.role or (kind == 'native' and 'runtime' or nil) }
                ctx.trace.frames = ctx.trace.frames or {}
                ctx.trace.frames[#ctx.trace.frames + 1] = frame
                count = count + 1
                if kind == 'lua' or kind == 'main' then
                    for i = 1, limits.locals + 1 do
                        -- getlocal must run at the same call depth as getinfo.
                        local localName, value = debug.getlocal(level, i)
                        if not localName then break end
                        if i > limits.locals then reason(ctx, 'local_limit'); break end
                        if ctx.nodes >= limits.nodes then reason(ctx, 'node_limit'); break end
                        if not reserve(ctx, 96) then break end
                        local localData = { name = metadataString(ctx, localName) or '', value = captureValue(ctx, value, 1) }
                        frame.locals = frame.locals or {}
                        frame.locals[#frame.locals + 1] = localData
                    end
                end
            end
        end
        level = level + 1
        -- Bound boundary search too (bad/missing boundaries cannot scan forever).
        if level > limits.frames + 64 then
            if started then reason(ctx, 'frame_limit') end
            break
        end
    end
    if not started then
        ctx.trace.status, ctx.trace.reasons = 'failed', { 'capture_failed' }
    end
end

function Diagnostics.capture(options)
    options = options or {}
    local ctx = { trace = { schemaVersion = 1, captureKind = options.captureKind or 'callsite', status = 'complete' },
        reasons = {}, ids = {}, nextId = 0, nodes = 0, pending = 0, stringBytes = 0, bytes = 256 }
    local ok = pcall(collect, ctx, options)
    if not ok then
        reason(ctx, 'capture_failed')
        if not ctx.trace.frames then ctx.trace.status = 'failed' end
    end
    return ctx.trace
end

return Diagnostics
