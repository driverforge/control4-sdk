local withDebugStubs = require 'spec.support.with_debug_stubs'
local Diagnostics = require 'diagnostics'
local json = require 'dkjson'

-- Count the emitted contract nodes, including unavailable placeholders and
-- references; internal work counters alone do not establish the wire limit.
local function inspectValues(trace)
    local count, ids, references = 0, {}, {}
    local function visit(node)
        count = count + 1
        if node.id then
            assert.is_nil(ids[node.id], 'duplicate identity definition')
            ids[node.id] = node.type
        end
        if node.type == 'reference' then references[#references + 1] = node.ref end
        for _, entry in ipairs(node.entries or {}) do
            visit(entry.key)
            visit(entry.value)
        end
    end
    for _, frame in ipairs(trace.frames or {}) do
        for _, item in ipairs(frame.locals or {}) do visit(item.value) end
    end
    for _, ref in ipairs(references) do assert.is_not_nil(ids[ref], 'unresolved reference') end
    return count, ids, references
end

-- Synthetic debug metadata makes large stacks deterministic and independent
-- of the test runner's own locals. Actual function metadata still uses Lua.
local function syntheticTrace(frames, localAt, sourceName, skipped)
    local originalInfo = debug.getinfo
    local visits = 0
    local function subject() end
    if skipped then Diagnostics.registerFunction(subject, { skip = true }) end
    local getinfo = function(level, options)
        if type(level) == 'function' then return originalInfo(level, options) end
        visits = visits + 1
        if level > frames + 2 then return nil end
        return {
            func = level == 2 and Diagnostics.capture or subject,
            what = 'Lua', name = sourceName or 'subject', source = '@' .. (sourceName or 'driver.lua'),
            currentline = level, linedefined = 1,
        }
    end
    local trace = withDebugStubs({
        getinfo = getinfo,
        getlocal = function(level, index) return localAt(level, index) end,
    }, function() return Diagnostics.capture() end)
    return trace, visits
end

local function tree(depth, width, leaf)
    if depth == 0 then return leaf end
    local result = {}
    for i = 1, width do result[i] = tree(depth - 1, width, leaf) end
    return result
end

describe('diagnostic wire bounds and identities', function()
    it('bounds encoded bytes for many locals, nested tables and escaped metadata', function()
        local subject = tree(3, 20, string.rep('\1\"\\', 400))
        local longName = string.rep('\1\"\\', 1000)
        local trace = syntheticTrace(1000, function(_, index)
            if index <= 100 then return longName .. index, subject end
        end, longName)
        local encoded = json.encode(trace)
        assert.is_true(#encoded <= 256 * 1024, 'encoded bytes: ' .. #encoded)
        assert.is_true(inspectValues(trace) <= 1024)
        assert.are.equal('partial', trace.status)
    end)

    it('counts value placeholders when nested table keys exhaust the node budget', function()
        -- A table key can consume the remaining budget before its associated
        -- value is captured. Every emitted placeholder still counts as a node.
        local subjects = {}
        for i = 1, 64 do
            subjects[i] = { [tree(2, 20, i)] = tree(2, 20, i) }
        end
        local trace = syntheticTrace(64, function(_, index)
            if subjects[index] then return 'local' .. index, subjects[index] end
        end)
        local count = inspectValues(trace)
        local reasons = {}
        for _, code in ipairs(trace.reasons or {}) do reasons[code] = true end
        assert.is_true(reasons.node_limit, 'fixture must exercise node exhaustion')
        assert.is_true(count <= 1024, 'emitted value nodes: ' .. count)
        assert.is_true(#json.encode(trace) <= 256 * 1024)
    end)

    it('resolves repeated functions, tables and threads without duplicate definitions', function()
        local function callback() end
        local thread = coroutine.create(callback)
        local shared = {}
        shared.self = shared
        local values = { callback, callback, shared, shared, thread, thread }
        local trace = syntheticTrace(1, function(_, index)
            if values[index] then return 'local' .. index, values[index] end
        end)
        local _, ids, references = inspectValues(trace)
        assert.are.equal('function', ids[1])
        assert.are.equal('table', ids[2])
        assert.are.equal('thread', ids[3])
        assert.are.equal(4, #references)
    end)

    it('bounds scanning even when every frame is registered to be skipped', function()
        local trace, visits = syntheticTrace(1000000, function() error('skipped locals inspected') end, nil, true)
        assert.is_true(visits <= 128, 'debug frames scanned: ' .. visits)
        assert.is_nil(trace.frames)
        assert.are.equal('partial', trace.status)
        assert.are.same({ 'frame_limit' }, trace.reasons)
    end)

    it('keeps committed collector fixtures within bounds with resolvable references', function()
        local file = assert(io.open('spec/fixtures/diagnostics/collector.json', 'rb'))
        local contents = file:read('*a')
        file:close()
        local fixtures, _, err = json.decode(contents)
        assert.is_nil(err)
        for _, trace in pairs(fixtures) do
            assert.are.equal(1, trace.schemaVersion)
            assert.is_true(inspectValues(trace) <= 1024)
            assert.is_true(#json.encode(trace) <= 256 * 1024)
        end
    end)

    it('infers an unnamed function from in-memory source without filesystem reads', function()
        local factory = assert((loadstring or load)([[
local function hidden_name()
    return 1
end
return hidden_name
]]))
        local subject = factory()
        local trace = syntheticTrace(1, function(_, index)
            if index == 1 then return 'callback', subject end
        end)
        local value = trace.frames[1].locals[1].value
        assert.are.equal('hidden_name', value.functionName)
        assert.are.equal('chunk', value.source.kind)
        assert.are.equal(1, value.definitionLine)
    end)
end)
