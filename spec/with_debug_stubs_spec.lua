local withDebugStubs = require 'spec.support.with_debug_stubs'

describe('debug fault injection isolation', function()
    it('restores debug functions and coverage after an unexpected failure', function()
        local getinfo = debug.getinfo
        local hook, mask, count = debug.gethook()
        local failure = {}
        local ok, err = pcall(withDebugStubs, {
            getinfo = function() error(failure, 0) end,
        }, function() return debug.getinfo(1) end)
        assert.is_false(ok)
        assert.are.equal(failure, err)
        assert.are.equal(getinfo, debug.getinfo)
        local restoredHook, restoredMask, restoredCount = debug.gethook()
        assert.are.equal(hook, restoredHook)
        assert.are.equal(mask, restoredMask)
        assert.are.equal(count, restoredCount)
    end)

    it('preserves callback returns including embedded nils', function()
        local getlocal = debug.getlocal
        local first, second, third = withDebugStubs({
            getlocal = function() return 'stubbed' end,
        }, function() return debug.getlocal(1), nil, 'tail' end)
        assert.are.equal('stubbed', first)
        assert.is_nil(second)
        assert.are.equal('tail', third)
        assert.are.equal(getlocal, debug.getlocal)
    end)
end)
