local anvil = require 'client'
local Diagnostics = require 'diagnostics'
local unpack = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end
-- Module return, kept out of the host driver's _G. pcall so an odd
-- embedding without the version module degrades to "unknown" instead of
-- failing the whole harness load.
local versionOk, SDK_VERSION = pcall(require, 'version')
if not versionOk then SDK_VERSION = nil end

-- Two namespaces, split by product rather than by kind of call.
--
--   Driverforge:  the driver's relationship to the platform.
--   Anvil:        the instrumentation verbs, which produce telemetry for the
--                 Anvil agent and are inert without one.
--
-- A driver calls Driverforge:Init once and then uses whichever surface it
-- needs. Neither namespace is required for the other to work.
Driverforge = Driverforge or {
    -- Initialise the SDK.
    -- @param token: the project's driver token (`drv_` prefix). An identifier,
    --   not a credential — it names the driver, it does not authenticate it,
    --   so shipping it inside a driver is expected.
    -- @param opts: optional configuration { logger, logMap, agentDriverName }
    --
    -- The driver's filename is NOT a parameter: the SDK reads it from
    -- C4:GetDriverFileName() when it first needs it. A caller-supplied name
    -- could disagree with the file actually running and mis-attribute usage.
    Init = function(self, token, opts)
        anvil._token = token

        -- Capture the driver version from driver.xml's spec-defined
        -- `version` field, falling back to "unknown".
        if C4 and C4.GetDriverConfigInfo then
            anvil._driverVersion = C4:GetDriverConfigInfo("version") or "unknown"
        else
            anvil._driverVersion = "unknown"
        end
        anvil:debug("Driver version: ", anvil._driverVersion)

        -- Capture SDK version baked at build time. Surfaced to
        -- the agent in every event/log/error envelope so Anvil can
        -- track which SDK versions are running across the deployed
        -- fleet. Returned by src/version.lua (required above).
        anvil._sdkVersion = SDK_VERSION or "unknown"
        anvil:debug("SDK version: ", anvil._sdkVersion)

        anvil:initDebugCache()

        if opts then
            anvil._clientOptions = opts
            -- Which agent device to discover. Set this from the driver's own
            -- (build-time) env config to point a dev build at a dev agent
            -- (e.g. "anvil-agent-dev.c4z"); leave unset in prod to use the
            -- default. SDK-internal — only affects this driver's own
            -- discovery, never forwarded to the agent.
            anvil._agentDriverName = opts.agentDriverName
            if opts.logger then
                -- Install the forwarding proxy directly on the
                -- caller's logger so existing call sites in their
                -- driver (Log:Info, Log:Error, ...) auto-forward to
                -- Anvil without any code change. Pre-fix this assigned
                -- a new proxy to a never-read Anvil.logger field, so
                -- the only way to get forwarding was to call
                -- Anvil:ForwardLog manually from inside the driver's
                -- own log methods.
                anvil:installLoggerProxy(opts.logger, opts.logMap)
            end
        end
    end,
}

Anvil = Anvil or {
    OnDriverInit = function(self, func, strDIR)
        anvil:debug("Anvil:OnDriverInit has been called, instrumenting")
        return anvil:instrument('OnDriverInit', func, strDIR)
    end,

    -- Forward a log line from a driver whose logger the SDK does not wrap.
    -- Takes the same arguments as a log call: tables are sent as structured
    -- data alongside the message.
    ForwardLog = function(self, logLevel, ...)
        anvil:forwardLogArgs(logLevel, { n = select('#', ...), ... })
    end,

    -- Manual error capture for non-instrumented contexts (timers, URL callbacks, etc.)
    -- @param errorMessage: string - the error message
    -- @param stacktrace: structured trace or nil - if nil, capture at call site
    -- @param context: table|nil - optional {eventName, args, traceId, spanId} for grouping
    CaptureError = function(self, errorMessage, stacktrace, context)
        anvil:captureError(errorMessage, stacktrace, context)
    end,

    -- Wrapper for C4:SetTimer that automatically captures errors in timer callbacks
    -- Use this instead of C4:SetTimer when you want automatic error reporting
    -- @param duration: number - timer duration in milliseconds
    -- @param callback: function - the callback function to execute
    -- @param ...: any additional arguments to pass to C4:SetTimer
    SetTimer = function(self, duration, callback, ...)
        return anvil:setTimer(duration, callback, ...)
    end,

    -- Whether this driver's telemetry is actually going anywhere, so a driver
    -- that believes it is instrumented can say otherwise instead of silently
    -- sending into a void. Returns { enabled, state, reason } where state is
    -- one of "initialising", "ready", "verifying", "no-agent" or "disabled",
    -- and reason carries the verification failure when state is "disabled".
    -- A pure read: it never triggers discovery or verification.
    TelemetryStatus = function(self)
        return anvil:telemetryStatus()
    end
}

function OnDriverLateInit(...)
    -- Run the boundary self-test before _hasLateInited flips: while it is still
    -- false the probe takes the instrumented (xpcall) path rather than the
    -- agent-absent short-circuit, so it actually exercises the boundary that
    -- ships to the driver. A failure disables instrumentation and fails open.
    anvil:runBoundarySelfTest()

    anvil._hasLateInited = true

    anvil:discoverAnvilAgent()

    if anvil:isAgentInstalled() then
        -- With an attestation root embedded this challenges the discovered
        -- device and starts only on a valid proof; without one it starts
        -- immediately (verification disabled).
        anvil:verifyAndStart()
    else
        -- Production contract: the same build ships everywhere and agent
        -- absence is the gate, so an agent-less controller must carry zero
        -- steady-state footprint. Discovery came up empty — nothing will
        -- ever drain the pre-late-init buffer; holding it would buy only
        -- backfill for an install that (on production) never comes.
        anvil:discardQueue()
    end

    -- Keep the full result list, including nils, while the lifecycle beacon
    -- runs before control returns to the caller.
    local results = pack(pcall(anvil.instrument, anvil,
        'OnDriverLateInit', anvil.EventHandlers.OnDriverLateInit, ...))

    -- Tell the agent this driver has finished coming up. Gated on the agent
    -- being installed: without an agent the beacon would queue forever (the
    -- queue is only drained by start(), which we just skipped). Fired after
    -- the driver's own late-init handler — and before re-raising any error
    -- it threw — so a "ready" beacon alongside an error envelope tells the
    -- agent the driver is up but its init threw.
    if anvil:isAgentInstalled() then
        anvil:sendLifecycle('ready')
    end

    -- instrument() already reported the error; re-raise it unchanged so the
    -- Director sees exactly what an uninstrumented driver would have thrown.
    if not results[1] then anvil.rethrow(results[2]) end
    return unpack(results, 2, results.n)
end

function OnPropertyChanged(sProperty, ...)
    anvil:refreshDebugCache(sProperty)
    return anvil:instrument('OnPropertyChanged', anvil.EventHandlers.OnPropertyChanged, sProperty, ...)
end

-- OnDriverAdded is the SDK's one rediscovery trigger for an agent installed
-- after this driver. Delegates to the driver's own handler when captured.
function OnDriverAdded(...)
    return anvil:instrument('OnDriverAdded', anvil.EventHandlers.OnDriverAdded, ...)
end

-- The agent's verification proof arrives as an ExecuteCommand invocation, so
-- it is checked before the call is instrumented. Protocol traffic
-- addressed to the SDK is intercepted and never forwarded to the driver's
-- handler — it would not exist without the SDK, so swallowing it is not a
-- mutation of driver behaviour (the one carve-out from the non-mutation
-- rule). Everything else delegates exactly as the dynamic loop below would.
function ExecuteCommand(strCommand, tParams)
    if anvil:handleProtocolCommand(strCommand, tParams) then return end
    return anvil:instrument('ExecuteCommand', anvil.EventHandlers.ExecuteCommand, strCommand, tParams)
end

-- Register every remaining known handler, implemented or not. Director only
-- calls globals that exist, so iterating the driver's captured handlers here
-- would leave unimplemented callbacks with no global, and a call to one would
-- never be recorded as "not implemented".
for _, name in ipairs(anvil.HandlerNames) do
    if name ~= "OnDriverLateInit" and name ~= "OnPropertyChanged"
        and name ~= "OnDriverAdded" and name ~= "ExecuteCommand" then
        _G[name] = function(...)
            return anvil:instrument(name, anvil.EventHandlers[name], ...)
        end
    end
end

-- Load-order contract: a driver must define its C4 handlers BEFORE requiring
-- the SDK. These globals now belong to the harness — record them so the first
-- instrumented call can warn if a later definition clobbered one (the classic
-- symptom: OnDriverLateInit replaced, Anvil never initialises, telemetry
-- silently queues until the cap discards it).
anvil:registerOwnedGlobals({
    OnDriverLateInit = OnDriverLateInit,
    OnPropertyChanged = OnPropertyChanged,
    OnDriverAdded = OnDriverAdded,
    ExecuteCommand = ExecuteCommand,
})

Diagnostics.registerFunction(Anvil.CaptureError, { skip = true })

-- Now that every wrapper is installed in _G, register the names
-- for the frames the SDK reshaped: the driver's displaced originals (so the
-- throw site is named, not `?`) and the wrappers (labelled as the boundary).
-- Built here because only the harness knows which _G globals it now owns.
local ownedWrappers = {}
for _, name in ipairs(anvil.HandlerNames) do
    ownedWrappers[name] = _G[name]
end
anvil:nameHandlerFrames(ownedWrappers)
