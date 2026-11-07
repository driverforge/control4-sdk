describe('harness', function()
    local function clearAnvilModules()
        package.loaded.client = nil
        package.loaded.harness = nil
        package.loaded.version = nil
        _G.Anvil = nil
        -- Both namespaces are `X = X or {...}`, so a stale global would stay
        -- bound to the previous module instance and every assertion after the
        -- first load would read the wrong table.
        _G.Driverforge = nil
        -- harness defines handler globals (OnDriverLateInit, OnPropertyChanged,
        -- …); clear the ones we exercise so a fresh `require 'client'` captures
        -- them as nil (unimplemented), matching a clean process. Otherwise a
        -- prior test's global leaks in as an "implemented" handler.
        _G.OnDriverLateInit = nil
        _G.OnPropertyChanged = nil
        _G.OnDriverAdded = nil
        _G.ExecuteCommand = nil
        _G.ReceivedFromProxy = nil
    end

    local function loadHarness(c4Overrides, properties, handlers)
        clearAnvilModules()
        for name, handler in pairs(handlers or {}) do _G[name] = handler end
        _G.C4 = c4Overrides or {
            GetUniqueMAC = function() return 'AA:BB:CC' end,
            GetTime = function() return 0 end,
            GetDriverConfigInfo = function(_, key)
                if key == 'version' then return '0.9.9' end
                return nil
            end,
            UUID = function() return 'uuid' end,
        }
        _G.Properties = properties or { ['Anvil Debug Logging'] = 'Off' }

        require 'harness'
        return _G.Anvil, package.loaded.client
    end

    after_each(function()
        clearAnvilModules()
        _G.Properties = nil
        _G.C4 = nil
    end)

    it('exposes Anvil with the public API surface', function()
        local Anvil = loadHarness()

        assert.is_function(Driverforge.Init)
        assert.is_function(Anvil.OnDriverInit)
        assert.is_function(Anvil.ForwardLog)
        assert.is_function(Anvil.CaptureError)
        assert.is_function(Anvil.SetTimer)
        assert.is_function(Anvil.TelemetryStatus)
    end)

    it('ForwardLog takes log-call arguments, tables included', function()
        local Anvil, anvil = loadHarness()
        local sent = {}
        anvil.sendData = function(_, payload) table.insert(sent, payload) end

        Anvil:ForwardLog('INFO', 'state:', { power = 'on' })
        Anvil:ForwardLog('WARN', 'plain message')

        assert.are.equal(2, #sent)
        assert.are.equal('state: [table]', sent[1].payload.message)
        assert.are.same({ 'state:', { power = 'on' } }, sent[1].payload.args)
        assert.are.equal('plain message', sent[2].payload.message)
        assert.is_nil(sent[2].payload.args)
    end)

    it('TelemetryStatus lets a driver see that it is sending into a void', function()
        local Anvil, anvil = loadHarness()
        Driverforge:Init('drv_token')

        -- Before late init nothing has been decided yet.
        assert.are.equal('initialising', Anvil:TelemetryStatus().state)

        anvil._hasLateInited = true
        assert.are.equal('no-agent', Anvil:TelemetryStatus().state)

        anvil:failVerification('missing attestation', { retryable = false })
        local status = Anvil:TelemetryStatus()
        assert.is_false(status.enabled)
        assert.are.equal('disabled', status.state)
        assert.are.equal('missing attestation', status.reason)
    end)

    it('Init wires the driver token onto the underlying client', function()
        local Anvil, anvil = loadHarness()

        Driverforge:Init('drv_my_token')

        assert.are.equal('drv_my_token', anvil._token)
    end)

    it('Init does not resolve the driver filename', function()
        -- The filename is needed for telemetry attribution and nothing else,
        -- so resolving it at Init would impose C4:GetDriverFileName (3.3.0) on
        -- the licence surface, which needs nothing of the sort.
        local resolved = false
        local Anvil, anvil = loadHarness({
            GetUniqueMAC = function() return 'AA' end,
            GetTime = function() return 0 end,
            UUID = function() return 'uuid' end,
            GetDriverFileName = function() resolved = true; return 'mydriver.c4z' end,
        })

        Driverforge:Init('drv_x')
        assert.is_false(resolved)
        assert.is_nil(anvil._driverFileName)

        -- It resolves on first use, and memoizes.
        assert.are.equal('mydriver.c4z', anvil:driverFileName())
        assert.is_true(resolved)
        assert.are.equal('mydriver.c4z', anvil._driverFileName)
    end)

    it('Init captures the driver version from C4:GetDriverConfigInfo', function()
        local Anvil, anvil = loadHarness()

        Driverforge:Init('drv_x')

        assert.are.equal('0.9.9', anvil._driverVersion)
    end)

    it("Init falls back to 'unknown' when version is not set", function()
        local Anvil, anvil = loadHarness({
            GetUniqueMAC = function() return 'AA' end,
            GetTime = function() return 0 end,
            UUID = function() return 'uuid' end,
            GetDriverConfigInfo = function() return nil end,
        })

        Driverforge:Init('drv_x')

        assert.are.equal('unknown', anvil._driverVersion)
    end)

    it("Init falls back to 'unknown' when C4:GetDriverConfigInfo isn't available", function()
        local Anvil, anvil = loadHarness({
            GetUniqueMAC = function() return 'AA' end,
            GetTime = function() return 0 end,
            UUID = function() return 'uuid' end,
            -- GetDriverConfigInfo intentionally omitted
        })

        Driverforge:Init('drv_x')

        assert.are.equal('unknown', anvil._driverVersion)
    end)

    it('Init captures the SDK version from version.lua without polluting _G', function()
        local Anvil, anvil = loadHarness()

        Driverforge:Init('drv_x')

        -- version.lua is a module return. Whatever the current build
        -- asserts, it has to match what landed on the anvil.
        assert.are.equal(require 'version', anvil._sdkVersion)
        assert.is_string(anvil._sdkVersion)
        -- Must be a real value, not the pre-Init default sentinel.
        assert.are_not.equal('unknown', anvil._sdkVersion)
        -- The point of the module return: no global leaks into the host
        -- driver's environment.
        assert.is_nil(_G.SDK_VERSION)
    end)

    it('Init installs the forwarding proxy on the caller-supplied logger', function()
        -- The end-to-end contract: pass your existing logger via
        -- opts.logger, then call sites in your driver that already say
        -- Log:Info(...) auto-forward to Anvil. Earlier the SDK
        -- assigned a new proxy to a dead Anvil.logger field; this test
        -- guards against that regression by exercising the original
        -- logger reference directly after Init.
        local Anvil, anvilModule = loadHarness()

        local forwarded = {}
        anvilModule.forwardLog = function(_, level, message)
            table.insert(forwarded, { level = level, message = message })
        end

        local seenUnderlying = {}
        local logger = {
            info = function(self, msg) table.insert(seenUnderlying, msg) end,
        }
        Driverforge:Init('drv_x', { logger = logger })

        -- Call the SAME logger reference the test passed in — no
        -- assignment from Anvil.logger.
        logger:info('routed')

        -- Forwarded to Anvil
        assert.are.equal(1, #forwarded)
        assert.are.equal('INFO', forwarded[1].level)
        assert.are.equal('routed', forwarded[1].message)

        -- And the original logger still received the call.
        assert.are.equal('routed', seenUnderlying[1])

        -- Anvil.logger field is no longer set — it was dropped
        -- because nothing reads it.
        assert.is_nil(Anvil.logger)
    end)

    describe('handler return parity', function()
        local unpack = table.unpack or unpack
        local function pack(...) return { n = select('#', ...), ... } end

        local function prepare(mode, name, handler)
            local handlers = name ~= 'Anvil:OnDriverInit' and { [name] = handler } or {}
            local _, anvil = loadHarness({
                GetUniqueMAC = function() return 'AA:BB:CC' end,
                GetTime = function() return 0 end,
                UUID = function() return 'abcdabcd-1234-5678-9abc-def012345678' end,
                GetDriverFileName = function() return 'driver.c4z' end,
                GetDevicesByC4iName = function()
                    return mode == 'agent present' and { [42] = {} } or {}
                end,
            }, nil, handlers)
            Driverforge:Init('drv_test')
            anvil._instrumentationDisabled = mode == 'instrumentation disabled'
            local sent = {}
            anvil.sendData = function(_, payload) sent[#sent + 1] = payload end
            if name ~= 'OnDriverLateInit' then OnDriverLateInit() end
            local function invoke(arg)
                if name == 'Anvil:OnDriverInit' then
                    return Anvil:OnDriverInit(handler, arg)
                end
                return _G[name](arg)
            end
            return invoke, sent
        end

        for _, mode in ipairs({ 'agent present', 'agent absent', 'instrumentation disabled' }) do
            -- Include generated and explicit wrappers that already preserve
            -- returns: the contract belongs to the public entry points.
            for _, name in ipairs({ 'OnPropertyChanged', 'OnDriverLateInit', 'Anvil:OnDriverInit',
                'ReceivedFromProxy', 'OnDriverAdded', 'ExecuteCommand' }) do
                it(name .. ' preserves return arity and identity with ' .. mode, function()
                    local object = {}
                    for _, values in ipairs({ pack(), pack(nil), pack(false),
                        pack(object), pack(nil, object, nil, false, 'tail', nil) }) do
                        local calls = 0
                        local function handler(arg)
                            assert.are.equal('driver-argument', arg)
                            calls = calls + 1
                            return unpack(values, 1, values.n)
                        end
                        local expected = pack(handler('driver-argument'))
                        local invoke = prepare(mode, name, handler)
                        local actual = pack(invoke('driver-argument'))
                        assert.are.equal(2, calls)
                        assert.are.equal(expected.n, actual.n)
                        for i = 1, expected.n do
                            assert.are.equal(expected[i], actual[i])
                        end
                    end
                end)
            end

            it('late-init reports ready after completion and preserves errors with ' .. mode, function()
                for _, failure in ipairs({ pack(nil), pack(false), pack({}), pack('driver error') }) do
                    local completed = false
                    local function handler()
                        completed = true
                        error(failure[1], 0)
                    end
                    local invoke, sent = prepare(mode, 'OnDriverLateInit', handler)
                    local ok, err = pcall(invoke)
                    assert.is_true(completed)
                    assert.is_false(ok)
                    assert.are.equal(failure[1], err)
                    if mode == 'agent present' then
                        assert.are.equal('lifecycle', sent[#sent].eventType)
                        assert.are.equal('ready', sent[#sent].payload.phase)
                    else
                        assert.are.equal(0, #sent)
                    end
                end
            end)
        end
    end)

    describe('ready lifecycle beacon', function()
        -- C4 stub that also resolves an agent device, so discoverAnvilAgent
        -- finds one (or not, when GetDevicesByC4iName returns empty).
        local function c4WithAgent(agentDevices)
            return {
                GetUniqueMAC = function() return 'AA:BB:CC' end,
                GetTime = function() return 0 end,
                UUID = function() return 'abcdabcd-1234-5678-9abc-def012345678' end,
                GetDriverConfigInfo = function(_, key)
                    if key == 'version' then return '3.1.4' end
                    return nil
                end,
                GetDevicesByC4iName = function() return agentDevices end,
                SendToDevice = function() end,
                -- The filename is no longer passed to Init; telemetry resolves
                -- it from the runtime when it builds a payload.
                GetDriverFileName = function() return 'd.c4z' end,
            }
        end

        local function lifecycleEvents(sent)
            local out = {}
            for _, p in ipairs(sent) do
                if p.eventType == 'lifecycle' then table.insert(out, p) end
            end
            return out
        end

        it('reports a late-init error once when called inside another instrumented handler', function()
            local thrown = {}
            local _, anvil = loadHarness(c4WithAgent({ [42] = {} }), nil, {
                OnDriverLateInit = function() error(thrown, 0) end,
            })
            Driverforge:Init('drv_x')
            local sent = {}
            anvil.sendData = function(_, envelope) sent[#sent + 1] = envelope end
            local ok, err = pcall(function()
                Anvil:OnDriverInit(function() OnDriverLateInit() end)
            end)
            assert.is_false(ok)
            assert.are.equal(thrown, err)
            local errors = 0
            for _, envelope in ipairs(sent) do
                if envelope.eventType == 'error' then errors = errors + 1 end
            end
            assert.are.equal(1, errors)
            assert.are.equal(1, #lifecycleEvents(sent))
        end)

        it('fires a ready beacon at the end of OnDriverLateInit when the agent is present', function()
            local Anvil, anvil = loadHarness(c4WithAgent({ [42] = {} }))
            Driverforge:Init('drv_x')

            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            OnDriverLateInit()

            local beacons = lifecycleEvents(sent)
            assert.are.equal(1, #beacons)
            assert.are.equal('ready', beacons[1].payload.phase)
            assert.are.equal('3.1.4', beacons[1].payload.driverVersion)
            assert.are.equal('d.c4z', beacons[1].payload.driver)
        end)

        it('still fires the ready beacon when late-init raises, then re-raises', function()
            clearAnvilModules()
            -- Defined before the harness loads, as in a real driver file.
            _G.OnDriverLateInit = function() error('init exploded') end
            _G.C4 = c4WithAgent({ [42] = {} })
            _G.Properties = { ['Anvil Debug Logging'] = 'Off' }
            require 'harness'
            _G.Driverforge:Init('drv_x')

            local anvil = package.loaded.client
            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            local ok, err = pcall(_G.OnDriverLateInit)

            -- The raise reaches the Director exactly as it would without
            -- the SDK...
            assert.is_false(ok)
            assert.is_truthy(tostring(err):match('init exploded'))
            -- ...but the beacon and the error envelope both went out first:
            -- "the driver is up, and its init threw".
            local beacons = lifecycleEvents(sent)
            assert.are.equal(1, #beacons)
            assert.are.equal('ready', beacons[1].payload.phase)
            local sawError = false
            for _, p in ipairs(sent) do
                if p.eventType == 'error' then sawError = true end
            end
            assert.is_true(sawError)
        end)

        it('does not fire a beacon when no agent is installed', function()
            local Anvil, anvil = loadHarness(c4WithAgent({}))  -- no agent devices
            Driverforge:Init('drv_x')

            local sent = {}
            anvil.sendData = function(_, payload) table.insert(sent, payload) end

            OnDriverLateInit()

            assert.are.equal(0, #lifecycleEvents(sent))
        end)
    end)

    describe('agent discovery target', function()
        local queried
        local function c4(devices)
            return {
                GetUniqueMAC = function() return 'AA' end,
                GetTime = function() return 0 end,
                UUID = function() return 'u' end,
                GetDriverConfigInfo = function() return '1.0' end,
                GetDevicesByC4iName = function(_, name) queried = name; return devices or { [1] = {} } end,
                SendToDevice = function() end,
            }
        end

        before_each(function() queried = nil end)

        it('discovers the default anvil-agent.c4z when no override is given', function()
            local Anvil, anvil = loadHarness(c4())
            Driverforge:Init('drv_x')
            anvil._hasLateInited = true
            anvil:discoverAnvilAgent()
            assert.are.equal('anvil-agent.c4z', queried)
        end)

        it('discovers opts.agentDriverName when set (e.g. a dev agent)', function()
            local Anvil, anvil = loadHarness(c4())
            Driverforge:Init('drv_x', { agentDriverName = 'anvil-agent-dev.c4z' })
            anvil._hasLateInited = true
            anvil:discoverAnvilAgent()
            assert.are.equal('anvil-agent-dev.c4z', queried)
        end)
    end)

    describe('OnDriverAdded agent rediscovery', function()
        -- A C4 stub whose agent "gets installed" mid-test: discovery finds
        -- nothing until installed() is called, then finds device 1001.
        local function lateAgentC4(sent)
            local installed = false
            return {
                GetUniqueMAC = function() return 'AA' end,
                GetTime = function() return 0 end,
                UUID = function() return 'abcdabcd-1234-5678-9abc-def012345678' end,
                GetDriverConfigInfo = function() return '1.0' end,
                GetDevicesByC4iName = function()
                    if installed then return { [1001] = 'anvil-agent.c4z' } end
                    return nil
                end,
                JsonEncode = function(_, value) return value end,
                SendToDevice = function(_, _, _, params) table.insert(sent, params) end,
            }, function() installed = true end
        end

        it('defines the OnDriverAdded global even when the driver does not', function()
            loadHarness()

            -- The Director only invokes handler globals that exist; without
            -- this one, the rediscovery special case in instrument() is
            -- unreachable for any driver that has no OnDriverAdded of its own.
            assert.is_function(_G.OnDriverAdded)
        end)

        it('defines ExecuteCommand so a verification proof can arrive even with no driver command handler', function()
            loadHarness()
            assert.is_function(_G.ExecuteCommand)
        end)

        it('intercepts the verification proof command and does NOT forward it to the driver handler', function()
            clearAnvilModules()
            local driverSaw = {}
            -- Driver defines its own ExecuteCommand before requiring the SDK.
            _G.ExecuteCommand = function(cmd, params) table.insert(driverSaw, cmd) end
            _G.C4 = {
                GetUniqueMAC = function() return 'AA' end,
                GetTime = function() return 0 end,
                UUID = function() return 'abcdabcd-1234-5678-9abc-def012345678' end,
                GetDriverConfigInfo = function() return '1.0' end,
            }
            _G.Properties = { ['Anvil Debug Logging'] = 'Off' }
            require 'harness'

            local anvil = package.loaded.client
            -- `_G.ExecuteCommand` is now the harness wrapper; capture it
            -- before anything else. The driver's own handler lives in
            -- EventHandlers — swap it for a count-only sentinel (xpcall on
            -- the vanilla-5.1 spec runner doesn't forward args, though the
            -- controller's LuaJIT does, so count the call, not the value).
            local wrapper = _G.ExecuteCommand
            local intercepted
            anvil.handleProtocolCommand = function(_, cmd)
                intercepted = cmd
                return cmd == 'AGENT_VERIFY_PROOF'
            end
            anvil.EventHandlers.ExecuteCommand = function() table.insert(driverSaw, true) end

            -- Protocol traffic: swallowed, driver never sees it.
            wrapper('AGENT_VERIFY_PROOF', { nonce = 'n' })
            assert.are.equal('AGENT_VERIFY_PROOF', intercepted)
            assert.are.equal(0, #driverSaw)

            -- A real command: delegated to the driver's handler.
            wrapper('TURN_ON', {})
            assert.are.equal(1, #driverSaw)
        end)

        it('leaves zero footprint on an agent-less controller: buffer discarded, sends dropped', function()
            local sent = {}
            local c4 = lateAgentC4(sent)  -- agent never installed
            local Anvil, anvil = loadHarness(c4)
            Driverforge:Init('drv_x')
            local Queue = require 'queue'

            -- Init window: discovery hasn't run, so envelopes buffer.
            anvil:sendData({ eventType = 'log', payload = 'before-late-init' })
            assert.are.equal(1, Queue.length(anvil._eventQueue))

            _G.OnDriverLateInit()  -- discovery comes up empty
            assert.is_false(anvil:isAgentInstalled())

            -- The init-window buffer is discarded (nothing would ever
            -- drain it), and post-late-init envelopes are dropped, not
            -- queued — zero steady-state memory on production controllers.
            assert.are.equal(0, Queue.length(anvil._eventQueue))
            anvil:sendData({ eventType = 'log', payload = 'dropped-no-agent' })
            assert.are.equal(0, Queue.length(anvil._eventQueue))
            assert.are.equal(0, #sent)
        end)

        it('discovers a late-installed agent on driver-added and delivers future events (no backfill)', function()
            local sent = {}
            local c4, installAgent = lateAgentC4(sent)
            local Anvil, anvil = loadHarness(c4)
            Driverforge:Init('drv_x')

            _G.OnDriverLateInit()  -- agent not installed yet
            assert.is_false(anvil:isAgentInstalled())

            -- Sent while agent-less: dropped by design.
            anvil:sendData({ eventType = 'log', payload = 'dropped-no-agent' })
            assert.are.equal(0, #sent)

            installAgent()
            _G.OnDriverAdded()     -- Director: a driver (the agent) was added

            assert.is_true(anvil:isAgentInstalled())
            assert.is_true(anvil:isAgentReady())

            -- Events from here on flow (alongside instrument()'s own
            -- OnDriverAdded envelope); the pre-install drop is permanent.
            anvil:sendData({ eventType = 'log', payload = 'after-agent' })

            local sawFuture = false
            for _, p in ipairs(sent) do
                assert.are_not.equal('dropped-no-agent', p.payload.payload)
                if p.payload.payload == 'after-agent' then sawFuture = true end
            end
            assert.is_true(sawFuture)
        end)

        it('warns once when a driver clobbers a harness-owned global after load', function()
            local Anvil = loadHarness()
            Driverforge:Init('drv_x')

            -- The load-order mistake: the driver defines its handler AFTER
            -- require'ing the SDK, replacing the harness's wrapper. The SDK
            -- can never late-init now; it should at least say so.
            _G.OnDriverLateInit = function() end

            local printed = {}
            local realPrint = _G.print
            _G.print = function(...)
                local parts = {}
                for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
                table.insert(printed, table.concat(parts, ' '))
            end
            -- Any harness-owned entry point triggers the one-shot check.
            _G.OnPropertyChanged('Some Property')
            _G.OnPropertyChanged('Some Property')
            _G.print = realPrint

            local warnings = 0
            for _, line in ipairs(printed) do
                if line:match('WARNING') and line:match('OnDriverLateInit') then
                    warnings = warnings + 1
                end
            end
            assert.are.equal(1, warnings)
        end)

        it('delegates to a driver-defined OnDriverAdded handler', function()
            clearAnvilModules()
            local called = false
            -- Defined before the harness loads, as in a real driver file —
            -- so it must be set AFTER clearing but before require. loadHarness
            -- would clear it, so load the harness by hand here.
            _G.OnDriverAdded = function() called = true end

            local sent = {}
            local c4, installAgent = lateAgentC4(sent)
            installAgent()  -- agent present from the start
            _G.C4 = c4
            _G.Properties = { ['Anvil Debug Logging'] = 'Off' }
            require 'harness'

            _G.Driverforge:Init('drv_x')
            _G.OnDriverLateInit()

            _G.OnDriverAdded()

            assert.is_true(called)
        end)
    end)

    describe('runtime floor', function()
        -- A controller below the SDK's floor: no C4:UUID. Everything else the
        -- SDK touches has been present for far longer, so this one capability
        -- is what separates a runtime the SDK can work on from one it can't.
        local function belowFloorC4()
            return {
                GetUniqueMAC = function() return 'AA:BB:CC' end,
                GetTime = function() return 0 end,
                GetDriverConfigInfo = function(_, key)
                    if key == 'version' then return '0.9.9' end
                    return nil
                end,
                GetDevicesByC4iName = function() return {} end,
            }
        end

        -- The probe announces itself once at load. Silence it so the suite's
        -- output stays readable, but keep it a real print in production.
        local function quietly(fn)
            local realPrint = _G.print
            _G.print = function() end
            local ok, err = pcall(fn)
            _G.print = realPrint
            if not ok then error(err, 0) end
        end

        local function loadBelowFloor()
            local Anvil, anvil
            quietly(function() Anvil, anvil = loadHarness(belowFloorC4()) end)
            return Anvil, anvil
        end

        it('switches the SDK off at load when a required capability is absent', function()
            local _, anvil = loadBelowFloor()

            assert.are.equal('UUID', anvil._unsupportedRuntime)
            -- Reuses the same short-circuit a failed boundary self-test sets,
            -- whose pass-through parity is covered in anvil_spec.
            assert.is_true(anvil._instrumentationDisabled)
        end)

        it('says so through TelemetryStatus rather than going quietly dark', function()
            local Anvil = loadBelowFloor()
            Driverforge:Init('drv_x')

            local status = Anvil:TelemetryStatus()

            assert.are.equal('unsupported-runtime', status.state)
            assert.is_false(status.enabled)
            -- The reason names the OS version and not the missing API: a
            -- driver author can act on a version, and which C4 call we needed
            -- is our implementation detail.
            assert.is_truthy(status.reason:find('3.3.1', 1, true))
            assert.is_nil(status.reason:find('UUID', 1, true))
        end)

        it('captures nothing and queues nothing, through to late-init', function()
            local Anvil, anvil = loadBelowFloor()
            local Queue = require 'queue'
            Driverforge:Init('drv_x')

            -- The init window is where an unguarded C4:UUID would have been
            -- reached: instrument() only short-circuits on agent absence once
            -- late-init has run, so before that it takes the capture path.
            anvil:instrument('OnPropertyChanged', function() end, 'Volume')
            assert.are.equal(0, Queue.length(anvil._eventQueue))

            -- Late-init must not throw either: discovery is skipped entirely,
            -- so the driver takes the same path as on an agent-less controller.
            assert.has_no.errors(function() _G.OnDriverLateInit() end)
            assert.is_false(anvil:isAgentInstalled())
            assert.are.equal(0, Queue.length(anvil._eventQueue))
        end)

        it("still forwards the driver's own handler and its return value", function()
            clearAnvilModules()
            local seen
            -- Defined before the harness loads, as in a real driver file.
            _G.OnDriverAdded = function(id) seen = id; return 'ret:' .. id end
            _G.C4 = belowFloorC4()
            _G.Properties = { ['Anvil Debug Logging'] = 'Off' }
            quietly(function() require 'harness' end)

            local r = _G.OnDriverAdded('device-7')

            assert.are.equal('device-7', seen)
            assert.are.equal('ret:device-7', r)
        end)

        it('leaves a supported runtime alone', function()
            local Anvil, anvil = loadHarness()   -- default C4 has UUID

            assert.is_nil(anvil._unsupportedRuntime)
            assert.is_falsy(anvil._instrumentationDisabled)
            assert.are_not.equal('unsupported-runtime', Anvil:TelemetryStatus().state)
        end)
    end)
end)
