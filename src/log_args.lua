-- Turns a log call's arguments into telemetry: a readable `message` string,
-- plus the arguments themselves as plain JSON-shaped values when any of them
-- is not a string.
--
--   Log:Debug("Response received:", { status = 200, body = "OK" })
--     message = "Response received: [table]"
--     args    = { "Response received:", { status = 200, body = "OK" } }
--
-- Encoding observes and never runs driver code: tables are walked with raw
-- `next`, and `tostring` is only applied to numbers and booleans, so a
-- metamethod cannot fire (or throw) from inside the logger. The result is a
-- fresh tree, bounded in depth, breadth and size; whatever the bounds cut is
-- replaced with a "[truncated]" marker and reported, so a reader can tell an
-- empty table from one that was too big to send.
local LogArgs = {}

LogArgs.limits = {
    depth = 6,          -- nesting levels below an argument
    entries = 100,      -- entries kept per table
    stringBytes = 2048, -- bytes kept per string
    nodes = 1000,       -- values encoded per log call
    bytes = 16384,      -- approximate encoded size per log call
}

local TRUNCATED = "[truncated]"

local function encodeNumber(value)
    -- JSON has no NaN or infinity.
    if value ~= value then return "nan" end
    if value == math.huge then return "inf" end
    if value == -math.huge then return "-inf" end
    return value
end

-- Only these render as themselves in `message`. tostring on anything else
-- could run a __tostring metamethod, and a table address helps nobody.
local function messagePart(value)
    local kind = type(value)
    if kind == "string" then return value end
    -- Non-finite numbers in their fixed form: tostring(0/0) is "nan" or
    -- "-nan" depending on the C library.
    if kind == "number" then return tostring(encodeNumber(value)) end
    if kind == "boolean" or kind == "nil" then return tostring(value) end
    return "[" .. kind .. "]"
end

-- Cut at a byte limit without splitting a UTF-8 sequence.
local function cutString(value, limit)
    local cut = limit
    while cut > 0 do
        local nextByte = value:byte(cut + 1)
        if not nextByte or nextByte < 0x80 or nextByte > 0xBF then break end
        cut = cut - 1
    end
    return value:sub(1, cut)
end

local function keyString(key)
    local kind = type(key)
    if kind == "string" then return key end
    if kind == "number" then
        if key == math.floor(key) and key > -1e15 and key < 1e15 then
            return string.format("%d", key)
        end
        return tostring(key)
    end
    if kind == "boolean" then return tostring(key) end
    return "[" .. kind .. "]"
end

local encode

local function encodeTable(ctx, value, depth)
    if ctx.onPath[value] then return "[cycle]" end
    if depth > LogArgs.limits.depth then
        ctx.truncated = true
        return TRUNCATED
    end

    -- Collect a bounded slice first: deciding array vs object needs the keys.
    -- It is an array when the keys are exactly 1..count, in whatever order
    -- `next` produced them (a table filled backwards keeps them in its hash).
    local keys, items, count = {}, {}, 0
    local integerKeys, maxKey, more = true, 0, false
    local key, item = next(value)
    while key ~= nil do
        if count >= LogArgs.limits.entries then more = true; break end
        count = count + 1
        keys[count], items[count] = key, item
        if type(key) == "number" and key >= 1 and key % 1 == 0 then
            if key > maxKey then maxKey = key end
        else
            integerKeys = false
        end
        key, item = next(value, key)
    end
    local isArray = integerKeys and maxKey == count

    ctx.onPath[value] = true
    local out = {}
    local stopped = false
    for i = 1, count do
        if isArray then
            out[i] = encode(ctx, rawget(value, i), depth + 1)
        else
            local name = keyString(keys[i])
            ctx.bytes = ctx.bytes + #name + 4
            -- Distinct keys can share a string form (1 and "1"); first wins.
            if out[name] == nil then out[name] = encode(ctx, items[i], depth + 1) end
        end
        if ctx.full then
            stopped = i < count
            break
        end
    end
    if more or stopped then
        if isArray then out[#out + 1] = TRUNCATED else out[TRUNCATED] = true end
    end
    ctx.onPath[value] = nil

    if more then ctx.truncated = true end
    return out
end

encode = function(ctx, value, depth)
    ctx.nodes = ctx.nodes + 1
    ctx.bytes = ctx.bytes + 8
    if ctx.nodes > LogArgs.limits.nodes or ctx.bytes > LogArgs.limits.bytes then
        ctx.full, ctx.truncated = true, true
        return TRUNCATED
    end

    local kind = type(value)
    if kind == "string" then
        local limit = math.min(LogArgs.limits.stringBytes, LogArgs.limits.bytes - ctx.bytes)
        if #value > limit then
            ctx.truncated = true
            value = cutString(value, math.max(limit, 0)) .. "…"
        end
        ctx.bytes = ctx.bytes + #value
        return value
    end
    if kind == "number" then return encodeNumber(value) end
    if kind == "boolean" then return value end
    if kind == "nil" then return "[nil]" end
    if kind == "table" then return encodeTable(ctx, value, depth) end
    return "[" .. kind .. "]"
end

-- Encode a packed argument list ({ n = count, ... }).
-- Returns message, args, truncated. `args` is nil when every argument is a
-- string: the message already carries them, and most log calls are text.
function LogArgs.encode(packed)
    local parts, structured = {}, false
    for i = 1, packed.n do
        local value = packed[i]
        parts[i] = messagePart(value)
        if type(value) ~= "string" then structured = true end
    end
    local message = table.concat(parts, " ")
    if not structured then return message, nil, false end

    local ctx = { nodes = 0, bytes = 0, onPath = {}, truncated = false, full = false }
    local args = {}
    for i = 1, packed.n do
        args[i] = encode(ctx, packed[i], 1)
        if ctx.full then
            if i < packed.n then args[i + 1] = TRUNCATED end
            break
        end
    end
    return message, args, ctx.truncated
end

return LogArgs
