local Queue = require "queue"
local Diagnostics = require "diagnostics"
local LogArgs = require "log_args"
local AgentVerify = require "agent_verify"

-- The C4 runtime is LuaJIT without 5.2 compat: table.unpack does not exist
-- there, only the 5.1 global unpack does. (Test runners often alias the two,
-- so a bare table.unpack passes CI and crashes on the controller.)
local unpack = table.unpack or unpack

-- table.pack is likewise 5.2-only. Recording the true value count means an
-- embedded nil survives a pack/unpack round-trip instead of truncating it.
local function pack(...)
    return { n = select('#', ...), ... }
end

-- Error transport requires a string, but inspecting an arbitrary error must
-- never execute its __tostring metamethod. Runtime rethrows keep the original.
local function errorText(value)
    local kind = type(value)
    if kind == "string" then return value end
    if kind == "nil" or kind == "boolean" or kind == "number" then return tostring(value) end
    return kind
end

local function failedTrace()
    return { schemaVersion = 1, captureKind = "exception", status = "failed", reasons = { "capture_failed" } }
end

-- Keep the original error visible to every caller, including driver-owned
-- pcall/xpcall. A dedicated live frame identifies our rethrow to an enclosing
-- collector without tagging the error or remembering values between throws.
local function rethrow(original)
    error(original, 0)
end

local function isSdkRethrow(boundary)
    -- Only the first Lua frame below this error handler can be the throw site.
    -- Searching the whole stack would mistake a new error in a driver's error
    -- handler for the older SDK rethrow still live underneath it.
    local ok, reported = pcall(function()
        local pastBoundary = false
        -- The boundary is near the top; cap even a broken metadata provider.
        for level = 2, 16 do
            local info = debug.getinfo(level, "fS")
            if not info then return false end
            if pastBoundary and info.what ~= "C" then
                return info.func == rethrow
            end
            if info.func == boundary then pastBoundary = true end
        end
        return false
    end)
    -- Missing/broken debug metadata may duplicate a report, but must never
    -- replace the driver's error or suppress collection based on a guess.
    return ok and reported
end

-- The runtime floor, expressed as capabilities rather than a version number.
--
-- A driver carries this SDK wherever it goes, including onto controllers old
-- enough to lack an API the SDK depends on. Lua resolves a call site only when
-- it executes and there is no build step to warn us, so a floor is a property
-- of which lines run unconditionally — and everything named here runs whether
-- or not an agent is ever installed. Absence must therefore switch the SDK OFF
-- rather than let it throw from inside its own capture path, in a driver that
-- gets nothing in return for the failure.
--
-- Version numbers are deliberately not consulted: Director exposes no version
-- gate a driver can declare, and a parsed version string cannot tell you about
-- a backport. Asking the runtime what it has is both cheaper and exact.
local REQUIRED_C4_CAPABILITIES = {
    -- Mints the trace, span and error ids attached to every captured event,
    -- including during the pre-late-init window before agent discovery has
    -- run. There is no fallback: an id good enough to correlate telemetry is
    -- the only thing this is for, and telemetry cannot be delivered on a
    -- runtime this old anyway.
    "UUID",
}

-- Field-existence tests only — no call, no cost, no side effect — so this is
-- safe to run at module load, which is early enough that no instrumented
-- handler can fire first. Reading a field off C4 rather than calling it is the
-- same test the harness already makes before touching GetDriverConfigInfo, so
-- it is a shipped, hardware-proven shape and not a new assumption. The read
-- still goes through pcall: C4 is protected userdata on a controller and a
-- plain table under test, and a capability we cannot even probe is one we must
-- treat as absent.
local function missingC4Capabilities()
    local missing = {}
    for _, name in ipairs(REQUIRED_C4_CAPABILITIES) do
        local ok, value = pcall(function() return C4 and C4[name] end)
        if (not ok) or value == nil then
            missing[#missing + 1] = name
        end
    end
    return missing
end

local _M = (function()
    local anvil = {
        EventHandlers = {
            GetPrivateKeyPassword = GetPrivateKeyPassword,
            OnConnectionStatusChanged = OnConnectionStatusChanged,
            OnDataFromUI = OnDataFromUI,
            OnDriverDestroyed = OnDriverDestroyed,
            OnDriverInit = OnDriverInit,
            OnDriverLateInit = OnDriverLateInit,
            OnDriverUpdate = OnDriverUpdate,
            OnTimerExpired = OnTimerExpired,
            OnNetworkBindingChanged = OnNetworkBindingChanged,
            OnPropertyChanged = OnPropertyChanged,
            OnReflashLockGranted = OnReflashLockGranted,
            OnReflashLockRevoked = OnReflashLockRevoked,
            OnBindingChanged = OnBindingChanged,
            OnServerConnectionStatusChanged = OnServerConnectionStatusChanged,
            OnServerStatusChanged = OnServerStatusChanged,
            OnServerDataIn = OnServerDataIn,
            OnSystemEvent = OnSystemEvent,
            OnVariableChanged = OnVariableChanged,
            OnDeviceEvent = OnDeviceEvent,
            OnEventFired = OnEventFired,
            OnWatchedVariableChanged = OnWatchedVariableChanged,
            ExecuteCommand = ExecuteCommand,
            ExecuteAction = ExecuteAction,
            ReceivedFromProxy = ReceivedFromProxy,
            ReceivedFromNetwork = ReceivedFromNetwork,
            ReceivedFromSerial = ReceivedFromSerial,
            ReceivedAsync = ReceivedAsync,
            UIRequest = UIRequest,
            ListMIBReceived = ListMIBReceived,
            ListNewControl = ListNewControl,
            ListEvent = ListEvent,
            ListNewList = ListNewList,
            GetNotificationAttachmentURL = GetNotificationAttachmentURL,
            GetNotificationAttachmentFile = GetNotificationAttachmentFile,
            GetNotificationAttachmentBytes = GetNotificationAttachmentBytes,
            FinishedWithNotificationAttachment = FinishedWithNotificationAttachment,
            OnProjectLocked = OnProjectLocked,
            OnLocaleChanged = OnLocaleChanged,
            OnProjectPropertyChanged = OnProjectPropertyChanged,
            OnZigbeeNodeOffline = OnZigbeeNodeOffline,
            OnProjectLoading = OnProjectLoading,
            OnLatitudeChanged = OnLatitudeChanged,
            OnCodeItemRemoved = OnCodeItemRemoved,
            OnPhysicalDeviceAdded = OnPhysicalDeviceAdded,
            OnVariableRemoved = OnVariableRemoved,
            OnSystemUpdateStarted = OnSystemUpdateStarted,
            OnVariableBindingRemoved = OnVariableBindingRemoved,
            OnSDDPDeviceStatus = OnSDDPDeviceStatus,
            OnDeviceUserInitiatedRemove = OnDeviceUserInitiatedRemove,
            OnTimezoneChanged = OnTimezoneChanged,
            OnProjectClear = OnProjectClear,
            OnSongAddedToPlaylist = OnSongAddedToPlaylist,
            OnItemDataChanged = OnItemDataChanged,
            OnMediaSessionVolumeLevelChanged = OnMediaSessionVolumeLevelChanged,
            OnAuthorizedConnectionDisconnected = OnAuthorizedConnectionDisconnected,
            OnZigbeeDuplicateMesh = OnZigbeeDuplicateMesh,
            OnZigbeeNetworkHealth = OnZigbeeNetworkHealth,
            OnMediaSessionMediaInfoChanged = OnMediaSessionMediaInfoChanged,
            OnEventModified = OnEventModified,
            OnTimeChanged = OnTimeChanged,
            OnCodeItemCommandUpdated = OnCodeItemCommandUpdated,
            OnItemAdded = OnItemAdded,
            OnSongRemovedFromPlaylist = OnSongRemovedFromPlaylist,
            OnItemMoved = OnItemMoved,
            OnEventAdded = OnEventAdded,
            OnSystemShutDown = OnSystemShutDown,
            OnProjectLoaded = OnProjectLoaded,
            OnDataToUI = OnDataToUI,
            OnMediaSessionAdded = OnMediaSessionAdded,
            OnZigbeeNodesChanged = OnZigbeeNodesChanged,
            OnDiscoveredDeviceChanged = OnDiscoveredDeviceChanged,
            OnCodeItemAddedToExpression = OnCodeItemAddedToExpression,
            OnBindingEntryAdded = OnBindingEntryAdded,
            OnScheduledEvent = OnScheduledEvent,
            OnMediaDataRemoved = OnMediaDataRemoved,
            OnVariableAdded = OnVariableAdded,
            OnEventRemoved = OnEventRemoved,
            OnControllerDisabled = OnControllerDisabled,
            OnMediaSessionMuteStateChanged = OnMediaSessionMuteStateChanged,
            OnMediaDeviceChanged = OnMediaDeviceChanged,
            OnDeviceOnline = OnDeviceOnline,
            OnMediaSessionDiscreteMuteChanged = OnMediaSessionDiscreteMuteChanged,
            OnVariableRemovedFromBinding = OnVariableRemovedFromBinding,
            OnZigbeeNodeUpdateSucceeded = OnZigbeeNodeUpdateSucceeded,
            OnZigbeeMeshChanged = OnZigbeeMeshChanged,
            OnItemNameChanged = OnItemNameChanged,
            OnCodeItemEnabled = OnCodeItemEnabled,
            OnZigbeeZserverChanged = OnZigbeeZserverChanged,
            OnZigbeeZapsChanged = OnZigbeeZapsChanged,
            OnBindingEntryRenamed = OnBindingEntryRenamed,
            OnBindingEntryRemoved = OnBindingEntryRemoved,
            OnBindingAdded = OnBindingAdded,
            OnPhysicalDeviceRemoved = OnPhysicalDeviceRemoved,
            OnNetworkBindingAdded = OnNetworkBindingAdded,
            OnDeviceAlreadyIdentified = OnDeviceAlreadyIdentified,
            OnDeviceIPAddressChanged = OnDeviceIPAddressChanged,
            OnDeviceIdentifying = OnDeviceIdentifying,
            OnVariableBindingAdded = OnVariableBindingAdded,
            OnNetworkBindingUnregistered = OnNetworkBindingUnregistered,
            OnDiscoveredDeviceRemoved = OnDiscoveredDeviceRemoved,
            OnDeviceCancelIdentify = OnDeviceCancelIdentify,
            OnDiscoveredDeviceAdded = OnDiscoveredDeviceAdded,
            OnDriverAdded = OnDriverAdded,
            OnMediaSessionChanged = OnMediaSessionChanged,
            OnDriverDisabled = OnDriverDisabled,
            OnSDDPDeviceDiscover = OnSDDPDeviceDiscover,
            OnCIDRRulesChanged = OnCIDRRulesChanged,
            OnDirectorIPAddressChanged = OnDirectorIPAddressChanged,
            OnAccountInfoUpdating = OnAccountInfoUpdating,
            OnDevicePreIdentify = OnDevicePreIdentify,
            OnZigBeeStickPresent = OnZigBeeStickPresent,
            OnDeviceIdentified = OnDeviceIdentified,
            OnProjectNew = OnProjectNew,
            OnMediaDeviceRemoved = OnMediaDeviceRemoved,
            OnConnectionAuthorized = OnConnectionAuthorized,
            OnNetworkBindingRemoved = OnNetworkBindingRemoved,
            OnMediaSessionSliderTargetVolumeReached = OnMediaSessionSliderTargetVolumeReached,
            OnPIP = OnPIP,
            OnMediaSessionRemoved = OnMediaSessionRemoved,
            OnVariableBindingRenamed = OnVariableBindingRenamed,
            OnUserVariableAdded = OnUserVariableAdded,
            OnAccountInfoUpdated = OnAccountInfoUpdated,
            OnDeviceOffline = OnDeviceOffline,
            OnZigbeeNodeOnline = OnZigbeeNodeOnline,
            OnVariableRenamed = OnVariableRenamed,
            OnZigBeeStickRemoved = OnZigBeeStickRemoved,
            OnSystemUpdateFinished = OnSystemUpdateFinished,
            OnZigbeeNodeUpdateStatus = OnZigbeeNodeUpdateStatus,
            OnDeviceIdentifiedNoLicense = OnDeviceIdentifiedNoLicense,
            OnProjectEnterLock = OnProjectEnterLock,
            OnNetworkBindingAddressChanged = OnNetworkBindingAddressChanged,
            OnProjectLeaveLock = OnProjectLeaveLock,
            OnMediaInfoModified = OnMediaInfoModified,
            OnMediaDeviceAdded = OnMediaDeviceAdded,
            OnNetworkBindingStatusChanged = OnNetworkBindingStatusChanged,
            OnMediaSessionVolumeSliderStateChanged = OnMediaSessionVolumeSliderStateChanged,
            OnSearchTypeFound = OnSearchTypeFound,
            OnMediaRemovedFromDevice = OnMediaRemovedFromDevice,
            OnMediaSessionDiscreteVolumeChanged = OnMediaSessionDiscreteVolumeChanged,
            OnAlive = OnAlive,
            OnProjectChanged = OnProjectChanged,
            OnLongitudeChanged = OnLongitudeChanged,
            OnNetworkBindingRegistered = OnNetworkBindingRegistered,
            OnItemRemoved = OnItemRemoved,
            OnDeviceFirmwareChanged = OnDeviceFirmwareChanged,
            OnCodeItemAdded = OnCodeItemAdded,
            OnBindingRemoved = OnBindingRemoved,
            OnCodeItemMoved = OnCodeItemMoved,
            OnZigbeeNodeUpdateFailed = OnZigbeeNodeUpdateFailed,
            OnMediaInfoAdded = OnMediaInfoAdded,
            OnZipcodeChanged = OnZipcodeChanged,
            OnVariableAddedToBinding = OnVariableAddedToBinding,
            OnAll = OnAll,
            OnDeviceDataChanged = OnDeviceDataChanged,
            OnAccessModeChanged = OnAccessModeChanged,
            OnDeviceDiscovered = OnDeviceDiscovered,
            OnSysmanResponse = OnSysmanResponse,
        },

        SEND_DATA_COMMAND = "DRIVER_DATA",
        AGENT_DRIVER_FILENAME = "anvil-agent.c4z",
        _token = nil,
        -- Resolved on first use by driverFileName(), never at Init.
        _driverFileName = nil,
        _driverVersion = "unknown",
        -- SDK version, set from src/version.lua via harness.lua at Init.
        -- Sent on every envelope so the agent (and ingestion) can track
        -- which SDK versions are running on the deployed fleet.
        _sdkVersion = "unknown",
        _clientOptions = nil,
        -- Override for which agent device to discover, from Driverforge:Init opts
        -- (opts.agentDriverName). Lets a driver built for a dev/staging agent
        -- target e.g. "anvil-agent-dev.c4z" via its own env config. nil →
        -- the AGENT_DRIVER_FILENAME default. SDK-internal: never sent to the
        -- agent, and only ever selects this driver's OWN send target.
        _agentDriverName = nil,
        _eventLastLogs = {},
        _eventStacktraces = {},
        _errorMessages = {},
        _agentReady = false,
        _eventQueue = Queue.new(),
        -- Upper bound on envelopes buffered before the agent is ready.
        -- The queue drains only when start() runs; if that never happens
        -- (agent never installed, or the late-init global was clobbered)
        -- an unbounded buffer becomes a slow memory leak on the controller.
        MAX_QUEUED_EVENTS = 500,
        _currentTraceId = nil,
        _currentSpanId = nil,
        _currentEventName = nil,
        _hasLateInited = false,
        _debugEnabled = false,
        -- The controller OS this SDK needs, for the one message a driver author
        -- will actually read. 3.3.1 rather than the 3.3.0 that REQUIRED_C4_
        -- CAPABILITIES literally implies: telemetry only goes anywhere with the
        -- agent installed, and the agent needs 3.3.1, so quoting a lower number
        -- would send someone chasing a configuration that cannot work.
        MINIMUM_OS = "3.3.1",
        -- Set at load when the runtime is below the SDK's floor: a
        -- comma-separated list of the C4 capabilities it lacks. Non-nil means
        -- the SDK has switched itself off — every handler forwards raw, nothing
        -- is captured, nothing is queued, nothing is retained.
        _unsupportedRuntime = nil,
    }

    function anvil:debug(...)
        if self._debugEnabled then
            -- select('#', ...), not #{...}: an embedded nil argument must
            -- not truncate the message.
            local parts = {}
            for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
            print(table.concat(parts))
        end
    end

    function anvil:initDebugCache()
        self._debugEnabled = (Properties["Anvil Debug Logging"] == "On")
    end

    function anvil:refreshDebugCache(propertyName)
        if propertyName == "Anvil Debug Logging" then
            self._debugEnabled = (Properties["Anvil Debug Logging"] == "On")
        end
    end

    -- Run a block of SDK-internal work (telemetry, serialization, queueing)
    -- isolated from the driver. A throw inside fn is, by construction, an
    -- SDK-origin fault: it is swallowed and routed to the SDK fault sink, and
    -- can never surface to the driver or the Director. Attribution is
    -- structural — an error caught here is definitionally the SDK's, so there
    -- is no stack-parsing "whose fault?" guess. Returns whether fn succeeded.
    function anvil:runSdkWork(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            self:reportSdkFault(label, err)
        end
        return ok
    end

    -- Report an SDK-internal fault. This runs only when the SDK is already
    -- malfunctioning, so it must be maximally defensive: it guards its own
    -- body in pcall and refuses to re-enter (a fault raised while reporting a
    -- fault degrades to nothing rather than looping). For now it leaves a
    -- local breadcrumb via the controller error log; routing SDK faults to
    -- the SDK team's own Anvil project (tagged origin=sdk, via the agent) is a
    -- later change — this is the seam it will hook.
    function anvil:reportSdkFault(label, err)
        if self._inSdkFaultReport then return end
        self._inSdkFaultReport = true
        -- Local breadcrumb: the guaranteed floor, even if the agent path is the
        -- thing malfunctioning. Always left.
        pcall(function()
            local msg = "Anvil SDK internal fault [" .. tostring(label) .. "]: " .. tostring(err)
            if C4 and C4.ErrorLog then C4:ErrorLog(msg) else print(msg) end
        end)
        -- Best-effort: forward to the agent tagged origin=sdk so the fault
        -- reaches the SDK team's Anvil project (the agent routes by origin),
        -- never the customer's error stream. Guarded — a failure here degrades
        -- to the breadcrumb above — and the _inSdkFaultReport guard means a
        -- fault raised WHILE reporting can't trigger another report.
        pcall(function() self:sendSdkFault(label, err) end)
        self._inSdkFaultReport = false
    end

    -- Forward an SDK-internal fault to the agent as an origin=sdk envelope. Sent
    -- down the ordinary DriverData channel (no new peer-callable action); the
    -- agent branches on origin and publishes it to the SDK team's project. No
    -- queueing: faults are not backfilled, and the local breadcrumb already
    -- holds the record if the agent isn't ready.
    function anvil:sendSdkFault(label, err)
        if not self:isAgentReady() then return end
        local envelope = self:generatePayload("error", {
            origin = "sdk",
            eventName = tostring(label),
            errorMessage = tostring(err),
            sdkVersion = self._sdkVersion,
        })
        -- Top-level marker the agent reads before touching the payload.
        envelope["origin"] = "sdk"
        C4:SendToDevice(self.AGENT_DEVICE_ID, self.SEND_DATA_COMMAND,
            { payload = C4:JsonEncode(envelope) }, false, false)
    end

    -- Init-time boundary self-test — the highest-leverage guard. Before any
    -- real handler runs, push a sentinel argument, return value and error
    -- through the REAL instrument() path and assert round-trip fidelity across
    -- the driver-observable channels (args in, returns out, error out). If the
    -- boundary does not preserve them on this runtime — a future regression, or
    -- an unexpected Lua flavour — DISABLE instrumentation and fail open (drivers
    -- run raw) with a single SDK diagnostic, rather than let the SDK corrupt or
    -- crash a driver. On a Lua-5.1 runtime this check turns the whole Issue-1
    -- arg-drop into a one-line warning instead of a load-time crash.
    --
    -- Attribution here is at the boundary, before the driver runs — so it
    -- catches faults that would otherwise detonate inside driver code and read
    -- as the customer's bug. Telemetry is silenced for the probe: this tests
    -- the forward contract, not the reporting path (whose faults 3.1 contains).
    function anvil:runBoundarySelfTest()
        -- Below the floor there is no instrumentation left to self-test: the
        -- probe already disabled it, so the forward path under test is the raw
        -- pass-through and reporting a "failure" would be noise.
        if self._unsupportedRuntime then return true end

        local ARG, RET = {}, {}            -- unique identities: == only if truly round-tripped
        local BOOM = "anvil-selftest-boom-" .. tostring(RET)

        local realSend, realTb = self.sendData, self.traceback
        self.sendData = function() end
        self.traceback = function() end

        local passed = false
        pcall(function()
            local gotArg
            local r1, r2 = self:instrument("__anvilSelfTest", function(a, b)
                gotArg = a
                return RET, b
            end, ARG, 7)
            local forwardOk = (gotArg == ARG) and (r1 == RET) and (r2 == 7)

            local threwOk, err = pcall(function()
                self:instrument("__anvilSelfTest", function() error(BOOM) end)
            end)
            local errorOk = (not threwOk) and type(err) == "string" and err:find(BOOM, 1, true) ~= nil

            passed = forwardOk and errorOk
        end)

        self.sendData, self.traceback = realSend, realTb

        if not passed then
            self._instrumentationDisabled = true
            self:reportSdkFault("boundary-self-test",
                "instrumentation self-test failed: a driver-observable channel "
                .. "was not preserved; running uninstrumented")
        end
        return passed
    end

    function anvil:traceback(traceId, errorMessage, stackTrace)
        self._eventStacktraces[traceId] = stackTrace
        self._errorMessages[traceId] = errorText(errorMessage)
    end

    -- W3C-shaped hex id from a random UUID: strip hyphens, lowercase,
    -- take the leading bytes. 16 bytes → traceId, 8 bytes → spanId.
    local function randomHex(byteCount)
        local hex = (C4:UUID("RANDOM"):gsub("-", "")):lower()
        return hex:sub(1, byteCount * 2)
    end

    -- Default mapping of canonical log levels to method names on a logger
    local DEFAULT_LOG_MAP = {
        fatal = "fatal",
        error = "error",
        warn = "warn",
        info = "info",
        debug = "debug",
        trace = "trace",
    }

    -- Resolve which method name on the caller's logger corresponds to
    -- a given canonical level. Priority order:
    --   1. Explicit `logMap[canonicalLevel]` — wins (semantic override
    --      path, e.g. mapping `fatal` to a method named `Alert`)
    --   2. Canonical lowercase — `info`
    --   3. PascalCase — `Info`
    --   4. UPPERCASE — `INFO`
    --
    -- Drivers using c4_log (Snap One's standard, PascalCase) or any
    -- other reasonable case convention work with `logMap = nil`.
    -- Drivers only need to supply a `logMap` entry for genuinely
    -- *renamed* methods, not for case-only differences.
    --
    -- If a logger has multiple variants for the same level (`info`
    -- AND `Info`), priority-order picks the first; we don't wrap all
    -- variants because of the delegation footgun (if `Info` calls
    -- `self:info` internally and we wrap both, every call would
    -- forward twice). The ambiguity is surfaced via anvil:debug so a
    -- developer with debug logging on can spot it.
    local function resolveMethodName(logger, canonicalLevel, logMap)
        if logMap and logMap[canonicalLevel] then
            return logMap[canonicalLevel], { logMap[canonicalLevel] }
        end

        local variants = {
            canonicalLevel,
            canonicalLevel:sub(1, 1):upper() .. canonicalLevel:sub(2),
            canonicalLevel:upper(),
        }

        local found
        local allFound = {}
        for _, name in ipairs(variants) do
            if type(logger[name]) == "function" then
                if not found then found = name end
                table.insert(allFound, name)
            end
        end
        return found, allFound
    end

    -- Wrap the caller's logger so existing call sites in the driver
    -- (Log:Info, Log:Error, etc.) auto-forward to Anvil without any
    -- code change at the call site.
    --
    -- The driver passes its own logger into Driverforge:Init via opts.logger.
    -- Earlier versions created a *new* proxy table and stored it on
    -- Anvil.logger; nothing read that field, so the proxy was dead and
    -- the driver had to manually call Anvil:ForwardLog from inside its
    -- own log methods to get anything into Anvil.
    --
    -- This function instead mutates the caller's logger table in place:
    -- each method named in the (default + caller-supplied) logMap is
    -- replaced with a wrapper that forwards to Anvil first, then
    -- delegates to the original. Idempotent — guarded against
    -- double-wrap on a re-Init via the _anvilWrapped flag.
    --
    -- Note: this does mutate a table the caller owns. The contract is
    -- documented; in practice the driver's logger is a singleton that
    -- already exists to be poked at, so the surprise factor is low.
    function anvil:installLoggerProxy(logger, logMap)
        if logger._anvilWrapped then
            return
        end

        for canonicalLevel, _ in pairs(DEFAULT_LOG_MAP) do
            local methodName, allFound = resolveMethodName(logger, canonicalLevel, logMap)
            if methodName then
                if #allFound > 1 then
                    self:debug(
                        "Multiple method variants for level '" .. canonicalLevel ..
                        "': " .. table.concat(allFound, ", ") ..
                        ". Wrapping '" .. methodName ..
                        "'. Set logMap." .. canonicalLevel ..
                        " to override."
                    )
                end

                local original = logger[methodName]
                local levelName = string.upper(canonicalLevel)
                logger[methodName] = function(self, ...)
                    -- Support both call styles: colon (`Log:Info("x")`,
                    -- self == the logger) and dot (`Log.Info("x")`, where
                    -- what lands in `self` is really the first message
                    -- argument). Only the FORWARDED arguments depend on the
                    -- distinction — the delegation to the original method
                    -- passes every argument through verbatim either way, so
                    -- the driver's own logging behaviour is untouched.
                    if self == logger then
                        anvil:forwardLogArgs(levelName, pack(...))
                    else
                        anvil:forwardLogArgs(levelName, pack(self, ...))
                    end
                    return original(self, ...)
                end
            end
        end

        logger._anvilWrapped = true
    end

    -- Cache for parameter names to avoid repeated source parsing
    local _parameterCache = {}

    -- Extract parameter names from a function's source definition
    -- Returns: array of parameter names, or nil if unable to determine
    local function getFunctionParameters(func)
        -- Check cache first
        if _parameterCache[func] ~= nil then
            return _parameterCache[func] or nil
        end

        local info = debug.getinfo(func, "Su")

        -- C functions don't have extractable parameter names
        if info.what == "C" then
            _parameterCache[func] = false
            return nil
        end

        -- Try debug.getlocal with a function value — a LuaJIT/5.2 capability.
        -- On a runtime without it the call RAISES, and this runs before the
        -- handler's xpcall, so an unguarded probe would turn instrumentation
        -- itself into the crash. Degrade to positional args instead.
        local params = {}
        local i = 1
        while true do
            local ok, name = pcall(debug.getlocal, func, i)
            if not ok or not name then break end
            if name:sub(1, 1) == "(" then break end  -- Stop at varargs/internals
            params[i] = name
            i = i + 1
        end

        if #params > 0 then
            _parameterCache[func] = params
            return params
        end

        _parameterCache[func] = false
        return nil
    end

    -- Build a table mapping parameter names to argument values
    -- Falls back to numeric indices if names unavailable
    local function buildNamedArgs(func, args)
        local paramNames = getFunctionParameters(func)

        if not paramNames then
            return args  -- Return numeric-indexed as-is
        end

        local namedArgs = {}
        local argCount = #args

        -- Map named parameters
        for i, name in ipairs(paramNames) do
            if i <= argCount then
                namedArgs[name] = args[i]
            end
        end

        -- Handle extra arguments (varargs) with numeric indices
        for i = #paramNames + 1, argCount do
            namedArgs[i] = args[i]
        end

        return namedArgs
    end

    -- Handlers whose arguments and return values must never appear in telemetry
    local SensitiveHandlers = {
        GetPrivateKeyPassword = true,
    }

    -- The harness registers the handler globals it owns right after defining
    -- them, so the first instrumented call can detect a driver that defined
    -- its handlers AFTER require'ing the SDK (replacing a harness wrapper).
    function anvil:registerOwnedGlobals(globals)
        self._ownedGlobals = globals
    end

    -- Keep displaced driver handlers and SDK boundaries distinguishable.
    function anvil:nameHandlerFrames(globals)
        for name, original in pairs(self.EventHandlers) do
            Diagnostics.registerFunction(original, { functionName = name, role = "driver" })
            local wrapper = globals[name]
            if wrapper and wrapper ~= original then
                Diagnostics.registerFunction(wrapper, { functionName = name, role = "sdk" })
            end
        end
    end

    -- One-shot: by the first instrumented call the driver chunk has fully
    -- executed, so any clobbering of a harness-owned global has happened.
    -- The failure this catches is otherwise silent — a replaced
    -- OnDriverLateInit means the SDK never initialises and telemetry just
    -- queues until the cap discards it.
    function anvil:warnIfHandlerGlobalsClobbered()
        if self._clobberChecked then return end
        self._clobberChecked = true
        if not self._ownedGlobals then return end
        for name, harnessFn in pairs(self._ownedGlobals) do
            if _G[name] ~= harnessFn then
                print("Anvil: WARNING - _G." .. name .. " was redefined after the Anvil SDK was required."
                    .. " Define all C4 handlers BEFORE requiring the SDK;"
                    .. " with this global replaced, Anvil telemetry cannot start.")
            end
        end
    end

    function anvil:instrument(name, func, ...)
        -- Fail-open: the init boundary self-test found instrumentation unsafe
        -- on this runtime, so forward the call raw and emit nothing. A direct
        -- call preserves args/returns/errors exactly, so the driver runs as if
        -- the SDK were absent. See runBoundarySelfTest.
        if self._instrumentationDisabled then
            if func ~= nil then return func(...) end
            return
        end

        self:warnIfHandlerGlobalsClobbered()

        local isImplemented = func ~= nil
        local isSensitive = SensitiveHandlers[name]

        -- if the agent isn't installed just call the function and don't do
        -- any instrumentation
        if self._hasLateInited and not self:isAgentInstalled() then
            -- Re-discover agent when a driver is added (handles agent installed after driver)
            if name == "OnDriverAdded" then
                self:discoverAnvilAgent()
                if self:isAgentInstalled() then
                    self:verifyAndStart()
                end
            end
            if not self:isAgentInstalled() then
                if isImplemented then return func(...) end
                return
            end
        end

        -- Each C4 entry-point invocation is a trace root. traceId
        -- is the event's correlation key (1:1); spanId is its root span.
        local traceId = randomHex(16)
        local spanId = randomHex(8)

        self:debug(name, " being wrapped by Anvil collector (Trace ID: ", traceId, ")")

        if not isImplemented then
            -- Unimplemented method: send event with zero duration, no execution
            local now = C4:GetTime()
            local rawArgs = { ... }
            local payloadArgs = isSensitive and "[REDACTED]" or rawArgs
            self:sendData(self:generateEventPayload(traceId, spanId, name, payloadArgs, now, now, 0, true, nil, nil, nil, nil, false))
            return
        end

        -- Nested handlers own their logs while running, then restore the
        -- enclosing event so its remaining logs keep their original owner.
        local parentTraceId, parentSpanId, parentEventName =
            self._currentTraceId, self._currentSpanId, self._currentEventName
        self._currentTraceId = traceId
        self._currentSpanId = spanId
        self._currentEventName = name

        -- Capture the handler's args arity- and nil-exact for the call below.
        -- The call unpacks them explicitly rather than relying on xpcall
        -- forwarding trailing args to func: that is a Lua 5.2 feature the C4
        -- LuaJIT runtime does NOT have, so `xpcall(func, msgh, ...)` there
        -- silently invokes func with zero args — dropping e.g. sProperty and
        -- crashing a handler that was actually given its argument. Only bites
        -- calls made *before* late-init: the agent-not-installed short-circuit
        -- above forwards via a direct `func(...)`, so the gap stayed hidden
        -- until an instrumented handler ran during OnDriverInit. The setTimer
        -- wrapper already uses this explicit-unpack form for the same reason.
        local callArgs = pack(...)

        local startTime = C4:GetTime()
        -- Save the original error before diagnostics so capture failure cannot
        -- replace it. Capture while the failing driver's frames are still live.
        local caughtError, caughtStack, errorSaved, isReraise
        local function onError(errorMessage)
            if errorSaved then return end
            errorSaved = true
            caughtError = errorMessage
            isReraise = isSdkRethrow(onError)
            if not isReraise then
                caughtStack = Diagnostics.capture({ captureKind = "exception", boundary = onError })
            end
        end
        local results = pack(xpcall(function()
            return func(unpack(callArgs, 1, callArgs.n))
        end, onError))
        local success, result = results[1], results[2]
        local endTime = C4:GetTime()

        -- === Telemetry: fully isolated from the driver. Any throw here is
        -- SDK-origin by construction; runSdkWork swallows it, routes it to the
        -- SDK fault sink, and CANNOT change what the driver returns or raises
        -- below. Nothing in this block is on the driver's critical path. ===
        -- A re-raise from an inner instrument frame: the error was already
        -- reported there, so this (outer) frame records its own event but must
        -- NOT emit a second error report for the same throw.
        self:runSdkWork("instrument:" .. name, function()
            self:debug("Finished executing wrapped function ", name, " (", endTime - startTime, "ms)")

            if not success and not isReraise then
                if caughtStack then
                    self:traceback(traceId, caughtError, caughtStack)
                else
                    -- Stack capture failed (SDK-internal); still report the
                    -- error, just without frames.
                    self._errorMessages[traceId] = errorText(caughtError)
                    self._eventStacktraces[traceId] = failedTrace()
                end
            end

            -- Named args are derived HERE (telemetry-only): introspecting the
            -- handler's parameters can throw, and that must never delay or
            -- corrupt the driver call. A plain array (no pack .n key) keeps the
            -- wire args byte-identical to the prior { ... } form. Redaction
            -- applies to telemetry only — the real args already reached func.
            local plainArgs = {}
            for i = 1, callArgs.n do plainArgs[i] = callArgs[i] end
            local payloadArgs = isSensitive and "[REDACTED]" or buildNamedArgs(func, plainArgs)

            -- Pre-generate errorId if there's an error (for bidirectional linking)
            local errorId = nil
            if not success and not isReraise then
                errorId = C4:UUID("RANDOM")
            end

            -- Explicit branch, not `isSensitive and nil or result`: with a nil
            -- middle operand that idiom always yields the result, which shipped
            -- the sensitive handler's return value onto the wire.
            local payloadResult = result
            if isSensitive then payloadResult = nil end

            -- The handler's complete return list for the wire, as a dense array
            -- of one-field boxes ({ value = v }; nil boxes to {}) — a Lua table
            -- cannot hold nil and a sparse array does not JSON-encode
            -- predictably, so boxing is what keeps arity and embedded nils
            -- intact through any encoder. `result` (first value) stays alongside
            -- for ingest back-compat.
            local payloadResults = nil
            if success and not isSensitive then
                payloadResults = {}
                for i = 2, results.n do
                    payloadResults[i - 1] = { value = results[i] }
                end
            end

            self:sendData(self:generateEventPayload(traceId, spanId, name, payloadArgs, startTime, endTime, endTime - startTime, success, payloadResult, payloadResults, nil, errorId, true))

            if not success and not isReraise then
                self:sendData(self:generateErrorPayload(
                    errorId, traceId, spanId, name, payloadArgs,
                    self._errorMessages[traceId], self._eventStacktraces[traceId]))
                self:debug("Error payload sent for event: ", name)
            end
        end)

        -- Restore context even if telemetry failed, and before any rethrow.
        -- Only this invocation's retained data is discarded.
        self._currentTraceId = parentTraceId
        self._currentSpanId = parentSpanId
        self._currentEventName = parentEventName
        self._eventLastLogs[traceId] = nil
        self._eventStacktraces[traceId] = nil
        self._errorMessages[traceId] = nil

        if not success then rethrow(caughtError) end

        -- results[1] is xpcall's success flag; everything after it is the
        -- handler's full return list, embedded nils included.
        return unpack(results, 2, results.n)
    end

    function anvil:generateLogMessagePayload(logLevelName, strMessage, args, argsTruncated)
        local logMessage = {}
        logMessage["level"] = logLevelName
        logMessage["message"] = strMessage
        -- The call's arguments as plain JSON, present only when one of them
        -- was not a string (see log_args.lua).
        logMessage["args"] = args
        if argsTruncated then logMessage["argsTruncated"] = true end
        logMessage["createdAt"] = C4:GetTime()
        -- A log carries the active event's (traceId, spanId) and name.
        -- A log emitted with no event in flight is its own root trace with
        -- a null spanId and no eventName.
        logMessage["traceId"] = self._currentTraceId or randomHex(16)
        logMessage["spanId"] = self._currentSpanId
        -- eventName mirrors spanId: set (camelCase, as on error payloads)
        -- only for in-event logs; omitted (nil key) for orphan logs.
        if self._currentSpanId then
            logMessage["eventName"] = self._currentEventName
        end

        if self._currentTraceId then
            self._eventLastLogs[self._currentTraceId] = strMessage
        end

        return self:generatePayload("log", logMessage)
    end

    function anvil:generateEventPayload(traceId, spanId, name, args, startedAt, finishedAt, duration, success, result, results, stacktrace, errorId, implemented)
        local payload = {}
        -- Event identity is (traceId, spanId). traceId is the
        -- 1:1 correlation key logs/errors reference; spanId is the root
        -- span. source marks this as a Control4-sourced root span.
        payload["traceId"] = traceId
        payload["spanId"] = spanId
        payload["source"] = "control4"
        payload["name"] = name
        payload["args"] = args
        payload["startedAt"] = startedAt
        payload["finishedAt"] = finishedAt
        payload["duration"] = duration
        payload["result"] = result
        payload["results"] = results
        payload["status"] = success and "ok" or "error"
        payload["implemented"] = implemented

        if errorId then
            payload["errorId"] = errorId
        end

        if (self._eventLastLogs[traceId]) then
            payload["lastLog"] = self._eventLastLogs[traceId]
        end

        if (self._eventStacktraces[traceId]) then
            payload["stacktrace"] = self._eventStacktraces[traceId]
        end

        if (self._errorMessages[traceId]) then
            payload["errorMessage"] = self._errorMessages[traceId]
        end

        return self:generatePayload("event", payload)
    end

    -- The driver's own filename, which is how telemetry is attributed to a
    -- driver. Resolved on first use rather than at Init: it is needed for
    -- attribution and nothing else, so a driver using only the licence surface
    -- never calls it — and never inherits the OS version that provides it
    -- (C4:GetDriverFileName is 3.3.0; licensing is not). Memoized because it
    -- cannot change for the life of a loaded driver.
    --
    -- Never substituted with a placeholder: a wrong attribution key is worse
    -- than an absent one. On any runtime the SDK is enabled for, this resolves.
    function anvil:driverFileName()
        if self._driverFileName == nil then
            local ok, name = pcall(function() return C4:GetDriverFileName() end)
            if ok and type(name) == "string" and name ~= "" then
                self._driverFileName = name
            end
        end
        return self._driverFileName
    end

    function anvil:generatePayload(eventType, data)
        local tags = {}
        tags["controller"] = C4:GetUniqueMAC()
        tags["driver"] = self:driverFileName()

        local event = {}
        data["controller"] = tags["controller"]
        data["driver"] = tags["driver"]
        -- The deployed driver's <version> on every log, event and error, so
        -- telemetry can be read back for one deploy. Errors and the lifecycle
        -- beacon already set it; never overwrite a version the caller chose.
        if data["driverVersion"] == nil then
            data["driverVersion"] = self._driverVersion
        end
        data["tags"] = tags

        event["eventType"] = eventType
        event["payload"] = data
        event["apiKey"] = self._token
        -- SDK version on every envelope. Agent extracts and
        -- includes it in the meta block of the MQTT message it forwards
        -- to ingestion, so Anvil can track per-driver SDK adoption.
        event["sdkVersion"] = self._sdkVersion

        return event
    end

    -- Generate error payload for dedicated error tracking
    function anvil:generateErrorPayload(errorId, traceId, spanId, eventName, args, errorMessage, stacktrace)
        local payload = {}
        payload["id"] = errorId or C4:UUID("RANDOM")  -- error's own entity id (referenced by events.errorId)
        -- In an event the error attributes to that event's
        -- (traceId, spanId). A standalone error (timer, manual capture)
        -- has no enclosing span: fresh root traceId, null spanId.
        payload["traceId"] = traceId or randomHex(16)
        payload["spanId"] = spanId
        payload["eventName"] = eventName
        payload["type"] = "lua:runtime_error"
        payload["value"] = errorText(errorMessage)
        payload["stacktrace"] = stacktrace or failedTrace()
        payload["args"] = args
        payload["driverVersion"] = self._driverVersion
        payload["createdAt"] = C4:GetTime()

        if traceId and self._eventLastLogs[traceId] then
            payload["lastLog"] = self._eventLastLogs[traceId]
        end

        return self:generatePayload("error", payload)
    end

    -- Manual error capture for non-instrumented contexts (timers, URL callbacks, etc.)
    -- errorMessage: string - the error message
    -- stacktrace: structured trace or nil - if nil, capture at call site
    -- context: table|nil - optional {eventName, args, traceId, spanId} for grouping
    function anvil:captureError(errorMessage, stacktrace, context)
        if self._instrumentationDisabled or (self._hasLateInited and not self:isAgentInstalled()) then return end
        local ctx = context or {}
        self:runSdkWork("captureError", function()
            local stack = stacktrace or Diagnostics.capture({ captureKind = "callsite", boundary = anvil.captureError })
            self:sendData(self:generateErrorPayload(
                nil, ctx.traceId, ctx.spanId, ctx.eventName or "ManualCapture",
                ctx.args or {}, errorMessage, stack
            ))
        end)
    end

    function anvil:forwardLog(logLevel, message, args, argsTruncated)
        if self._hasLateInited and not self:isAgentInstalled() then
            self:debug("Anvil agent not installed, not forwarding log message")
            return
        end
        self:sendData(self:generateLogMessagePayload(logLevel, message, args, argsTruncated))
    end

    -- Forward a log call's arguments, packed ({ n = count, ... }). Encoding
    -- is skipped entirely without an agent, and runs as SDK work, so nothing
    -- in it can reach the driver's logger.
    function anvil:forwardLogArgs(logLevel, packed)
        if self._hasLateInited and not self:isAgentInstalled() then return end
        self:runSdkWork("forwardLog", function()
            local message, args, truncated = LogArgs.encode(packed)
            if message ~= "" or args then
                self:forwardLog(logLevel, message, args, truncated)
            end
        end)
    end

    -- Lifecycle beacon: a small, identity-stamped signal about the driver
    -- process itself (not a C4 event/log/error). The agent uses the "ready"
    -- phase, fired once the driver has finished its late init, to confirm a
    -- freshly-deployed driver actually restarted and to read the running
    -- version. generatePayload stamps driver (filename), controller (MAC),
    -- apiKey and sdkVersion, so the beacon shares the same identity as every
    -- other envelope.
    function anvil:sendLifecycle(phase)
        local now = C4:GetTime()
        self:sendData(self:generatePayload("lifecycle", {
            phase = phase,                       -- e.g. "ready"
            driverVersion = self._driverVersion, -- the deployed driver's version
            createdAt = now,
        }))
        self:debug("Lifecycle beacon sent: ", tostring(phase))
    end

    -- Wrapper for C4:SetTimer that automatically captures errors in timer callbacks
    -- Use this instead of C4:SetTimer when you want automatic error reporting
    -- duration: number - timer duration in milliseconds
    -- callback: function - the callback function to execute
    -- ...: any additional arguments to pass to C4:SetTimer
    function anvil:setTimer(duration, callback, ...)
        if self._instrumentationDisabled then return C4:SetTimer(duration, callback, ...) end
        local extraArgs = pack(...)
        local timerName = "Timer"
        -- Keep the callback wrapper so an agent installed later can receive
        -- future errors, but do no diagnostic work while an agent is absent.
        if not (self._hasLateInited and not self:isAgentInstalled()) then
            pcall(function()
                -- This closure and pcall add two frames above setTimer.
                local callerInfo = debug.getinfo(4, "Sl")
                if callerInfo then
                    timerName = string.format("Timer@%s:%d", callerInfo.short_src, callerInfo.currentline)
                end
            end)
        end

        local function timerCallback(timer, ...)
            if self._instrumentationDisabled or (self._hasLateInited and not self:isAgentInstalled()) then
                return callback(timer, ...)
            end
            local callbackArgs = pack(timer, ...)
            local caughtError, caughtStack, errorSaved, isReraise
            local function onError(e)
                if errorSaved then return end
                errorSaved = true
                caughtError = e
                isReraise = isSdkRethrow(onError)
                if not isReraise then
                    caughtStack = Diagnostics.capture({ captureKind = "exception", boundary = onError })
                end
            end
            local results = pack(xpcall(function()
                return callback(unpack(callbackArgs, 1, callbackArgs.n))
            end, onError))

            if not results[1] then
                if not isReraise then
                    self:runSdkWork("timer", function()
                        self:sendData(self:generateErrorPayload(
                            nil, nil, nil, timerName, {}, caughtError, caughtStack
                        ))
                    end)
                end
                rethrow(caughtError)
            end

            return unpack(results, 2, results.n)
        end
        Diagnostics.registerFunction(timerCallback, { functionName = "timerCallback", role = "sdk" })
        return C4:SetTimer(duration, timerCallback, unpack(extraArgs, 1, extraArgs.n))
    end

    function anvil:start()
        self._agentReady = true
        self:processQueue()
    end

    -- Entry point after discovery finds an agent. With no attestation root
    -- embedded (AgentVerify.enabled() is false) verification is
    -- disabled and discovery is trusted as before. With a root embedded,
    -- the discovered device must prove it is the real agent before any
    -- telemetry flows: state goes pending (telemetry queues, bounded),
    -- then verified (queue drains) or failed (fail-closed, queue
    -- discarded). Fallback-to-trust on timeout would reinstate the
    -- impersonation hole as a downgrade attack, so a failure disables
    -- telemetry until a fresh discovery + a fresh, valid proof.
    --
    -- "Until a fresh discovery" used to mean "never", in the one case that
    -- happens most: a just-installed agent has not authenticated or registered
    -- yet, so it holds no attestation and cannot answer. The SDK challenges it
    -- the instant it is added — the single moment it is guaranteed to fail —
    -- and both recovery paths below exist because the SDK cannot tell that
    -- apart from impersonation: the agent announces when it becomes able to
    -- answer, and scheduleVerifyRetry re-asks on a bounded ladder if that
    -- announcement never lands. Neither weakens the decision; both only cause
    -- the SDK to demand a real proof again.
    function anvil:verifyAndStart()
        if not AgentVerify.enabled() then
            self:start()
            return
        end

        local challengerId
        pcall(function() challengerId = C4:GetDeviceID() end)
        if not challengerId or not AgentVerify.available() then
            -- A property of this runtime, not of the agent: no amount of
            -- re-asking will produce a device id or a way to hash.
            self:failVerification("verification prerequisites unavailable on this runtime",
                { retryable = false })
            return
        end

        self._verifyState = 'pending'
        self._verifyNonce = randomHex(16)
        self._verifyChallengerId = tostring(challengerId)

        C4:SendToDevice(self.AGENT_DEVICE_ID, AgentVerify.CHALLENGE_COMMAND, {
            nonce = self._verifyNonce,
            challengerDeviceId = self._verifyChallengerId,
        })

        -- No proof before the deadline reads as an impostor (or an agent
        -- too old to answer — the loud print says which upgrade fixes it).
        local timerOk = pcall(function()
            self._verifyTimer = C4:SetTimer(AgentVerify.TIMEOUT_MS, function()
                if self._verifyState == 'pending' then
                    self:failVerification("no proof received before the deadline"
                        .. " (an agent that predates verification cannot answer; update the agent)")
                end
            end)
        end)
        if not timerOk then
            -- No timers on this runtime means no retry ladder either, so this
            -- one really is terminal.
            self:failVerification("could not arm the verification deadline",
                { retryable = false })
        end
    end

    local function cancelVerifyTimer(self)
        if self._verifyTimer then
            pcall(function() self._verifyTimer:Cancel() end)
            self._verifyTimer = nil
        end
    end

    local function cancelRetryTimer(self)
        if self._verifyRetryTimer then
            pcall(function() self._verifyRetryTimer:Cancel() end)
            self._verifyRetryTimer = nil
        end
    end

    -- Make the disabled state legible. A driver latched off believes it is
    -- instrumented while sending into a void, and a lone print in the driver's
    -- own Lua output is not a surface anyone finds: the observed incident cost
    -- half a day precisely because nothing said so. The message is tagged so it
    -- is greppable, states the consequence rather than only the cause, and is
    -- mirrored to the controller error log — the one place an operator looks
    -- that is not this driver's log. Recorded on the instance too, so a driver
    -- can report its own status (Anvil:TelemetryStatus).
    function anvil:noteTelemetryDisabled(reason)
        -- Only the transition INTO the disabled state gets the full notice and
        -- the error-log entry. A failed retry is still a failure, but the
        -- driver was already dark: repeating the whole notice (and re-filling
        -- the controller error log) each rung would bury the one that mattered.
        local alreadyDisabled = self._telemetryDisabledReason ~= nil
        self._telemetryDisabledReason = tostring(reason)
        if alreadyDisabled then
            self:debug("Anvil: verification retry failed (", tostring(reason), ")")
            return
        end
        local message = "Anvil: TELEMETRY DISABLED for " .. tostring(self:driverFileName())
            .. " - the device claiming to be the Anvil agent failed identity verification ("
            .. tostring(reason) .. "). This driver's events, logs and errors are being"
            .. " discarded, not sent."
        print(message)
        pcall(function()
            if C4 and C4.ErrorLog then C4:ErrorLog(message) end
        end)
    end

    -- The matching transition. Without it the disabled notice above has no
    -- counterpart and a recovered driver looks identical to a latched one.
    function anvil:noteTelemetryRestored()
        if not self._telemetryDisabledReason then return end
        self._telemetryDisabledReason = nil
        print("Anvil: telemetry restored for " .. tostring(self:driverFileName())
            .. " - the Anvil agent verified successfully.")
    end

    -- What this driver can say about its own telemetry, for a driver that wants
    -- to surface the state itself (a property, its own log, a UI). Deliberately
    -- a plain snapshot: reading it must not trigger discovery or verification.
    function anvil:telemetryStatus()
        local state
        if self._unsupportedRuntime then
            -- Checked first: this one is decided at load, before late-init has
            -- an opinion, and it outranks every other state — nothing else can
            -- become true once the SDK has switched itself off.
            state = 'unsupported-runtime'
        elseif not self._hasLateInited then
            state = 'initialising'
        elseif self._agentReady then
            state = 'ready'
        elseif self._verifyState == 'pending' then
            state = 'verifying'
        elseif self._verifyState == 'failed' then
            state = 'disabled'
        else
            state = 'no-agent'
        end
        return {
            enabled = self._agentReady == true,
            state = state,
            reason = self._telemetryDisabledReason
                or (self._unsupportedRuntime
                    and ("requires Control4 OS " .. self.MINIMUM_OS .. " or newer"))
                or nil,
        }
    end

    function anvil:failVerification(reason, opts)
        self._verifyState = 'failed'
        self._verifyNonce = nil
        cancelVerifyTimer(self)
        self:noteTelemetryDisabled(reason)
        -- From here the existing agent-less machinery applies: no capture,
        -- no queuing, no retained memory. Clearing _agentReady matters when a
        -- previously-verified driver re-verifies against a replaced agent and
        -- fails: left set, sendData would keep dispatching to the device id
        -- being cleared on the next line.
        self._agentReady = false
        self.AGENT_DEVICE_ID = nil
        self:discardQueue()
        if not (opts and opts.retryable == false) then
            self:scheduleVerifyRetry()
        end
    end

    -- Arm the next rung of the backstop ladder. Each rung re-runs discovery and
    -- challenges again; a rung that fails schedules the next through
    -- failVerification, so the ladder walks itself. Once exhausted the driver
    -- stays disabled — that is the terminal outcome an impostor must get.
    function anvil:scheduleVerifyRetry()
        local attempt = (self._verifyRetryAttempt or 0) + 1
        local delay = AgentVerify.RETRY_DELAYS_MS[attempt]
        if not delay then
            -- Said once. Past this point every further failure is another
            -- rejected challenge, which is the ladder working as intended, not
            -- news worth reprinting.
            if not self._verifyRetryExhausted then
                self._verifyRetryExhausted = true
                print("Anvil: agent verification has failed " .. tostring(attempt - 1)
                    .. " times; giving up on automatic recovery. Telemetry stays disabled for "
                    .. tostring(self:driverFileName())
                    .. " until the driver restarts (or the agent announces it is ready).")
            end
            return
        end
        self._verifyRetryAttempt = attempt
        cancelRetryTimer(self)
        pcall(function()
            self._verifyRetryTimer = C4:SetTimer(delay, function()
                self._verifyRetryTimer = nil
                self:retryVerification("scheduled retry " .. tostring(attempt))
            end)
        end)
    end

    -- Re-run discovery and re-challenge. Guarded on the latched state: a
    -- verified or in-flight driver has nothing to recover, so a stray trigger
    -- (including a spoofed readiness announcement) is a no-op rather than a way
    -- to knock a working driver back into the handshake.
    function anvil:retryVerification(trigger)
        if self._verifyState ~= 'failed' then return end

        self:debug("Retrying agent verification (", tostring(trigger), ")")
        self:discoverAnvilAgent()
        if self:isAgentInstalled() then
            self:verifyAndStart()
        else
            -- Nothing under the agent's filename right now. verifyAndStart is
            -- what normally walks the ladder on, so keep it moving from here.
            self:scheduleVerifyRetry()
        end
    end

    -- The agent telling a challenger it could not satisfy that it can answer
    -- now. This grants nothing: it only makes the SDK ask again, and the answer
    -- still has to be a valid attestation from whatever responds.
    function anvil:handleAgentReady()
        if self._verifyState ~= 'failed' then return end

        local used = (self._verifyAnnounceRetries or 0) + 1
        if used > AgentVerify.MAX_ANNOUNCE_RETRIES then
            self:debug("Ignoring agent-ready announcement: retry budget exhausted")
            return
        end
        self._verifyAnnounceRetries = used

        -- The announcement supersedes any pending rung: re-challenging now is
        -- strictly better than waiting out a timer, and leaving the old rung
        -- armed would fire a redundant second challenge mid-handshake.
        cancelRetryTimer(self)
        self:retryVerification("agent readiness announcement")
    end

    -- SDK-protocol traffic arriving via the harness's ExecuteCommand
    -- global. Returns true when the command was addressed to the SDK and
    -- must not reach the driver's own handler.
    function anvil:handleProtocolCommand(command, params)
        if command == AgentVerify.PROOF_COMMAND then
            self:handleVerifyProof(params or {})
            return true
        end
        if command == AgentVerify.READY_COMMAND then
            self:handleAgentReady()
            return true
        end
        return false
    end

    function anvil:handleVerifyProof(proof)
        if self._verifyState ~= 'pending' then return end
        -- A stale or foreign proof is ignored, not failed: the deadline
        -- still guards the pending state.
        if proof.nonce ~= self._verifyNonce then return end

        local mac
        pcall(function() mac = C4:GetUniqueMAC() end)

        local verified, reason = AgentVerify.verifyProof(proof, {
            nonce = self._verifyNonce,
            mac = mac,
            agentDeviceId = tostring(self.AGENT_DEVICE_ID),
            challengerDeviceId = self._verifyChallengerId,
            now = os.time(),
        })
        if not verified then
            self:failVerification(reason or "invalid proof")
            return
        end

        self._verifyState = 'verified'
        self._verifyNonce = nil
        cancelVerifyTimer(self)
        -- Both budgets reset on success, so a later agent replacement gets a
        -- full ladder rather than inheriting an exhausted one.
        cancelRetryTimer(self)
        self._verifyRetryAttempt = 0
        self._verifyAnnounceRetries = 0
        self._verifyRetryExhausted = false
        self:debug("Anvil agent identity verified")
        self:noteTelemetryRestored()
        self:start()
    end

    -- Free the pre-late-init buffer on a controller with no agent: the
    -- queue exists to bridge the gap until the agent is discovered, and
    -- once discovery has come up empty nothing will ever drain it.
    function anvil:discardQueue()
        self._eventQueue = Queue.new()
        self._droppedQueuedEvents = 0
    end

    function anvil:queueItem(data)
        self:debug("Queuing item for later processing")
        -- Drop-oldest keeps the newest telemetry: when the agent finally
        -- appears, the tail of what happened is worth more than the head.
        while Queue.length(self._eventQueue) >= self.MAX_QUEUED_EVENTS do
            Queue.pop(self._eventQueue)
            self._droppedQueuedEvents = (self._droppedQueuedEvents or 0) + 1
        end
        Queue.push(self._eventQueue, data)
    end

    function anvil:processQueue()
        self:debug("Processing queue")
        if self._droppedQueuedEvents and self._droppedQueuedEvents > 0 then
            print("Anvil: dropped " .. self._droppedQueuedEvents
                .. " oldest queued envelope(s) while waiting for the agent (cap "
                .. self.MAX_QUEUED_EVENTS .. ")")
            self._droppedQueuedEvents = 0
        end
        for i = 1, Queue.length(self._eventQueue) do
            local event = Queue.pop(self._eventQueue)
            self:sendData(event)
        end
    end

    function anvil:isAgentReady()
        return self._agentReady
    end

    function anvil:sendData(data)
        if not data then
            return
        end

        -- Deliberately do NOT forward `_clientOptions` to the agent: the
        -- agent ignores client-supplied configuration. `_clientOptions`
        -- stays in-process for SDK-internal use of `logger`/`logMap` only.

        if not self:isAgentReady() then
            -- Once late-init has determined no agent is installed, drop
            -- instead of queue: nothing will ever drain the queue, and the
            -- production contract is zero steady-state footprint (the same
            -- build ships everywhere; agent absence is the gate). An agent
            -- installed later (driver-added rediscovery) gets future
            -- events, not backfill.
            if self._hasLateInited and not self:isAgentInstalled() then
                return
            end
            self:queueItem(data)
            return
        end

        self:debug("Sending data to anvil agent")

        local function dispatch()
            C4:SendToDevice(self.AGENT_DEVICE_ID, self.SEND_DATA_COMMAND, { payload = C4:JsonEncode(data) }, false, false)
        end

        -- Optional debug delay: a Composer property, so its value is a STRING.
        -- Only honour it when it coerces to a positive number — passing a
        -- non-number (empty/garbage) to C4:SetTimer raises "Invalid argument
        -- value". Coerce + guard so a bad value just sends immediately.
        local delay = tonumber(Properties["Anvil Debug Delay"])

        -- Belt-and-braces: never let a send failure propagate out of sendData.
        -- It runs inside processQueue → start → the harness OnDriverLateInit,
        -- all OUTSIDE instrument's xpcall, so a raise here would abort late-init
        -- (and the ready beacon) and — being in the send path itself — never
        -- reach Anvil. Degrade to a local print instead.
        local ok, err = pcall(function()
            if delay and delay > 0 then
                C4:SetTimer(delay, function()
                    local sok, serr = pcall(dispatch)
                    if not sok then print("Anvil: Error sending delayed data: " .. tostring(serr)) end
                end)
            else
                dispatch()
            end
        end)
        if not ok then
            print("Anvil: Error sending data to agent: " .. tostring(err))
        end

        self:debug("Sent to agent")
    end

    function anvil:isAgentInstalled()
        if not self._hasLateInited then
            error("isAgentInstalled can not be called before OnDriverLateInit")
        end

        if self.AGENT_DEVICE_ID then
            return true
        end

        return false
    end

    function anvil:discoverAnvilAgent()
        if not self._hasLateInited then
            error("discoverAnvilAgent can not be called before OnDriverLateInit")
        end

        -- Below the floor, stay out of the runtime entirely: no discovery, so
        -- no agent, so late-init takes the same path it takes on an agent-less
        -- controller — the buffer is discarded and nothing is retained. An
        -- agent could not have delivered this driver's telemetry anyway.
        if self._unsupportedRuntime then return nil end

        local anvilAgentName = self._agentDriverName or self.AGENT_DRIVER_FILENAME
        self:debug("Looking for Anvil agent using filename ", anvilAgentName)
        local anvilAgent = C4:GetDevicesByC4iName(anvilAgentName)
        if not anvilAgent then
            return nil
        end

        local instanceCount = 0

        for _ in pairs(anvilAgent) do
            instanceCount = instanceCount + 1
        end

        if instanceCount == 0 then
            return nil
        end

        for agentDeviceId in pairs(anvilAgent) do
            self.AGENT_DEVICE_ID = agentDeviceId
        end

        self:debug("Anvil agent identified, device id: ", self.AGENT_DEVICE_ID)

        return self.AGENT_DEVICE_ID
    end

    -- The floor check, run once as the module loads. On a runtime that has
    -- everything this is a handful of field reads and nothing changes; on one
    -- that doesn't, the SDK switches itself off here — before Init, before any
    -- handler wrapper can fire, and before a single event is captured.
    --
    -- It reuses the same short-circuit a failed boundary self-test uses:
    -- instrument() forwards the driver's own function raw and emits nothing, so
    -- the driver behaves exactly as it would with no SDK vendored at all.
    local missing = missingC4Capabilities()
    if #missing > 0 then
        anvil._unsupportedRuntime = table.concat(missing, ", ")
        anvil._instrumentationDisabled = true

        -- Said once, plainly, because the alternative is a developer staring at
        -- an empty dashboard with nothing to explain it. Not an error: an
        -- unsupported controller is a supported outcome, and the driver itself
        -- is unaffected.
        --
        -- Names the version and nothing else. Which C4 API is absent is our
        -- implementation detail, and a driver author can act on a version
        -- number but not on a capability name. The missing set stays in
        -- _unsupportedRuntime for our own debugging.
        print("Anvil: this controller is running Control4 OS older than "
            .. anvil.MINIMUM_OS .. " - the SDK has disabled itself and the"
            .. " driver will run uninstrumented.")
    end

    -- The harness's late-init pcall also rethrows after its lifecycle beacon.
    -- Use the same boundary so an enclosing collector recognises that rethrow.
    anvil.rethrow = rethrow

    -- Identify SDK frames by function identity, including helpers that can
    -- appear beneath a driver callback. Never infer ownership from filenames.
    for name, fn in pairs(anvil) do
        if type(fn) == "function" then
            Diagnostics.registerFunction(fn, { functionName = name, role = "sdk" })
        end
    end
    return anvil
end)()

return _M
