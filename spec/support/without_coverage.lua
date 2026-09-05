-- Hundreds of RSA vectors execute the same arithmetic loops. LuaCov's line
-- hook makes that run exceed CI's timeout, without adding useful coverage
-- beyond rs256_spec.lua. Suspend only LuaCov's hook, never another tool's,
-- and restore it even when the callback raises an error.
local function pack(...)
    return { n = select('#', ...), ... }
end

return function(callback, ...)
    local runner = package.loaded['luacov.runner']
    local hook, mask, count = debug.gethook()
    if not runner or hook ~= runner.debug_hook or not hook then
        return callback(...)
    end
    debug.sethook()
    local result = pack(pcall(callback, ...))
    debug.sethook(hook, mask, count)
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end
