local withDebugStubs = require 'spec.support.with_debug_stubs'
local Diagnostics = require 'diagnostics'

local function findLocal(trace, name)
    for _, frame in ipairs(trace.frames or {}) do
        for _, item in ipairs(frame.locals or {}) do
            if item.name == name then return item.value end
        end
    end
end

local function captureSubject(subject)
    local trace = Diagnostics.capture({ captureKind = 'callsite' })
    return trace, subject
end

local function entry(node, key)
    for _, item in ipairs(node.entries or {}) do
        if item.key.value == key then return item.value end
    end
end

describe('structured diagnostics', function()
    it('captures typed locals and source without presentation fields', function()
        local trace = captureSubject({ count = 3, enabled = true, text = 'hello' })
        assert.are.equal(1, trace.schemaVersion)
        assert.are.equal('callsite', trace.captureKind)
        local subject = findLocal(trace, 'subject')
        assert.are.equal('table', subject.type)
        assert.same({ type = 'number', value = 3 }, entry(subject, 'count'))
        assert.same({ type = 'boolean', value = true }, entry(subject, 'enabled'))
        assert.same({ type = 'string', value = 'hello' }, entry(subject, 'text'))
        assert.is_nil(trace.frames[1].text)
        assert.are.equal('file', trace.frames[1].source.kind)
    end)

    it('distinguishes numeric and string table keys', function()
        local node = findLocal(captureSubject({ [1] = 'numeric', ['1'] = 'text' }), 'subject')
        assert.are.equal('numeric', entry(node, 1).value)
        assert.are.equal('text', entry(node, '1').value)
    end)

    it('represents cycles and shared identities as references', function()
        local subject = {}
        subject.self = subject
        local node = findLocal(captureSubject(subject), 'subject')
        assert.same({ type = 'reference', ref = node.id }, entry(node, 'self'))
    end)

    it('does not invoke application metamethods', function()
        local calls = 0
        local function fail() calls = calls + 1; error('must not execute') end
        local subject = setmetatable({ value = 7 }, { __tostring = fail, __pairs = fail, __index = fail })
        local node = findLocal(captureSubject(subject), 'subject')
        assert.are.equal(7, entry(node, 'value').value)
        assert.are.equal(0, calls)
    end)

    it('captures large strings as data and explicit truncation', function()
        local trace = captureSubject(string.rep('a', 10000))
        local node = findLocal(trace, 'subject')
        assert.are.equal(512, #node.value)
        assert.are.equal(10000, node.originalBytes)
        assert.is_true(node.truncated)
        assert.are.equal('string_limit', node.reason)
        assert.are.equal('partial', trace.status)
    end)

    it('keeps UTF-8 truncation on character boundaries and encodes binary', function()
        local node = findLocal(captureSubject(string.rep('\226\130\172', 200)), 'subject')
        assert.are.equal(510, #node.value)
        assert.is_nil(node.encoding)
        local binary = findLocal(captureSubject('\0\255\128'), 'subject')
        assert.are.equal('hex', binary.encoding)
        assert.are.equal('00ff80', binary.value)
    end)

    it('represents non-finite numbers without invalid JSON numbers', function()
        local node = findLocal(captureSubject({ nan = 0/0, pos = math.huge, neg = -math.huge }), 'subject')
        assert.are.equal('nan', entry(node, 'nan').value)
        assert.are.equal('positive_infinity', entry(node, 'pos').value)
        assert.are.equal('negative_infinity', entry(node, 'neg').value)
    end)

    it('bounds table depth and traversal breadth', function()
        local wide = {}
        for i = 1, 1000 do wide[i] = i end
        local node = findLocal(captureSubject(wide), 'subject')
        assert.are.equal(20, #node.entries)
        assert.are.equal('entry_limit', node.reason)
        local deep = findLocal(captureSubject({ a = { b = { c = { d = 1 } } } }), 'subject')
        assert.are.equal('depth_limit', entry(entry(entry(deep, 'a'), 'b'), 'c').reason)
    end)

    it('captures throw-site locals before unwinding and names original handlers', function()
        local trace, onError
        onError = function(e)
            trace = Diagnostics.capture({ captureKind = 'exception', boundary = onError })
            return e
        end
        local function handler()
            local marker = 'throw-site'
            error(marker)
        end
        Diagnostics.registerFunction(handler, { functionName = 'OnPropertyChanged', role = 'driver' })
        xpcall(handler, onError)
        assert.are.equal('OnPropertyChanged', trace.frames[1].functionName)
        assert.are.equal('registered', trace.frames[1].nameOrigin)
        assert.are.equal('driver', trace.frames[1].role)
        assert.are.equal('throw-site', findLocal(trace, 'marker').value)
    end)

    it('keeps a registered SDK boundary while hiding reporting shims', function()
        local function shim()
            local trace = Diagnostics.capture()
            return trace
        end
        local function wrapper()
            local trace = shim()
            return trace
        end
        Diagnostics.registerFunction(shim, { skip = true })
        Diagnostics.registerFunction(wrapper, { functionName = 'Wrapper', role = 'sdk' })
        local trace = wrapper()
        assert.are.equal('Wrapper', trace.frames[1].functionName)
        assert.are.equal('sdk', trace.frames[1].role)
    end)

    it('fails explicitly when a requested boundary cannot be found', function()
        local trace = Diagnostics.capture({ boundary = function() end })
        assert.are.equal('failed', trace.status)
        assert.same({ 'capture_failed' }, trace.reasons)
        assert.is_nil(trace.frames)
    end)

    it('returns captured frames when inspection fails partway through', function()
        local trace = withDebugStubs({
            getlocal = function() error('inspection failed') end,
        }, function() return Diagnostics.capture() end)
        assert.are.equal('partial', trace.status)
        assert.is_table(trace.frames)
        assert.same({ 'capture_failed' }, trace.reasons)
    end)

    it('returns failure data if debug metadata is unavailable', function()
        local trace = withDebugStubs({
            getinfo = function() error('unavailable') end,
        }, function() return Diagnostics.capture() end)
        assert.are.equal('failed', trace.status)
    end)
end)
