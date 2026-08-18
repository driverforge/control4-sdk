local STP = require 'stacktrace'

describe('stacktrace', function()
    describe('stacktrace()', function()
        it('returns a Dumper with the current call stack', function()
            local function inner()
                return STP.stacktrace('boom', 1)
            end
            local dumper = inner()

            assert.is_table(dumper)
            assert.is_table(dumper.frames)
            assert.is_true(#dumper.frames > 0)
            assert.are.equal('boom', dumper.message)
        end)

        it('toJSON returns the frames array', function()
            local dumper = STP.stacktrace('msg', 1)
            local json = dumper:toJSON()

            assert.is_table(json)
            assert.are.equal(json, dumper.frames)
        end)

        it('removeFrames pops the top N frames', function()
            local dumper = STP.stacktrace('msg', 1)
            local original = #dumper.frames
            assert.is_true(original >= 1)

            dumper:removeFrames(1)
            assert.are.equal(original - 1, #dumper.frames)
        end)

        it('handles a missing message arg', function()
            assert.has_no.errors(function()
                STP.stacktrace(nil, 1)
            end)
        end)
    end)

    describe('string local capping', function()
        -- Find a named local in the captured frames.
        local function findLocal(dumper, wanted)
            for _, frame in ipairs(dumper.frames) do
                for _, l in ipairs(frame.locals or {}) do
                    if l.name == wanted then return l end
                end
            end
            return nil
        end

        it('caps a long string local at 512 chars and annotates the original length', function()
            local function withBigLocal()
                local hugePayload = string.rep('x', 10000)
                local dumper = STP.stacktrace('boom', 1)
                return dumper, hugePayload
            end
            local dumper = withBigLocal()

            local captured = findLocal(dumper, 'hugePayload')
            assert.is_table(captured)
            assert.are.equal('string', captured.type)
            -- 512 chars of payload + the marker, nothing more.
            assert.are.equal(string.rep('x', 512), captured.value:sub(1, 512))
            assert.are.equal(' ...(truncated, 10000 chars)', captured.value:sub(513))
        end)

        it('leaves a short string local untouched', function()
            local function withSmallLocal()
                local smallPayload = 'connection refused'
                local dumper = STP.stacktrace('boom', 1)
                return dumper, smallPayload
            end
            local dumper = withSmallLocal()

            local captured = findLocal(dumper, 'smallPayload')
            assert.is_table(captured)
            assert.are.equal('connection refused', captured.value)
        end)

        it('caps a huge string inside a table local', function()
            local function withBigTableLocal()
                local holder = { blob = string.rep('y', 10000) }
                local dumper = STP.stacktrace('boom', 1)
                return dumper, holder
            end
            local dumper = withBigTableLocal()

            local captured = findLocal(dumper, 'holder')
            assert.is_table(captured)
            assert.are.equal('table', captured.type)
            assert.is_truthy(captured.value:match('%(truncated, 10000 chars%)'))
            -- Bounded: one capped entry + markers, far below the raw 10000.
            assert.is_true(#captured.value < 700)
        end)
    end)

    describe('table local structured capping', function()
        local function findLocal(dumper, wanted)
            for _, frame in ipairs(dumper.frames) do
                for _, l in ipairs(frame.locals or {}) do
                    if l.name == wanted then return l end
                end
            end
            return nil
        end

        local function capture(wanted, value)
            local function withLocal()
                local subject = value
                local dumper = STP.stacktrace('boom', 1)
                return dumper, subject
            end
            return findLocal(withLocal(), 'subject')
        end

        it('renders a small table in full, richer than the old 70-char dump', function()
            local captured = capture('subject', {
                status = 'connected', retries = 3, secure = true,
                host = 'controller.local', port = 8883,
            })

            assert.are.equal('table', captured.type)
            assert.is_truthy(captured.value:match('status:connected'))
            assert.is_truthy(captured.value:match('retries:3'))
            assert.is_truthy(captured.value:match('secure:true'))
            assert.is_truthy(captured.value:match('host:controller%.local'))
            assert.is_truthy(captured.value:match('port:8883'))
            -- Nothing was cut.
            assert.is_falsy(captured.value:match('more entries'))
            assert.is_falsy(captured.value:match('depth%-capped'))
        end)

        it('descends nested tables and depth-caps at level 4', function()
            local captured = capture('subject', { b = { c = { d = { e = 1 } } } })

            assert.are.equal('{b:{c:{d:[table depth-capped]}}}', captured.value)
        end)

        it('caps a wide table at 20 entries and counts the remainder', function()
            local wide = {}
            for i = 1, 1000 do wide[i] = i end
            local captured = capture('subject', wide)

            assert.is_truthy(captured.value:match('%.%.%.%(%+980 more entries%)'))
            local entries = 0
            for _ in captured.value:gmatch('%d+:%d+') do entries = entries + 1 end
            assert.are.equal(20, entries)
        end)

        it('terminates on a cyclic table via the depth cap', function()
            local cyclic = {}
            cyclic.self = cyclic
            local captured = capture('subject', cyclic)

            assert.are.equal('{self:{self:{self:[table depth-capped]}}}', captured.value)
        end)

        it('renders a nested known table as its registered name, not its contents', function()
            local captured = capture('subject', { env = _G })

            assert.are.equal('{env:_G (global table)}', captured.value)
        end)

        it('renders non-scalar leaves as type placeholders, not addresses', function()
            local captured = capture('subject', { cb = function() end, co = coroutine.create(function() end) })

            assert.is_truthy(captured.value:match('cb:%[function%]'))
            assert.is_truthy(captured.value:match('co:%[thread%]'))
            assert.is_falsy(captured.value:match('0x'))
        end)

        it('bounds the total render with the per-local budget', function()
            -- 20 entries × ~600-char strings pass the breadth check but would
            -- render ~12KB; the budget must cut in first.
            local heavy = {}
            for i = 1, 20 do heavy[i] = string.rep('w', 600) end
            local captured = capture('subject', heavy)

            assert.is_true(#captured.value < 3300)
            assert.is_truthy(captured.value:match('more entries'))
        end)
    end)

    describe('unknown local value types', function()
        -- cdata exists only on LuaJIT (the controller runtime); gate so the
        -- suite still runs on plain Lua 5.1.
        local hasFFI, ffi = pcall(require, 'ffi')

        if hasFFI then
            it('captures cdata locals via the default branch and prints without throwing', function()
                local function withCdataLocal()
                    local box = ffi.new('int[1]', 42)
                    local dumper = STP.stacktrace('boom', 1)
                    return dumper, box
                end
                local dumper = withCdataLocal()

                local captured
                for _, frame in ipairs(dumper.frames) do
                    for _, l in ipairs(frame.locals or {}) do
                        if l.name == 'box' then captured = l end
                    end
                end

                -- Pre-fix this local was an EMPTY table, which made
                -- AppendLocals's format() throw inside the error handler.
                assert.is_table(captured)
                assert.are.equal('cdata', captured.type)
                assert.is_string(captured.value)
                assert.has_no.errors(function()
                    dumper:AppendLocals({}, { captured })
                end)
            end)
        end
    end)

    describe('add_known_table', function()
        it('rejects re-registering a built-in table', function()
            assert.has_error(function()
                STP.add_known_table(_G, 'override globals')
            end, 'Cannot override an already known table')
        end)

        it('accepts a fresh table', function()
            assert.has_no.errors(function()
                STP.add_known_table({}, 'spec scratch table')
            end)
        end)
    end)
end)
