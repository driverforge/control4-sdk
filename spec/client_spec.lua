local withDebugStubs = require 'spec.support.with_debug_stubs'
describe('anvil', function()
    -- C4 globals aren't loaded in the spec runner. Stub the calls anvil.lua
    -- actually makes during the codepaths under test (mostly GetUniqueMAC
    -- for the controller tag and GetTime for createdAt timestamps).
    local function stubC4(overrides)
        local c4 = {
            GetUniqueMAC = function() return 'AA:BB:CC' end,
            GetTime = function() return 1234567890 end,
            -- Realistic v4-shaped UUID so randomHex() yields proper-length
            -- 32-hex traceIds and 16-hex spanIds.
            UUID = function(_, _) return 'abcdabcd-1234-5678-9abc-def012345678' end,
        }
        for k, v in pairs(overrides or {}) do c4[k] = v end
        _G.C4 = c4
    end

    local function freshAnvil()
        package.loaded.client = nil
        local anvil = require 'client'
        anvil._token = 'drv_test'
        anvil._driverFileName = 'driver.c4z'
        anvil._driverVersion = '0.1.0'
        return anvil
    end

    it('loads', function()
        assert.has_no.errors(function() require 'client' end)
    end)

    describe('generatePayload', function()
        before_each(function() stubC4() end)

        it('includes sdkVersion on every envelope', function()
            local anvil = freshAnvil()
            anvil._sdkVersion = '1.2.3'
            local envelope = anvil:generatePayload('event', { id = 'e1' })

            assert.are.equal('1.2.3', envelope.sdkVersion)
            assert.are.equal('event', envelope.eventType)
            assert.are.equal('drv_test', envelope.apiKey)
        end)

        it("falls back to 'unknown' if version.lua wasn't loaded", function()
            local anvil = freshAnvil()
            local envelope = anvil:generatePayload('event', {})

            assert.are.equal('unknown', envelope.sdkVersion)
        end)

        it('decorates the inner data with controller and driver tags', function()
            local anvil = freshAnvil()
            local envelope = anvil:generatePayload('event', { id = 'e1' })

            assert.are.equal('AA:BB:CC', envelope.payload.controller)
            assert.are.equal('driver.c4z', envelope.payload.driver)
            assert.are.equal('AA:BB:CC', envelope.payload.tags.controller)
            assert.are.equal('driver.c4z', envelope.payload.tags.driver)
        end)
    end)

    describe('generateLogMessagePayload', function()
        before_each(function() stubC4() end)

        it('builds a log envelope with level, message, and createdAt', function()
            local anvil = freshAnvil()
            local envelope = anvil:generateLogMessagePayload('INFO', 'hello')

            assert.are.equal('log', envelope.eventType)
            assert.are.equal('INFO', envelope.payload.level)
            assert.are.equal('hello', envelope.payload.message)
            assert.are.equal(1234567890, envelope.payload.createdAt)
        end)

        it('attaches the active traceId and spanId when an event is in flight', function()
            local anvil = freshAnvil()
            anvil._currentTraceId = 'trace-1'
            anvil._currentSpanId = 'span-1'
            local envelope = anvil:generateLogMessagePayload('INFO', 'hello')

            assert.are.equal('trace-1', envelope.payload.traceId)
            assert.are.equal('span-1', envelope.payload.spanId)
            -- And the message is captured as the lastLog for that trace so a
            -- subsequent error payload can reference it.
            assert.are.equal('hello', anvil._eventLastLogs['trace-1'])
        end)

        it('mints a fresh root traceId with null spanId when no event is in flight', function()
            local anvil = freshAnvil()
            local envelope = anvil:generateLogMessagePayload('INFO', 'hello')

            -- A log outside an event is its own root trace.
            assert.is_truthy(envelope.payload.traceId:match('^%x+$'))
            assert.are.equal(32, #envelope.payload.traceId)
            assert.is_nil(envelope.payload.spanId)
        end)

        it('attaches the active eventName when emitted inside an event', function()
            local anvil = freshAnvil()
            anvil._currentTraceId = 'trace-1'
            anvil._currentSpanId = 'span-1'
            anvil._currentEventName = 'OnPropertyChanged'
            local envelope = anvil:generateLogMessagePayload('INFO', 'hello')

            assert.are.equal('OnPropertyChanged', envelope.payload.eventName)
        end)

        it('omits eventName for an orphan log, mirroring spanId', function()
            local anvil = freshAnvil()
            -- Gated on spanId, not merely on a name being set: even if a
            -- stale name lingered, an orphan log carries neither field.
            anvil._currentEventName = 'OnPropertyChanged'
            local envelope = anvil:generateLogMessagePayload('INFO', 'hello')

            assert.is_nil(envelope.payload.spanId)
            assert.is_nil(envelope.payload.eventName)
        end)
    end)

    describe('generateEventPayload', function()
        before_each(function() stubC4() end)

        it('marks status ok, carries traceId/spanId/source, omits error fields on success', function()
            local anvil = freshAnvil()
            local envelope = anvil:generateEventPayload(
                'trace-1', 'span-1', 'OnDriverInit', { 'arg1' },
                100, 105, 5,
                true, 'result', { { value = 'result' } },
                nil, nil, true
            )

            assert.are.equal('event', envelope.eventType)
            assert.are.equal('trace-1', envelope.payload.traceId)
            assert.are.equal('span-1', envelope.payload.spanId)
            assert.are.equal('control4', envelope.payload.source)
            -- Events are identified by (traceId, spanId); the
            -- old UUID `id` field is gone.
            assert.is_nil(envelope.payload.id)
            assert.are.equal('OnDriverInit', envelope.payload.name)
            assert.are.equal('ok', envelope.payload.status)
            assert.are.equal(true, envelope.payload.implemented)
            assert.are.equal(5, envelope.payload.duration)
            assert.are.equal('result', envelope.payload.result)
            assert.are.same({ { value = 'result' } }, envelope.payload.results)
            assert.is_nil(envelope.payload.errorId)
            assert.is_nil(envelope.payload.errorMessage)
        end)

        it('marks status error and threads errorId through', function()
            local anvil = freshAnvil()
            anvil._errorMessages['trace-1'] = 'boom'
            anvil._eventStacktraces['trace-1'] = { frames = {} }

            local envelope = anvil:generateEventPayload(
                'trace-1', 'span-1', 'OnDriverInit', {},
                100, 105, 5,
                false, nil, nil,
                nil, 'err-1', true
            )

            assert.are.equal('error', envelope.payload.status)
            assert.are.equal('err-1', envelope.payload.errorId)
            assert.are.equal('boom', envelope.payload.errorMessage)
            assert.is_table(envelope.payload.stacktrace)
        end)

        it('attaches lastLog when one was captured during the event', function()
            local anvil = freshAnvil()
            anvil._eventLastLogs['trace-1'] = 'last log line'

            local envelope = anvil:generateEventPayload(
                'trace-1', 'span-1', 'OnDriverInit', {},
                100, 105, 5,
                true, nil, nil, nil, nil, true
            )

            assert.are.equal('last log line', envelope.payload.lastLog)
        end)
    end)

    describe('generateErrorPayload', function()
        before_each(function() stubC4() end)

        it('builds an error envelope with own id, traceId/spanId, value, and structured trace', function()
            local anvil = freshAnvil()
            local envelope = anvil:generateErrorPayload(
                'err-1', 'trace-1', 'span-1', 'OnDriverInit', {},
                'something failed',
                { schemaVersion = 1, captureKind = 'exception', status = 'complete' }
            )

            assert.are.equal('error', envelope.eventType)
            -- The error keeps its own entity id (referenced by events.errorId).
            assert.are.equal('err-1', envelope.payload.id)
            -- Attributes to the event span via (traceId, spanId);
            -- the old eventId FK is gone.
            assert.are.equal('trace-1', envelope.payload.traceId)
            assert.are.equal('span-1', envelope.payload.spanId)
            assert.is_nil(envelope.payload.eventId)
            assert.are.equal('OnDriverInit', envelope.payload.eventName)
            assert.are.equal('lua:runtime_error', envelope.payload.type)
            assert.are.equal('something failed', envelope.payload.value)
            assert.are.equal('0.1.0', envelope.payload.driverVersion)
            assert.is_nil(envelope.payload.fingerprint)
        end)

        it('normalizes primitive and opaque errors without calling metamethods', function()
            local anvil = freshAnvil()
            local opaque = setmetatable({}, { __tostring = function() error('must not run') end })
            for _, example in ipairs({ { value = nil, expected = 'nil' }, { value = false, expected = 'false' },
                { value = 42, expected = '42' }, { value = opaque, expected = 'table' },
                { value = function() end, expected = 'function' } }) do
                local envelope = anvil:generateErrorPayload(nil, nil, nil, 'Manual', {}, example.value, nil)
                assert.are.equal(example.expected, envelope.payload.value)
                assert.are.equal(1, envelope.payload.stacktrace.schemaVersion)
                assert.are.equal('failed', envelope.payload.stacktrace.status)
            end
        end)

        it('auto-generates an errorId when not supplied', function()
            local anvil = freshAnvil()
            _G.C4.UUID = function() return 'auto-uuid' end

            local envelope = anvil:generateErrorPayload(nil, 'trace-1', 'span-1', 'X', {}, 'msg', nil)

            assert.are.equal('auto-uuid', envelope.payload.id)
        end)

        it('mints a fresh root traceId with null spanId for a standalone error', function()
            local anvil = freshAnvil()
            -- No trace/span supplied (timer / manual capture): the error
            -- becomes its own root trace with no enclosing span.
            local envelope = anvil:generateErrorPayload('err-1', nil, nil, 'Timer', {}, 'msg', nil)

            assert.is_truthy(envelope.payload.traceId:match('^%x+$'))
            assert.are.equal(32, #envelope.payload.traceId)
            assert.is_nil(envelope.payload.spanId)
        end)

        it('attaches lastLog from the originating event', function()
            local anvil = freshAnvil()
            anvil._eventLastLogs['trace-1'] = 'last log'

            local envelope = anvil:generateErrorPayload('err-1', 'trace-1', 'span-1', 'X', {}, 'msg', nil)

            assert.are.equal('last log', envelope.payload.lastLog)
        end)
    end)

    describe('instrument (implemented handler)', function()
        -- Two controller capabilities that vanilla 5.1 (a common spec runner)
        -- lacks; specs depending on them are gated so the suite is meaningful
        -- everywhere and complete on LuaJIT-like runtimes.

        -- debug.getlocal on a FUNCTION value (parameter-name extraction).
        local supportsNamedArgs = (function()
            local ok, name = pcall(debug.getlocal, function(first) end, 1)
            return ok and name == 'first'
        end)()

        -- xpcall forwarding extra args to the called function.
        local supportsXpcallArgs = (function()
            local ok, passed = xpcall(function(v) return v == 42 end, function() end, 42)
            return ok and passed == true
        end)()

        local function instrumentedAnvil()
            local anvil = freshAnvil()
            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end
            return anvil, sent
        end

        before_each(function()
            -- Deterministic clock (start=100, end=107 -> duration 7) and
            -- counting UUIDs so trace/span/error ids are distinct — id
            -- LINKAGE assertions would pass vacuously with a constant stub.
            local clock = { 100, 107 }
            local uuidCount = 0
            stubC4({
                GetTime = function() return table.remove(clock, 1) or 107 end,
                UUID = function()
                    uuidCount = uuidCount + 1
                    return string.format('%08d-abcd-4ef0-9abc-def012345678', uuidCount)
                end,
            })
        end)

        it('calls the handler, preserves its return value, and sends an ok event', function()
            local anvil, sent = instrumentedAnvil()

            local result = anvil:instrument('OnPropertyChanged', function()
                return 'handled'
            end)

            assert.are.equal('handled', result)
            assert.are.equal(1, #sent)
            local event = sent[1]
            assert.are.equal('event', event.eventType)
            assert.are.equal('OnPropertyChanged', event.payload.name)
            assert.are.equal('ok', event.payload.status)
            assert.are.equal(true, event.payload.implemented)
            assert.are.equal(7, event.payload.duration)
            assert.are.equal('handled', event.payload.result)
            assert.are.equal(32, #event.payload.traceId)
            assert.are.equal(16, #event.payload.spanId)
            assert.is_nil(event.payload.errorId)
        end)

        -- Handler args must reach the handler even on a runtime whose xpcall
        -- does NOT forward trailing args to the called function (Lua 5.1 /
        -- LuaJIT without 5.2 compat — the C4 controller). This shims the
        -- global xpcall to that behaviour so the test catches the arg-drop
        -- regardless of whether the host interpreter happens to have 5.2
        -- compat (which silently forwards and would mask the regression).
        it('forwards handler arguments under a non-forwarding (5.1) xpcall', function()
            local anvil, sent = instrumentedAnvil()

            local realxpcall = xpcall
            _G.xpcall = function(f, h) return realxpcall(f, h) end  -- drop trailing args

            local received = 'UNSET'
            local ok, err = pcall(function()
                anvil:instrument('OnPropertyChanged', function(sProperty)
                    received = sProperty
                    return 'handled:' .. sProperty  -- nil-concat crash if arg dropped
                end, 'Log Mode')
            end)

            _G.xpcall = realxpcall  -- restore before asserting

            assert.is_true(ok, tostring(err))
            assert.are.equal('Log Mode', received)
            assert.are.equal('ok', sent[1].payload.status)
            assert.are.equal('handled:Log Mode', sent[1].payload.result)
        end)

        it('forwards multiple args with an embedded nil, arity intact', function()
            local anvil = instrumentedAnvil()

            local realxpcall = xpcall
            _G.xpcall = function(f, h) return realxpcall(f, h) end

            local seen
            pcall(function()
                anvil:instrument('OnBindingChanged', function(a, b, c)
                    seen = { n = select('#', a, b, c), a, b, c }
                end, 10, nil, 'z')
            end)

            _G.xpcall = realxpcall

            assert.are.equal(3, seen.n)
            assert.are.equal(10, seen[1])
            assert.is_nil(seen[2])
            assert.are.equal('z', seen[3])
        end)

        -- select('#', ...)-based counting so an embedded nil is observed
        -- rather than truncating the list at the first nil.
        local function packReturns(...)
            return select('#', ...), { ... }
        end

        it('preserves all return values, embedded nils included', function()
            local anvil, sent = instrumentedAnvil()

            local n, vals = packReturns(anvil:instrument('ExecuteCommand', function()
                return 'first', nil, 3
            end))

            assert.are.equal(3, n)
            assert.are.equal('first', vals[1])
            assert.is_nil(vals[2])
            assert.are.equal(3, vals[3])
            -- The wire carries the complete return list as boxed values
            -- (an empty box marks an embedded nil), plus the first value
            -- in `result` for ingest back-compat.
            assert.are.equal('first', sent[1].payload.result)
            assert.are.same(
                { { value = 'first' }, {}, { value = 3 } },
                sent[1].payload.results)
        end)

        it('returns the same values when the agent is not installed', function()
            -- Late-inited with no agent discovered takes the uninstrumented
            -- short-circuit; a multi-return handler must behave identically
            -- on both paths.
            local anvil = freshAnvil()
            anvil._hasLateInited = true
            assert.is_false(anvil:isAgentInstalled())

            local n, vals = packReturns(anvil:instrument('ExecuteCommand', function()
                return 'first', nil, 3
            end))

            assert.are.equal(3, n)
            assert.are.equal('first', vals[1])
            assert.is_nil(vals[2])
            assert.are.equal(3, vals[3])
        end)

        if supportsXpcallArgs then
            it('passes the C4 arguments through to the handler', function()
                local anvil = instrumentedAnvil()
                local received

                anvil:instrument('OnPropertyChanged', function(a, b)
                    received = { a = a, b = b }
                end, 'Power', 'On')

                assert.are.equal('Power', received.a)
                assert.are.equal('On', received.b)
            end)
        end

        if supportsNamedArgs then
            it('maps positional args to the handler parameter names in the payload', function()
                local anvil, sent = instrumentedAnvil()

                anvil:instrument('OnPropertyChanged', function(strProperty, strValue) end,
                    'Power', 'On')

                assert.are.equal('Power', sent[1].payload.args.strProperty)
                assert.are.equal('On', sent[1].payload.args.strValue)
            end)
        end

        it('falls back to positional args in the payload when parameter names are unavailable', function()
            local anvil, sent = instrumentedAnvil()

            -- A varargs-only handler has no named parameters on any runtime.
            anvil:instrument('ExecuteCommand', function(...) end, 'SHOUT')

            assert.are.equal('SHOUT', sent[1].payload.args[1])
        end)

        it('sends a linked event + error pair when the handler raises, then re-raises', function()
            local anvil, sent = instrumentedAnvil()

            local ok, err = pcall(function()
                anvil:instrument('OnBindingChanged', function()
                    error('binding fell over')
                end)
            end)

            -- Report, don't handle: telemetry goes out and the original
            -- error then propagates to the Director exactly as it would
            -- have without the SDK.
            assert.is_false(ok)
            assert.is_truthy(tostring(err):match('binding fell over'))
            assert.are.equal(2, #sent)

            local event, errorEnvelope = sent[1], sent[2]
            assert.are.equal('event', event.eventType)
            assert.are.equal('error', errorEnvelope.eventType)
            assert.are.equal('error', event.payload.status)
            assert.is_truthy(event.payload.errorMessage:match('binding fell over'))

            -- Bidirectional linkage: the event points at the error's own id,
            -- and both attribute to the same (traceId, spanId).
            assert.is_string(event.payload.errorId)
            assert.are.equal(event.payload.errorId, errorEnvelope.payload.id)
            assert.are.equal(event.payload.traceId, errorEnvelope.payload.traceId)
            assert.are.equal(event.payload.spanId, errorEnvelope.payload.spanId)
            assert.are.equal('OnBindingChanged', errorEnvelope.payload.eventName)
            assert.is_nil(errorEnvelope.payload.fingerprint)

            -- Diagnostic frames carry source fields, without presentation text.
            assert.is_table(errorEnvelope.payload.stacktrace)
            assert.are.equal(1, errorEnvelope.payload.stacktrace.schemaVersion)
            assert.is_string(errorEnvelope.payload.stacktrace.frames[1].source.name)
            assert.is_nil(errorEnvelope.payload.stacktrace.frames[1].text)
        end)

        -- The captured stacktrace must start at the driver's own handler, not
        -- at the SDK's instrument()/xpcall machinery. A runtime error (nil
        -- index) carries no error() C frame, so a mis-calibrated capture level
        -- buries the handler under the SDK — the exact symptom that surfaced
        -- as an instrument() top frame in the field. error()/assert() raises
        -- push a C boundary frame that must be stripped. Assert the top frame
        -- points at this spec file (where each handler is defined), never at
        -- src/anvil.lua or a C boundary.
        local function topFrameFor(raise)
            local anvil, sent = instrumentedAnvil()
            pcall(function()
                anvil:instrument('OnBindingChanged', raise)
            end)
            local errorEnvelope = sent[2]
            return errorEnvelope.payload.stacktrace.frames[1]
        end

        it('starts the stacktrace at the driver handler for a runtime error', function()
            local top = topFrameFor(function()
                local x = nil
                return x.field  -- nil index: no error() C frame
            end)
            assert.is_truthy(top.source.name:find('client_spec.lua', 1, true))
            assert.are.equal('lua', top.kind)
        end)

        it('starts the stacktrace at the driver handler for an error() raise', function()
            local top = topFrameFor(function() error('boom') end)
            assert.is_truthy(top.source.name:find('client_spec.lua', 1, true))
            assert.are.equal('lua', top.kind)
        end)

        it('names the displaced driver handler frame, not the wrapper', function()
            local anvil, sent = instrumentedAnvil()
            local function driverHandler() local x = nil; return x.field end
            anvil.EventHandlers = { OnPropertyChanged = driverHandler }
            anvil:nameHandlerFrames({ OnPropertyChanged = function() end })
            pcall(function() anvil:instrument('OnPropertyChanged', driverHandler) end)
            local top = sent[2].payload.stacktrace.frames[1]
            assert.are.equal('OnPropertyChanged', top.functionName)
            assert.are.equal('registered', top.nameOrigin)
            assert.are.equal('driver', top.role)
        end)

        it('labels the SDK wrapper frame as a boundary', function()
            local anvil = instrumentedAnvil()
            local Diagnostics = require 'diagnostics'
            local wrapper = function() local x = nil; return x.field end
            anvil.EventHandlers = { OnPropertyChanged = function() end }
            anvil:nameHandlerFrames({ OnPropertyChanged = wrapper })
            local top
            local function onError()
                top = Diagnostics.capture({ captureKind = 'exception', boundary = onError }).frames[1]
            end
            xpcall(wrapper, onError)
            assert.are.equal('OnPropertyChanged', top.functionName)
            assert.are.equal('sdk', top.role)
        end)

        it('marks the instrument boundary as SDK-owned using function identity', function()
            local anvil, sent = instrumentedAnvil()
            pcall(function() anvil:instrument('OnPropertyChanged', function() error('driver error') end) end)
            local found = false
            for _, frame in ipairs(sent[2].payload.stacktrace.frames) do
                if frame.functionName == 'instrument' then
                    found = true
                    assert.are.equal('sdk', frame.role)
                    assert.are.equal('registered', frame.nameOrigin)
                end
            end
            assert.is_true(found)
        end)

        it('preserves hostile table errors without invoking their metamethods', function()
            local anvil, sent = instrumentedAnvil()
            local thrown = setmetatable({ __dfReported = true }, {
                __index = function() error('must not index') end,
                __tostring = function() error('must not stringify') end,
            })
            local ok, err = pcall(function()
                anvil:instrument('OnDriverInit', function()
                    anvil:instrument('OnPropertyChanged', function() error(thrown, 0) end)
                end)
            end)
            assert.is_false(ok)
            assert.are.equal(thrown, err)
            local reports = 0
            for _, envelope in ipairs(sent) do
                if envelope.eventType == 'error' then
                    reports = reports + 1
                    assert.are.equal('table', envelope.payload.value)
                end
            end
            assert.are.equal(1, reports)
        end)

        it('retains original nil, false and table errors when diagnostic capture throws', function()
            local Diagnostics = require 'diagnostics'
            local originalCapture = Diagnostics.capture
            for _, box in ipairs({ { value = nil }, { value = false }, { value = {} } }) do
                local anvil, sent = instrumentedAnvil()
                Diagnostics.capture = function() error('diagnostics failed', 0) end
                local ok, err = pcall(function()
                    anvil:instrument('OnPropertyChanged', function() error(box.value, 0) end)
                end)
                Diagnostics.capture = originalCapture
                assert.is_false(ok)
                assert.are.equal(box.value, err)
                assert.are.equal('error', sent[2].eventType)
                assert.are.equal(type(box.value) == 'table' and 'table' or tostring(box.value), sent[2].payload.value)
                assert.are.equal('failed', sent[2].payload.stacktrace.status)
                assert.are.same({ 'capture_failed' }, sent[2].payload.stacktrace.reasons)
            end
        end)

        -- Containment: SDK-internal telemetry work is isolated, so a failure
        -- in it can never change what the driver returns or raises. It is
        -- swallowed and routed to the SDK fault sink (reportSdkFault) instead.
        it('a telemetry failure never changes the driver return value', function()
            local anvil = instrumentedAnvil()
            anvil.sendData = function() error('telemetry exploded') end
            local faults = {}
            anvil.reportSdkFault = function(_, label, err)
                faults[#faults + 1] = { label = label, err = err }
            end

            local result = anvil:instrument('OnPropertyChanged', function()
                return 'driver-ok'
            end, 'X')

            assert.are.equal('driver-ok', result)         -- driver outcome intact
            assert.are.equal(1, #faults)                   -- fault contained, not raised
            assert.is_truthy(tostring(faults[1].err):find('telemetry exploded', 1, true))
        end)

        it('a telemetry failure never suppresses the driver error re-raise', function()
            local anvil = instrumentedAnvil()
            anvil.sendData = function() error('telemetry exploded') end
            anvil.reportSdkFault = function() end

            local ok, err = pcall(function()
                anvil:instrument('OnPropertyChanged', function()
                    error('driver boom')
                end)
            end)

            assert.is_false(ok)                            -- original error still propagates
            assert.is_truthy(tostring(err):find('driver boom', 1, true))
        end)

        it('reportSdkFault refuses to re-enter (no reporting recursion)', function()
            local anvil = freshAnvil()
            local calls = 0
            -- A sink whose own logging re-enters the reporter must not loop.
            local realLog = C4.ErrorLog
            C4.ErrorLog = function(_, _)
                calls = calls + 1
                anvil:reportSdkFault('reentrant', 'boom')  -- would loop without the guard
            end
            anvil:reportSdkFault('outer', 'boom')
            C4.ErrorLog = realLog
            assert.are.equal(1, calls)
        end)

        it('forwards an SDK fault to the agent tagged origin=sdk when ready', function()
            local captured
            stubC4({
                ErrorLog = function() end,                  -- silence the breadcrumb
                JsonEncode = function(_, t) return t end,   -- pass-through to inspect
                SendToDevice = function(_, deviceId, cmd, params)
                    captured = { deviceId = deviceId, cmd = cmd, params = params }
                end,
            })
            local anvil = freshAnvil()
            anvil.isAgentReady = function() return true end
            anvil.AGENT_DEVICE_ID = 7
            anvil._token = 'drv_customer'
            anvil._sdkVersion = '9.9.9'

            anvil:reportSdkFault('instrument:Foo', 'kaboom')

            assert.is_table(captured)
            assert.are.equal(7, captured.deviceId)
            assert.are.equal('DRIVER_DATA', captured.cmd)
            local envelope = captured.params.payload
            assert.are.equal('sdk', envelope.origin)         -- top-level marker for the agent
            assert.are.equal('error', envelope.eventType)
            assert.are.equal('instrument:Foo', envelope.payload.eventName)
            assert.is_truthy(tostring(envelope.payload.errorMessage):find('kaboom', 1, true))
        end)

        it('does not forward an SDK fault when the agent is not ready', function()
            local sends = 0
            stubC4({ ErrorLog = function() end, SendToDevice = function() sends = sends + 1 end })
            local anvil = freshAnvil()
            anvil.isAgentReady = function() return false end

            anvil:reportSdkFault('x', 'y')  -- local breadcrumb only

            assert.are.equal(0, sends)
        end)

        -- Dedup: a single throw that unwinds through nested instrumented
        -- handlers is reported ONCE, at the inner frame that caught it, and the
        -- Director still receives the driver's original error (not a wrapper).
        it('reports a nested throw once and re-raises the original', function()
            local anvil, sent = instrumentedAnvil()

            local ok, err = pcall(function()
                anvil:instrument('OnDriverInit', function()
                    anvil:instrument('OnPropertyChanged', function()
                        error('boom at leaf')
                    end, 'Log Mode')
                end)
            end)

            -- Director sees the ORIGINAL error, unwrapped — never our tag table.
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_truthy(err:find('boom at leaf', 1, true))

            local errors, events = {}, {}
            for _, p in ipairs(sent) do
                if p.eventType == 'error' then errors[#errors + 1] = p end
                if p.eventType == 'event' then events[#events + 1] = p end
            end

            -- Exactly one error report, from the innermost handler...
            assert.are.equal(1, #errors)
            assert.are.equal('OnPropertyChanged', errors[1].payload.eventName)
            -- ...and both events recorded, both marked errored.
            assert.are.equal(2, #events)
            for _, e in ipairs(events) do
                assert.are.equal('error', e.payload.status)
            end
        end)

        it('leaves instrument depth balanced after a nested throw', function()
            local anvil = instrumentedAnvil()
            pcall(function()
                anvil:instrument('OnDriverInit', function()
                    anvil:instrument('OnPropertyChanged', function()
                        error('boom')
                    end)
                end)
            end)
            assert.are.equal(0, anvil._instrumentDepth)
        end)

        -- Init-time boundary self-test + fail-open.
        it('passes the boundary self-test on this runtime and keeps instrumentation on', function()
            local anvil = instrumentedAnvil()
            assert.is_true(anvil:runBoundarySelfTest())
            assert.is_falsy(anvil._instrumentationDisabled)
        end)

        it('disables instrumentation and reports when the boundary self-test fails', function()
            local anvil = instrumentedAnvil()
            local faults = {}
            anvil.reportSdkFault = function(_, label) faults[#faults + 1] = label end
            -- Simulate a broken boundary: the forward drops the handler's args.
            anvil.instrument = function(_, name, fn) return fn() end

            assert.is_false(anvil:runBoundarySelfTest())
            assert.is_true(anvil._instrumentationDisabled)
            assert.are.equal('boundary-self-test', faults[1])
        end)

        it('runs raw and preserves args/returns/errors when instrumentation is disabled', function()
            local anvil, sent = instrumentedAnvil()
            anvil._instrumentationDisabled = true

            local got
            local r = anvil:instrument('OnPropertyChanged', function(p)
                got = p; return 'ok:' .. p
            end, 'X')

            assert.are.equal('X', got)                 -- arg preserved
            assert.are.equal('ok:X', r)                -- return preserved
            assert.are.equal(0, #sent)                 -- no telemetry emitted

            local threw, e = pcall(function()
                anvil:instrument('OnPropertyChanged', function() error('boom') end)
            end)
            assert.is_false(threw)                     -- error still propagates
            assert.is_truthy(tostring(e):find('boom', 1, true))
        end)

        it('clears the event context and per-trace state after the call', function()
            local anvil, sent = instrumentedAnvil()

            -- Cleanup must happen before the error path re-raises.
            pcall(function()
                anvil:instrument('OnBindingChanged', function()
                    error('boom')
                end)
            end)

            local traceId = sent[1].payload.traceId
            assert.is_nil(anvil._currentTraceId)
            assert.is_nil(anvil._currentSpanId)
            assert.is_nil(anvil._currentEventName)
            assert.is_nil(anvil._eventLastLogs[traceId])
            assert.is_nil(anvil._eventStacktraces[traceId])
            assert.is_nil(anvil._errorMessages[traceId])
        end)

        it('redacts a sensitive handler on the wire while preserving its return value', function()
            local anvil, sent = instrumentedAnvil()

            local secret = anvil:instrument('GetPrivateKeyPassword', function(bindingId)
                return 'hunter2-super-secret'
            end, 42)

            -- The Director must still receive the real password...
            assert.are.equal('hunter2-super-secret', secret)
            -- ...but telemetry must carry neither args nor results.
            assert.are.equal(1, #sent)
            assert.are.equal('[REDACTED]', sent[1].payload.args)
            assert.is_nil(sent[1].payload.result)
            assert.is_nil(sent[1].payload.results)
        end)
    end)

    describe('installLoggerProxy', function()
        before_each(function() stubC4() end)

        it('forwards the full message on dot-style calls (Log.Info) too', function()
            -- A dot-style call site puts the first message argument where a
            -- colon call puts the logger; the proxy must not eat it as
            -- `self`. The delegation to the original stays verbatim either
            -- way — call-style quirks are the driver's own business.
            local anvil = freshAnvil()
            local forwarded = {}
            anvil.forwardLog = function(_, level, message)
                table.insert(forwarded, { level = level, message = message })
            end

            local received
            local logger = {
                info = function(...) received = { n = select('#', ...), ... } end,
            }
            anvil:installLoggerProxy(logger)

            logger.info('dotted', 'call')

            assert.are.equal(1, #forwarded)
            assert.are.equal('dotted call', forwarded[1].message)
            -- Verbatim passthrough: the original sees exactly the
            -- arguments the call site supplied.
            assert.are.equal(2, received.n)
            assert.are.equal('dotted', received[1])
            assert.are.equal('call', received[2])
        end)

        it('forwards via the caller-supplied logger reference (no proxy table)', function()
            -- Regression guard: the SDK must mutate the
            -- caller's logger in place so existing `Log:Info` call
            -- sites auto-forward to Anvil. Pre-fix the SDK created a
            -- new proxy table and assigned it to a dead `Anvil.logger`
            -- field; nothing read it, so callers had to manually call
            -- Anvil:ForwardLog from inside their own log methods to
            -- get anything to Anvil.
            local anvil = freshAnvil()
            local forwarded = {}
            anvil.forwardLog = function(_, level, message)
                table.insert(forwarded, { level = level, message = message })
            end

            local underlyingCalls = {}
            local logger = {
                info = function(self, ...)
                    table.insert(underlyingCalls, { method = 'info', args = { ... } })
                end,
                error = function(self, ...)
                    table.insert(underlyingCalls, { method = 'error', args = { ... } })
                end,
            }

            anvil:installLoggerProxy(logger)

            -- Crucially: call the methods on the SAME `logger` reference
            -- the test passed in. No reassignment, no return value used.
            logger:info('hello', 'world')
            logger:error('bang')

            -- Forwarded to Anvil
            assert.are.equal(2, #forwarded)
            assert.are.equal('INFO', forwarded[1].level)
            assert.are.equal('hello world', forwarded[1].message)
            assert.are.equal('ERROR', forwarded[2].level)
            assert.are.equal('bang', forwarded[2].message)

            -- And the original log behaviour still ran (proxy, not replace)
            assert.are.equal(2, #underlyingCalls)
            assert.are.equal('info', underlyingCalls[1].method)
            assert.are.equal('hello', underlyingCalls[1].args[1])
        end)

        it('respects a custom logMap', function()
            local anvil = freshAnvil()
            local forwarded = {}
            anvil.forwardLog = function(_, level, message)
                table.insert(forwarded, { level = level, message = message })
            end

            local logger = { logInfo = function() end }
            anvil:installLoggerProxy(logger, { info = 'logInfo' })
            logger:logInfo('mapped')

            assert.are.equal(1, #forwarded)
            assert.are.equal('INFO', forwarded[1].level)
        end)

        it('leaves non-log methods on the logger untouched', function()
            local anvil = freshAnvil()
            anvil.forwardLog = function() end

            local logger = {
                info = function() end,
                Setup = function(self, value) self._setup = value end,
            }
            local originalSetup = logger.Setup

            anvil:installLoggerProxy(logger)

            -- Methods not in the logMap should not be replaced.
            assert.are.equal(originalSetup, logger.Setup)
        end)

        it('is idempotent — a re-install does not stack the wrap', function()
            -- If Driverforge:Init runs twice (driver reload, etc.), the
            -- wrap must not double-fire. The earlier behaviour was
            -- "create a new proxy each time" — equivalent to no
            -- wrapping at all on the input logger, but now we mutate
            -- in place so this matters.
            local anvil = freshAnvil()
            local forwardCallCount = 0
            anvil.forwardLog = function() forwardCallCount = forwardCallCount + 1 end

            local logger = { info = function() end }

            anvil:installLoggerProxy(logger)
            anvil:installLoggerProxy(logger)

            logger:info('x')

            assert.are.equal(1, forwardCallCount)
        end)

        it('does not forward when the message is empty (avoids zero-length spam)', function()
            local anvil = freshAnvil()
            local forwarded = {}
            anvil.forwardLog = function(_, level, message)
                table.insert(forwarded, { level = level, message = message })
            end

            local logger = { info = function() end }
            anvil:installLoggerProxy(logger)
            logger:info()  -- no args at all

            assert.are.equal(0, #forwarded)
        end)

        describe('variant fallback', function()
            -- Drivers using PascalCase loggers (Snap One's c4_log,
            -- our unified lib/logger.lua, most C4 drivers in the wild)
            -- shouldn't need a 6-row logMap to spell out the case
            -- difference. installLoggerProxy probes lowercase ->
            -- PascalCase -> UPPERCASE on each canonical level and
            -- wraps whichever exists.

            it('resolves PascalCase methods (c4_log shape) without a logMap', function()
                local anvil = freshAnvil()
                local forwarded = {}
                anvil.forwardLog = function(_, level, message)
                    table.insert(forwarded, { level = level, message = message })
                end

                local logger = {
                    Fatal = function() end,
                    Error = function() end,
                    Warn  = function() end,
                    Info  = function() end,
                    Debug = function() end,
                    Trace = function() end,
                }

                anvil:installLoggerProxy(logger)

                logger:Fatal('boom')
                logger:Error('err')
                logger:Warn('warn')
                logger:Info('info')
                logger:Debug('dbg')
                logger:Trace('trc')

                assert.are.equal(6, #forwarded)
                assert.are.equal('FATAL', forwarded[1].level)
                assert.are.equal('ERROR', forwarded[2].level)
                assert.are.equal('WARN',  forwarded[3].level)
                assert.are.equal('INFO',  forwarded[4].level)
                assert.are.equal('DEBUG', forwarded[5].level)
                assert.are.equal('TRACE', forwarded[6].level)
            end)

            it('resolves UPPERCASE methods without a logMap', function()
                local anvil = freshAnvil()
                local forwarded = {}
                anvil.forwardLog = function(_, level, message)
                    table.insert(forwarded, { level = level, message = message })
                end

                local logger = { INFO = function() end }
                anvil:installLoggerProxy(logger)
                logger:INFO('shouty')

                assert.are.equal(1, #forwarded)
                assert.are.equal('INFO', forwarded[1].level)
            end)

            it('explicit logMap entry wins over case-variant resolution', function()
                -- A driver whose logger uses a renamed method (e.g.
                -- `Alert` for fatal) supplies it via logMap. The
                -- variant chain would otherwise miss it.
                local anvil = freshAnvil()
                local forwarded = {}
                anvil.forwardLog = function(_, level, message)
                    table.insert(forwarded, { level = level, message = message })
                end

                local logger = {
                    Alert = function() end,  -- semantic mismatch
                    Info  = function() end,
                }
                anvil:installLoggerProxy(logger, { fatal = 'Alert' })

                logger:Alert('catastrophe')
                assert.are.equal(1, #forwarded)
                assert.are.equal('FATAL', forwarded[1].level)

                -- And case-variant fallback still works for the other
                -- level we didn't supply explicitly.
                logger:Info('alright')
                assert.are.equal(2, #forwarded)
                assert.are.equal('INFO', forwarded[2].level)
            end)

            it('lowercase variant wins when both lowercase and PascalCase exist', function()
                -- Priority order: lowercase first. A driver exposing
                -- both is pathological; we pick deterministically.
                local anvil = freshAnvil()
                local forwarded = {}
                anvil.forwardLog = function(_, level, message)
                    table.insert(forwarded, { level = level, message = message })
                end

                local lowerCalls, upperCalls = 0, 0
                local logger = {
                    info = function() lowerCalls = lowerCalls + 1 end,
                    Info = function() upperCalls = upperCalls + 1 end,
                }
                anvil:installLoggerProxy(logger)

                logger:info('lower')
                logger:Info('upper')

                -- Both call sites still fire (we wrap only `info`,
                -- leave `Info` untouched). The lowercase one forwards;
                -- the PascalCase one doesn't.
                assert.are.equal(1, #forwarded)
                assert.are.equal(1, lowerCalls)
                assert.are.equal(1, upperCalls)
            end)

            it('emits an anvil:debug warning when multiple variants exist', function()
                -- The warning helps a developer who's troubleshooting
                -- "why is one variant not forwarding?" find the
                -- ambiguity. Fires only when Anvil Debug Logging is on.
                _G.Properties = { ['Anvil Debug Logging'] = 'On' }
                local anvil = freshAnvil()
                anvil.forwardLog = function() end
                anvil:initDebugCache()

                local printed = {}
                local origPrint = _G.print
                _G.print = function(s) table.insert(printed, s) end

                local logger = {
                    info = function() end,
                    Info = function() end,
                }
                anvil:installLoggerProxy(logger)

                _G.print = origPrint

                local sawWarning = false
                for _, line in ipairs(printed) do
                    if line:find("Multiple method variants for level 'info'") then
                        sawWarning = true
                        break
                    end
                end
                assert.is_true(sawWarning,
                    "expected debug warning about multiple variants for 'info'")
            end)

            it('skips levels the logger does not implement', function()
                -- A logger that only implements a subset (say, no
                -- Trace) should still wrap the levels it does have.
                local anvil = freshAnvil()
                local forwarded = {}
                anvil.forwardLog = function(_, level, message)
                    table.insert(forwarded, { level = level, message = message })
                end

                local logger = { Info = function() end }
                anvil:installLoggerProxy(logger)

                logger:Info('only level we have')

                assert.are.equal(1, #forwarded)
                -- Trace simply isn't there; nothing to wrap.
                assert.is_nil(logger.Trace)
                assert.is_nil(logger.trace)
                assert.is_nil(logger.TRACE)
            end)
        end)
    end)

    describe('queue / start integration', function()
        before_each(function() stubC4() end)

        it('queues sendData calls until start() flips _agentReady', function()
            local anvil = freshAnvil()
            local sent = {}
            -- Simulate the agent being installed but not yet ready. Capture
            -- the C4:SendToDevice call that anvil.sendData makes after the
            -- queue is drained.
            _G.C4.SendToDevice = function(_, _, _, params) table.insert(sent, params) end
            _G.C4.JsonEncode = function(_, value) return tostring(value) end
            _G.Properties = {}

            anvil:sendData({ payload = 'hello' })
            assert.are.equal(0, #sent)
            local Queue = require 'queue'
            assert.are.equal(1, Queue.length(anvil._eventQueue))

            anvil:start()
            assert.are.equal(1, #sent)
        end)

        it('does NOT forward _clientOptions to the agent envelope (regression guard)', function()
            -- The SDK must not forward client options to the agent. Earlier,
            -- sendData attached `data["opts"] = self._clientOptions` before
            -- publishing; the agent ignores client-supplied configuration, so
            -- the forward was removed entirely. logger/logMap stay in-process.
            local anvil = freshAnvil()
            local sent = {}
            -- Capture whatever JSON the SDK actually sends to the agent so
            -- we can introspect the payload shape.
            local lastEncoded
            _G.C4.JsonEncode = function(_, value) lastEncoded = value; return 'stub-json' end
            _G.C4.SendToDevice = function(_, _, _, params) table.insert(sent, params) end
            _G.Properties = {}

            anvil._clientOptions = {
                baseUrl = 'evil.example',
                port = 8883,
                logger = {},
            }
            anvil:start()
            anvil:sendData({ eventType = 'event', payload = { id = 'e1' } })

            assert.are.equal(1, #sent)
            assert.is_table(lastEncoded)
            assert.is_nil(lastEncoded.opts,
                '_clientOptions must not appear on the wire')
        end)
    end)

    describe('captureError', function()
        before_each(function() stubC4() end)

        it('queues an error payload when no event is in flight', function()
            local anvil = freshAnvil()
            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            local fakeStack = { schemaVersion = 1, captureKind = 'callsite', status = 'complete' }
            anvil:captureError('manual error', fakeStack, { eventName = 'Manual', args = {} })

            assert.are.equal(1, #sent)
            assert.are.equal('error', sent[1].eventType)
            assert.are.equal('manual error', sent[1].payload.value)
            assert.are.equal('Manual', sent[1].payload.eventName)
        end)
        it('captures the manual reporting callsite as structured data', function()
            local anvil = freshAnvil()
            local sent
            anvil.sendData = function(_, payload) sent = payload end
            anvil:captureError('manual report')
            assert.are.equal('callsite', sent.payload.stacktrace.captureKind)
            assert.is_truthy(sent.payload.stacktrace.frames[1].source.name:find('client_spec.lua', 1, true))
        end)

        it('does not capture or submit when disabled or an agent is absent', function()
            local anvil = freshAnvil()
            local Diagnostics = require 'diagnostics'
            local originalCapture = Diagnostics.capture
            local calls = 0
            Diagnostics.capture = function() calls = calls + 1 end
            anvil.sendData = function() calls = calls + 1 end
            anvil._instrumentationDisabled = true
            anvil:captureError('ignored')
            anvil._instrumentationDisabled = false
            anvil._hasLateInited = true
            anvil.isAgentInstalled = function() return false end
            anvil:captureError('ignored')
            Diagnostics.capture = originalCapture
            assert.are.equal(0, calls)
        end)

    end)

    describe('SetTimer', function()
        -- The C4 runtime is LuaJIT WITHOUT 5.2 compat: `table.unpack` is nil
        -- and only the global `unpack` exists. busted's own dependency chain
        -- (penlight's pl.compat) aliases table.unpack = unpack globally, which
        -- masks any accidental table.unpack use from every spec. Remove the
        -- alias for this block so these specs see the controller's real
        -- surface — with it in place, a table.unpack regression passes CI and
        -- crashes on hardware.
        local penlightUnpackAlias

        before_each(function()
            penlightUnpackAlias = table.unpack
            table.unpack = nil

            stubC4()
            -- Director-side C4:SetTimer: fire the callback immediately with a
            -- timer handle, forwarding any extra registration args, and return
            -- the handle — the contract anvil:setTimer wraps.
            _G.C4.SetTimer = function(_, _, callback, ...)
                local handle = { id = 'timer-1' }
                callback(handle, ...)
                return handle
            end
        end)

        after_each(function()
            table.unpack = penlightUnpackAlias
        end)

        it('fires the callback with the timer handle and extra args, returning the handle', function()
            local anvil = freshAnvil()
            local fired

            local handle = anvil:setTimer(50, function(timer, a, b)
                fired = { timer = timer, a = a, b = b }
            end, 'alpha', 'beta')

            assert.are.equal('timer-1', handle.id)
            assert.are.equal('timer-1', fired.timer.id)
            assert.are.equal('alpha', fired.a)
            assert.are.equal('beta', fired.b)
        end)

        it('reports a callback error in an envelope named for the caller, then re-raises', function()
            local anvil = freshAnvil()
            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            -- The stub Director fires the callback synchronously, so the
            -- re-raised error surfaces from the registration call itself.
            local ok, err = pcall(function()
                anvil:setTimer(50, function()
                    error('timer exploded')
                end)
            end)

            -- Report, don't handle: the envelope goes out and the error
            -- still propagates as an unwrapped C4:SetTimer callback's would.
            assert.is_false(ok)
            assert.is_truthy(tostring(err):match('timer exploded'))
            assert.are.equal(1, #sent)
            assert.are.equal('error', sent[1].eventType)
            assert.is_truthy(sent[1].payload.value:match('timer exploded'))
            assert.is_truthy(sent[1].payload.eventName:match('^Timer@'))
            assert.is_nil(sent[1].payload.fingerprint)
        end)

        it('marks the timer callback wrapper as SDK-owned', function()
            local anvil = freshAnvil()
            local sent
            anvil.sendData = function(_, payload) sent = payload end
            pcall(function() anvil:setTimer(20, function() error('driver timer error') end) end)
            local found = false
            for _, frame in ipairs(sent.payload.stacktrace.frames) do
                if frame.functionName == 'timerCallback' then
                    found = true
                    assert.are.equal('sdk', frame.role)
                    assert.are.equal('registered', frame.nameOrigin)
                end
            end
            assert.is_true(found)
        end)

        it('preserves nil, false and table errors when capture or submission fails', function()
            local Diagnostics = require 'diagnostics'
            local originalCapture = Diagnostics.capture
            local values = { { value = nil }, { value = false }, { value = {} } }
            for _, failure in ipairs({ 'capture', 'submission' }) do
                for _, box in ipairs(values) do
                    local anvil = freshAnvil()
                    anvil.reportSdkFault = function() end
                    Diagnostics.capture = failure == 'capture' and function() error('capture failed') end or originalCapture
                    anvil.sendData = function() error('submission failed') end
                    local ok, err = pcall(function()
                        anvil:setTimer(50, function() error(box.value, 0) end)
                    end)
                    Diagnostics.capture = originalCapture
                    assert.is_false(ok)
                    assert.are.equal(box.value, err)
                end
            end
        end)

        it('bypasses capture at callback time when instrumentation is inactive', function()
            local anvil = freshAnvil()
            local callback
            C4.SetTimer = function(_, _, fn) callback = fn end
            anvil:setTimer(50, function() error('driver failure', 0) end)
            anvil._hasLateInited = true
            anvil.isAgentInstalled = function() return false end
            local Diagnostics = require 'diagnostics'
            local originalCapture = Diagnostics.capture
            local captures = 0
            Diagnostics.capture = function() captures = captures + 1 end
            local ok, err = pcall(callback, {})
            Diagnostics.capture = originalCapture
            assert.is_false(ok)
            assert.are.equal('driver failure', err)
            assert.are.equal(0, captures)
        end)

        it('reports errors through nested timers and handlers only once', function()
            for _, withHandler in ipairs({ false, true }) do
                local anvil = freshAnvil()
                local sent = {}
                anvil.sendData = function(_, payload)
                    if payload.eventType == 'error' then sent[#sent + 1] = payload end
                end
                local thrown = {}
                local ok, err = pcall(function()
                    anvil:setTimer(50, function()
                        local function inner()
                            anvil:setTimer(20, function() error(thrown, 0) end)
                        end
                        if withHandler then anvil:instrument('OnPropertyChanged', inner)
                        else inner() end
                    end)
                end)
                assert.is_false(ok)
                assert.are.equal(thrown, err)
                assert.are.equal(1, #sent)
                assert.are.equal(0, anvil._timerDepth)
                assert.are.equal(0, anvil._instrumentDepth or 0)
            end
        end)

        it('skips registration diagnostics without an agent and captures future timer errors', function()
            local anvil = freshAnvil()
            anvil._hasLateInited = true
            local installed = false
            anvil.isAgentInstalled = function() return installed end
            local callback, sent
            C4.SetTimer = function(_, _, fn) callback = fn end
            anvil.sendData = function(_, payload) sent = payload end
            local calls = 0
            withDebugStubs({
                getinfo = function() calls = calls + 1; error('debug unavailable') end,
            }, function()
                anvil:setTimer(20, function() error('later failure', 0) end)
            end)
            assert.are.equal(0, calls)
            installed = true
            local ok, err = pcall(callback, {})
            assert.is_false(ok)
            assert.are.equal('later failure', err)
            assert.are.equal('error', sent.eventType)
        end)

        it('still schedules a timer when caller metadata capture fails', function()
            local anvil = freshAnvil()
            local called = false
            withDebugStubs({
                getinfo = function() error('debug unavailable') end,
            }, function()
                anvil:setTimer(20, function() called = true end)
            end)
            assert.is_true(called)
        end)

        it('hands the Director the callback return list unchanged, embedded nils included', function()
            local anvil = freshAnvil()

            -- Director-side stub that consumes the callback's returns, as
            -- the real dispatcher may.
            local n, vals
            _G.C4.SetTimer = function(_, _, callback)
                n = select('#', callback({ id = 'timer-1' }))
                vals = { callback({ id = 'timer-1' }) }
            end

            anvil:setTimer(50, function()
                return 'first', nil, 3
            end)

            assert.are.equal(3, n)
            assert.are.equal('first', vals[1])
            assert.is_nil(vals[2])
            assert.are.equal(3, vals[3])
        end)
    end)

    describe('sendLifecycle', function()
        before_each(function() stubC4() end)

        it('sends a lifecycle envelope carrying the phase and driver version', function()
            local anvil = freshAnvil()
            anvil._driverVersion = '1.2.3'
            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            anvil:sendLifecycle('ready')

            assert.are.equal(1, #sent)
            assert.are.equal('lifecycle', sent[1].eventType)
            assert.are.equal('ready', sent[1].payload.phase)
            assert.are.equal('1.2.3', sent[1].payload.driverVersion)
            -- identity stamped by generatePayload
            assert.are.equal('driver.c4z', sent[1].payload.driver)
            assert.are.equal('AA:BB:CC', sent[1].payload.controller)
        end)
    end)

    describe('queueItem cap', function()
        before_each(function() stubC4() end)
        after_each(function() _G.Properties = nil end)

        it('bounds the pre-agent queue, dropping the oldest entries', function()
            local anvil = freshAnvil()
            anvil.MAX_QUEUED_EVENTS = 3

            -- Agent never ready (e.g. never installed, or a clobbered
            -- OnDriverLateInit): everything routes to the queue.
            for i = 1, 5 do
                anvil:sendData({ eventType = 'log', payload = 'item-' .. i })
            end

            local Queue = require 'queue'
            assert.are.equal(3, Queue.length(anvil._eventQueue))

            -- Drain: the survivors are the NEWEST three, in order.
            local sent = {}
            _G.C4.SendToDevice = function(_, _, _, params) table.insert(sent, params) end
            _G.C4.JsonEncode = function(_, value) return value end
            _G.Properties = {}
            anvil:start()

            assert.are.equal(3, #sent)
            assert.are.equal('item-3', sent[1].payload.payload)
            assert.are.equal('item-4', sent[2].payload.payload)
            assert.are.equal('item-5', sent[3].payload.payload)
        end)

        it('ships with a bound generous enough for real pre-agent buffering', function()
            local anvil = freshAnvil()

            -- The exact number matters less than there BEING one; pin it so
            -- a future edit can't silently remove the bound.
            assert.is_number(anvil.MAX_QUEUED_EVENTS)
            assert.is_true(anvil.MAX_QUEUED_EVENTS >= 100)
        end)

        it('discardQueue empties the buffer and resets the dropped counter', function()
            local anvil = freshAnvil()
            anvil:sendData({ eventType = 'log', payload = 'x' })
            anvil._droppedQueuedEvents = 5

            anvil:discardQueue()

            local Queue = require 'queue'
            assert.are.equal(0, Queue.length(anvil._eventQueue))
            assert.are.equal(0, anvil._droppedQueuedEvents)
        end)
    end)

    describe('verifyAndStart (agent identity verification)', function()
        local AgentVerify = require 'agent_verify'
        local realVerifyProof = AgentVerify.verifyProof
        after_each(function()
            AgentVerify.ROOT_PUBLIC_KEYS = {}
            AgentVerify.verifyProof = realVerifyProof
        end)

        -- A discovered-agent anvil, with the challenge send + timer captured.
        local function discoveredAnvil(c4extra)
            local sends, timers = {}, {}
            stubC4({
                GetDeviceID = function() return 77 end,
                GetUniqueMAC = function() return 'AA:BB:CC' end,
                -- Verification needs a digest and nothing else off C4.
                Hash = function() return string.rep('ab', 32) end,
                SendToDevice = function(_, id, cmd, params)
                    table.insert(sends, { id = id, cmd = cmd, params = params })
                end,
                SetTimer = function(_, ms, cb)
                    local t = { ms = ms, cb = cb, cancelled = false }
                    t.Cancel = function() t.cancelled = true end
                    table.insert(timers, t)
                    return t
                end,
            })
            local anvil = freshAnvil()
            anvil._hasLateInited = true
            anvil.AGENT_DEVICE_ID = 42
            return anvil, sends, timers
        end

        it('starts immediately when no attestation root is embedded (disabled)', function()
            AgentVerify.ROOT_PUBLIC_KEYS = {}
            local anvil, sends = discoveredAnvil()

            anvil:verifyAndStart()

            assert.is_true(anvil:isAgentReady())
            assert.are.equal(0, #sends)  -- no challenge issued
        end)

        it('challenges the agent and stays pending (not ready) until a proof arrives', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }  -- enabled; verifyProof is stubbed below
            local anvil, sends = discoveredAnvil()

            anvil:verifyAndStart()

            assert.are.equal('pending', anvil._verifyState)
            assert.is_false(anvil:isAgentReady())
            assert.are.equal(1, #sends)
            assert.are.equal(42, sends[1].id)
            assert.are.equal(AgentVerify.CHALLENGE_COMMAND, sends[1].cmd)
            assert.are.equal(77, tonumber(anvil._verifyChallengerId))
            assert.is_string(sends[1].params.nonce)
        end)

        it('starts once a valid proof is verified', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil, sends, timers = discoveredAnvil()
            AgentVerify.verifyProof = function() return true end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            assert.are.equal('verified', anvil._verifyState)
            assert.is_true(anvil:isAgentReady())
            assert.is_true(timers[1].cancelled)  -- deadline disarmed
        end)

        it('fails closed on an invalid proof: agent cleared, queue discarded', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil, sends = discoveredAnvil()
            AgentVerify.verifyProof = function() return nil, 'challenge signature invalid' end

            anvil:verifyAndStart()
            anvil:sendData({ eventType = 'log', payload = 'queued-while-pending' })
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            assert.are.equal('failed', anvil._verifyState)
            assert.is_false(anvil:isAgentReady())
            assert.is_nil(anvil.AGENT_DEVICE_ID)
            local Queue = require 'queue'
            assert.are.equal(0, Queue.length(anvil._eventQueue))
        end)

        it('fails closed when the deadline fires with no proof', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil, sends, timers = discoveredAnvil()

            anvil:verifyAndStart()
            timers[1].cb()  -- deadline expires

            assert.are.equal('failed', anvil._verifyState)
            assert.is_nil(anvil.AGENT_DEVICE_ID)
        end)

        it('ignores a proof carrying the wrong nonce (stays pending, deadline still guards)', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil = discoveredAnvil()
            AgentVerify.verifyProof = function() error('should not be called') end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = 'not-the-nonce' })

            assert.are.equal('pending', anvil._verifyState)
        end)

        it('routes the proof command through handleProtocolCommand and swallows it', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil, sends = discoveredAnvil()
            AgentVerify.verifyProof = function() return true end
            anvil:verifyAndStart()

            local swallowed = anvil:handleProtocolCommand(
                AgentVerify.PROOF_COMMAND, { nonce = sends[1].params.nonce })

            assert.is_true(swallowed)
            assert.are.equal('verified', anvil._verifyState)
            -- A normal command is not intercepted.
            assert.is_false(anvil:handleProtocolCommand('SOME_DRIVER_COMMAND', {}))
        end)

        it('clears agent-ready state so a failure stops the send path', function()
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            local anvil, sends = discoveredAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            -- A driver that was verified against the previous agent.
            anvil._agentReady = true
            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            assert.is_false(anvil:isAgentReady())
            -- With AGENT_DEVICE_ID cleared, a still-true _agentReady would send
            -- every subsequent envelope to a nil device.
            local before = #sends
            anvil:sendData({ eventType = 'log', payload = 'after-failure' })
            assert.are.equal(before, #sends)
        end)
    end)

    -- A driver latched off by a failed verification must be able to come back.
    -- The failure that matters is not impersonation: it is a just-installed
    -- agent that has not logged in or registered yet, so it holds no
    -- attestation at the exact moment the SDK challenges it.
    describe('recovery from a failed verification', function()
        local AgentVerify = require 'agent_verify'
        local realVerifyProof = AgentVerify.verifyProof
        after_each(function()
            AgentVerify.ROOT_PUBLIC_KEYS = {}
            AgentVerify.verifyProof = realVerifyProof
        end)

        -- As discoveredAnvil above, but discovery is stubbed too so the retry
        -- path (which re-runs discoverAnvilAgent) actually finds the agent.
        local function latchableAnvil(agentPresent)
            local sends, timers, prints = {}, {}, {}
            local present = agentPresent ~= false
            stubC4({
                GetDeviceID = function() return 77 end,
                GetUniqueMAC = function() return 'AA:BB:CC' end,
                -- Verification needs a digest and nothing else off C4.
                Hash = function() return string.rep('ab', 32) end,
                GetDevicesByC4iName = function()
                    if not present then return {} end
                    return { [42] = 'anvil-agent' }
                end,
                SendToDevice = function(_, id, cmd, params)
                    table.insert(sends, { id = id, cmd = cmd, params = params })
                end,
                SetTimer = function(_, ms, cb)
                    local t = { ms = ms, cb = cb, cancelled = false }
                    t.Cancel = function() t.cancelled = true end
                    table.insert(timers, t)
                    return t
                end,
            })
            local anvil = freshAnvil()
            anvil._hasLateInited = true
            anvil.AGENT_DEVICE_ID = 42
            AgentVerify.ROOT_PUBLIC_KEYS = { test = 'ROOT' }
            return anvil, sends, timers, prints,
                function(v) present = v end
        end

        -- Fire every armed-but-unfired retry timer, newest first is wrong here:
        -- the ladder arms one at a time, so just walk forward and fire any
        -- retry-shaped timer we have not fired yet.
        local function fireRetries(timers, count)
            local fired = 0
            local i = 1
            while fired < count do
                local t = timers[i]
                if not t then break end
                i = i + 1
                -- The verification deadline is TIMEOUT_MS; anything longer is a
                -- ladder rung.
                if t.ms > AgentVerify.TIMEOUT_MS and not t.cancelled and not t.fired then
                    t.fired = true
                    t.cb()
                    fired = fired + 1
                end
            end
            return fired
        end

        it('arms a bounded retry ladder when verification fails', function()
            local anvil, sends, timers = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            assert.are.equal('failed', anvil._verifyState)
            -- timers[1] is the 10s deadline (cancelled); timers[2] is rung one.
            assert.are.equal(AgentVerify.RETRY_DELAYS_MS[1], timers[2].ms)
            assert.are.equal(1, anvil._verifyRetryAttempt)
        end)

        it('recovers on a retry once the agent can answer', function()
            local anvil, sends, timers = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })
            assert.is_nil(anvil.AGENT_DEVICE_ID)

            -- The agent finishes registering; the announcement is lost.
            AgentVerify.verifyProof = function() return true end
            fireRetries(timers, 1)

            -- Rediscovered and re-challenged.
            assert.are.equal(42, anvil.AGENT_DEVICE_ID)
            local challenge = sends[#sends]
            assert.are.equal(AgentVerify.CHALLENGE_COMMAND, challenge.cmd)

            anvil:handleVerifyProof({ nonce = challenge.params.nonce })
            assert.are.equal('verified', anvil._verifyState)
            assert.is_true(anvil:isAgentReady())
        end)

        it('recovers immediately on the agent readiness announcement', function()
            local anvil, sends, timers = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })
            assert.are.equal('failed', anvil._verifyState)
            local ladderRung = timers[2]

            -- The agent registers and announces; no timer has fired.
            AgentVerify.verifyProof = function() return true end
            local swallowed = anvil:handleProtocolCommand(
                AgentVerify.READY_COMMAND, { agentDeviceId = '42' })

            assert.is_true(swallowed)
            assert.is_true(ladderRung.cancelled)  -- superseded, no duplicate challenge
            local challenge = sends[#sends]
            assert.are.equal(AgentVerify.CHALLENGE_COMMAND, challenge.cmd)

            anvil:handleVerifyProof({ nonce = challenge.params.nonce })
            assert.are.equal('verified', anvil._verifyState)
            assert.is_true(anvil:isAgentReady())
        end)

        it('ignores a readiness announcement when not latched', function()
            local anvil, sends = latchableAnvil()
            AgentVerify.verifyProof = function() return true end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })
            assert.are.equal('verified', anvil._verifyState)

            local before = #sends
            anvil:handleProtocolCommand(AgentVerify.READY_COMMAND, {})

            -- No re-challenge: a spoofed announcement cannot knock a working
            -- driver back into the handshake.
            assert.are.equal(before, #sends)
            assert.is_true(anvil:isAgentReady())
        end)

        it('bounds how many announcements can trigger a re-challenge', function()
            local anvil, sends = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'challenge signature invalid' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            for _ = 1, AgentVerify.MAX_ANNOUNCE_RETRIES + 5 do
                anvil:handleProtocolCommand(AgentVerify.READY_COMMAND, {})
                -- Each accepted announcement re-challenges and immediately
                -- fails again, returning to the latched state.
                if anvil._verifyState == 'pending' then
                    anvil:handleVerifyProof({ nonce = sends[#sends].params.nonce })
                end
            end

            assert.are.equal(AgentVerify.MAX_ANNOUNCE_RETRIES, anvil._verifyAnnounceRetries)
            assert.are.equal('failed', anvil._verifyState)
        end)

        it('stays terminally disabled against a genuine impostor', function()
            local anvil, sends, timers = latchableAnvil()
            -- Whatever answers, it never produces a valid proof.
            AgentVerify.verifyProof = function() return nil, 'challenge signature invalid' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            -- Walk the whole ladder, failing each rung.
            for _ = 1, #AgentVerify.RETRY_DELAYS_MS + 2 do
                fireRetries(timers, 1)
                if anvil._verifyState == 'pending' then
                    anvil:handleVerifyProof({ nonce = sends[#sends].params.nonce })
                end
            end

            assert.are.equal('failed', anvil._verifyState)
            assert.is_false(anvil:isAgentReady())
            assert.is_nil(anvil.AGENT_DEVICE_ID)
            -- The ladder is exhausted, not endlessly re-arming.
            assert.are.equal(#AgentVerify.RETRY_DELAYS_MS, anvil._verifyRetryAttempt)
        end)

        it('keeps the ladder walking when discovery finds no agent yet', function()
            local anvil, sends, timers, _, setPresent = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })

            setPresent(false)
            local sendsBefore = #sends
            fireRetries(timers, 1)

            -- Nothing to challenge, but the next rung is armed.
            assert.are.equal(sendsBefore, #sends)
            assert.are.equal(2, anvil._verifyRetryAttempt)
        end)

        it('arms no ladder when the runtime cannot verify at all', function()
            local anvil, _, timers = latchableAnvil()
            _G.C4.GetDeviceID = function() error('no device id') end

            anvil:verifyAndStart()

            assert.are.equal('failed', anvil._verifyState)
            assert.are.equal(0, #timers)  -- neither a deadline nor a retry rung
            assert.is_nil(anvil._verifyRetryAttempt)
        end)

        it('resets both retry budgets once verification succeeds', function()
            local anvil, sends, timers = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })
            anvil:handleProtocolCommand(AgentVerify.READY_COMMAND, {})
            assert.are.equal(1, anvil._verifyAnnounceRetries)

            AgentVerify.verifyProof = function() return true end
            anvil:handleVerifyProof({ nonce = sends[#sends].params.nonce })

            assert.are.equal('verified', anvil._verifyState)
            assert.are.equal(0, anvil._verifyRetryAttempt)
            assert.are.equal(0, anvil._verifyAnnounceRetries)
        end)

        it('surfaces the disabled state and its reason, then clears it', function()
            local anvil, sends = latchableAnvil()
            AgentVerify.verifyProof = function() return nil, 'missing attestation' end

            anvil:verifyAndStart()
            assert.are.equal('verifying', anvil:telemetryStatus().state)

            anvil:handleVerifyProof({ nonce = sends[1].params.nonce })
            local status = anvil:telemetryStatus()
            assert.is_false(status.enabled)
            assert.are.equal('disabled', status.state)
            assert.are.equal('missing attestation', status.reason)

            AgentVerify.verifyProof = function() return true end
            anvil:handleProtocolCommand(AgentVerify.READY_COMMAND, {})
            anvil:handleVerifyProof({ nonce = sends[#sends].params.nonce })

            local recovered = anvil:telemetryStatus()
            assert.is_true(recovered.enabled)
            assert.are.equal('ready', recovered.state)
            assert.is_nil(recovered.reason)
        end)
    end)

    describe('sendData', function()
        after_each(function() _G.Properties = nil end)

        local function readyAnvil(props, c4extra)
            stubC4(c4extra)
            local anvil = freshAnvil()
            anvil._agentReady = true
            anvil.AGENT_DEVICE_ID = 99
            _G.Properties = props or {}
            return anvil
        end

        it('sends immediately when no debug delay is set', function()
            local sent = {}
            local anvil = readyAnvil({}, {
                SendToDevice = function(_, dev) table.insert(sent, dev) end,
                JsonEncode = function() return 'json' end,
            })
            anvil:sendData({ foo = 1 })
            assert.are.equal(1, #sent)
            assert.are.equal(99, sent[1])
        end)

        it('drops instead of queueing once late-init has found no agent', function()
            stubC4()
            local anvil = freshAnvil()
            -- Late-init ran and discovery came up empty (no AGENT_DEVICE_ID):
            -- envelopes must not accumulate anywhere.
            anvil._hasLateInited = true
            _G.Properties = {}

            anvil:sendData({ foo = 1 })

            local Queue = require 'queue'
            assert.are.equal(0, Queue.length(anvil._eventQueue))
        end)

        it('does not crash and still sends when Anvil Debug Delay is non-numeric', function()
            -- Regression: a string/garbage delay used to be passed straight to
            -- C4:SetTimer, which raised "Invalid argument value" and aborted
            -- late-init (and the ready beacon). Now it degrades to an immediate send.
            local sent = {}
            local anvil = readyAnvil({ ['Anvil Debug Delay'] = 'oops' }, {
                SendToDevice = function(_, dev) table.insert(sent, dev) end,
                JsonEncode = function() return 'json' end,
                SetTimer = function() error('Invalid argument value') end,  -- as the controller does
            })
            assert.has_no.errors(function() anvil:sendData({ foo = 1 }) end)
            assert.are.equal(1, #sent)   -- fell back to immediate send
        end)

        it('arms a timer (coerced to a number) when the delay is a positive numeric string', function()
            local timers = {}
            local anvil = readyAnvil({ ['Anvil Debug Delay'] = '100' }, {
                SendToDevice = function() end,
                JsonEncode = function() return 'json' end,
                SetTimer = function(_, ms, cb) table.insert(timers, { ms = ms, cb = cb }) end,
            })
            anvil:sendData({ foo = 1 })
            assert.are.equal(1, #timers)
            assert.are.equal(100, timers[1].ms)  -- number, not the "100" string
        end)
    end)
end)
