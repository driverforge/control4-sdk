local LogArgs = require "log_args"

local function pack(...) return { n = select('#', ...), ... } end

describe('LogArgs.encode', function()
    it('keeps an all-string call as message only', function()
        local message, args, truncated = LogArgs.encode(pack('hello', 'world'))
        assert.are.equal('hello world', message)
        assert.is_nil(args)
        assert.is_false(truncated)
    end)

    it('sends a table argument as plain data, with a placeholder in the message', function()
        local response = { status = 200, body = 'OK' }
        local message, args = LogArgs.encode(pack('Response received:', response))

        assert.are.equal('Response received: [table]', message)
        assert.are.same({ 'Response received:', { status = 200, body = 'OK' } }, args)
        -- A fresh tree, never the driver's own table.
        assert.are_not.equal(response, args[2])
    end)

    it('keeps scalar types and argument positions, nil included', function()
        local message, args = LogArgs.encode(pack('count', 5, nil, true))
        assert.are.equal('count 5 nil true', message)
        assert.are.same({ 'count', 5, '[nil]', true }, args)
    end)

    it('encodes sequences as arrays and anything else as string-keyed objects', function()
        local backwards = {}
        backwards[3], backwards[2], backwards[1] = 'c', 'b', 'a'
        local _, args = LogArgs.encode(pack({ 10, 20 }, backwards, { [1] = 'a', [3] = 'c' }, { [true] = 1, [2.5] = 2 }))
        assert.are.same({ 10, 20 }, args[1])
        assert.are.same({ 'a', 'b', 'c' }, args[2])
        assert.are.same({ ['1'] = 'a', ['3'] = 'c' }, args[3])
        assert.are.same({ ['true'] = 1, ['2.5'] = 2 }, args[4])
    end)

    it('tags values JSON cannot hold', function()
        local message, args = LogArgs.encode(pack(print, coroutine.create(function() end), 0 / 0, math.huge, -math.huge))
        assert.are.equal('[function] [thread] nan inf -inf', message)
        assert.are.same({ '[function]', '[thread]', 'nan', 'inf', '-inf' }, args)
    end)

    it('marks a cycle instead of following it, but repeats a shared table', function()
        local node = { name = 'loop' }
        node.self = node
        local shared = { x = 1 }
        local _, args, truncated = LogArgs.encode(pack(node, { a = shared, b = shared }))
        assert.are.same({ name = 'loop', self = '[cycle]' }, args[1])
        assert.are.same({ a = { x = 1 }, b = { x = 1 } }, args[2])
        assert.is_false(truncated)
    end)

    it('never runs metamethods on driver values', function()
        local called = false
        local hostile = setmetatable({ field = 1 }, {
            __tostring = function() called = true; error('tostring ran') end,
            __index = function() called = true; error('index ran') end,
            __pairs = function() called = true; error('pairs ran') end,
        })
        local message, args
        assert.has_no.errors(function()
            message, args = LogArgs.encode(pack('obj', hostile))
        end)
        assert.is_false(called)
        assert.are.equal('obj [table]', message)
        assert.are.same({ 'obj', { field = 1 } }, args)
    end)

    describe('bounds', function()
        local saved
        before_each(function()
            saved = {}
            for k, v in pairs(LogArgs.limits) do saved[k] = v end
        end)
        after_each(function()
            for k, v in pairs(saved) do LogArgs.limits[k] = v end
        end)

        it('cuts nesting at the depth limit', function()
            LogArgs.limits.depth = 2
            local _, args, truncated = LogArgs.encode(pack({ a = { b = { c = 1 } } }))
            assert.are.same({ a = { b = '[truncated]' } }, args[1])
            assert.is_true(truncated)
        end)

        it('cuts wide arrays and objects at the entry limit', function()
            LogArgs.limits.entries = 3
            local _, args, truncated = LogArgs.encode(pack({ 1, 2, 3, 4, 5 }, { a = 1, b = 2, c = 3, d = 4 }))
            assert.are.same({ 1, 2, 3, '[truncated]' }, args[1])
            local kept = 0
            for k in pairs(args[2]) do if k ~= '[truncated]' then kept = kept + 1 end end
            assert.are.equal(3, kept)
            assert.is_true(args[2]['[truncated]'])
            assert.is_true(truncated)
        end)

        it('cuts long strings without splitting a UTF-8 character', function()
            LogArgs.limits.stringBytes = 4
            local _, args, truncated = LogArgs.encode(pack(1, 'abcdef', 'ab\226\130\172cd'))
            assert.are.equal('abcd…', args[2])
            -- The euro sign spans bytes 3-5; a 4-byte cut backs off before it.
            assert.are.equal('ab…', args[3])
            assert.is_true(truncated)
        end)

        it('stops at the size budget and says so', function()
            LogArgs.limits.bytes = 200
            local big = {}
            for i = 1, 50 do big[i] = 'value number ' .. i end
            local _, args, truncated = LogArgs.encode(pack(big, 'after'))
            assert.is_true(truncated)
            assert.are.equal('[truncated]', args[1][#args[1]])
            assert.is_true(#args[1] < 50)
            assert.are.equal('[truncated]', args[2])
        end)

        it('stops at the node limit', function()
            LogArgs.limits.nodes = 10
            local big = {}
            for i = 1, 50 do big[i] = i end
            local _, args, truncated = LogArgs.encode(pack(big))
            assert.is_true(truncated)
            assert.is_true(#args[1] <= 11)
            assert.are.equal('[truncated]', args[1][#args[1]])
        end)

        it('bounds a huge table with the default limits', function()
            local big = {}
            for i = 1, 100000 do big[i] = { id = i, name = string.rep('x', 100) } end
            local _, args, truncated = LogArgs.encode(pack(big))
            assert.is_true(truncated)
            assert.is_true(#args[1] <= LogArgs.limits.entries + 1)
        end)
    end)
end)
