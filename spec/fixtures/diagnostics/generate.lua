-- Run from sdk/: lua spec/fixtures/diagnostics/generate.lua > /tmp/traces.json
-- Requires the test-only dkjson encoder; no encoder is bundled in the collector.
local Diagnostics = require 'diagnostics'
local json = require 'dkjson'
local fixtureTrace
local function onError(err)
    fixtureTrace = Diagnostics.capture({ captureKind = 'exception', boundary = onError })
    return err
end
local driver = assert((loadstring or load)([[
return function()
    local shared = { enabled = true, attempts = 3 }
    shared.self = shared
    local payload = { [1] = 'number key', ['1'] = 'string key', shared = shared,
        binary = '\0\255', huge = string.rep('x', 10000), positiveInfinity = math.huge }
    local empty = {}
    error('fixture error')
end
]], '@driver.lua'))()
Diagnostics.registerFunction(driver, { functionName = 'OnPropertyChanged', role = 'driver' })
xpcall(driver, onError)
-- Keep the actual throw-site frame. Its values reference only IDs defined in it.
-- Caller frames vary with the runner and do not belong in a portable fixture.
fixtureTrace.frames = { fixtureTrace.frames[1] }
local failed = Diagnostics.capture({ boundary = function() end })
io.write(json.encode({ exception = fixtureTrace, failed = failed }, { indent = true }), '\n')
