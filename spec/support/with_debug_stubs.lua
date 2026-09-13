-- Debug fault injection must not also break LuaCov's debug.getinfo calls.
-- Suspend only its hook, and restore debug functions before restoring coverage,
-- including when the code under test raises unexpectedly.
local function pack(...)
    return { n = select('#', ...), ... }
end

return function(stubs, callback)
    local runner = package.loaded['luacov.runner']
    local hook, mask, count = debug.gethook()
    local suspend = hook and runner and hook == runner.debug_hook
    if suspend then debug.sethook() end
    local originals = {}
    for name, replacement in pairs(stubs) do
        originals[name] = debug[name]
        debug[name] = replacement
    end
    local result = pack(pcall(callback))
    for name in pairs(stubs) do debug[name] = originals[name] end
    if suspend then debug.sethook(hook, mask, count) end
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end
