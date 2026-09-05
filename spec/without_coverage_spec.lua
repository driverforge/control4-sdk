local withoutCoverage = require 'spec.support.without_coverage'

describe('conformance coverage isolation', function()
    local originalHook, originalMask, originalCount, originalRunner
    before_each(function()
        originalHook, originalMask, originalCount = debug.gethook()
        originalRunner = package.loaded['luacov.runner']
    end)
    after_each(function()
        debug.sethook(originalHook, originalMask, originalCount)
        package.loaded['luacov.runner'] = originalRunner
    end)

    it('removes the coverage hook during the call and restores it afterwards', function()
        local hook = function() end
        package.loaded['luacov.runner'] = { debug_hook = hook }
        debug.sethook(hook, 'l')
        local first, second, third = withoutCoverage(function(value)
            assert.is_nil(debug.gethook())
            return value, nil, 'tail'
        end, 'head')
        assert.equals('head', first)
        assert.is_nil(second)
        assert.equals('tail', third)
        assert.equals(hook, debug.gethook())
    end)

    it('restores coverage and preserves the error when an assertion fails', function()
        local hook, failure = function() end, {}
        package.loaded['luacov.runner'] = { debug_hook = hook }
        debug.sethook(hook, 'l')
        local ok, err = pcall(withoutCoverage, function()
            assert.is_nil(debug.gethook())
            error(failure)
        end)
        assert.is_false(ok)
        assert.equals(failure, err)
        assert.equals(hook, debug.gethook())
    end)

    it('preserves hooks belonging to other tools', function()
        local hook = function() end
        package.loaded['luacov.runner'] = { debug_hook = function() end }
        debug.sethook(hook, '', 10000)
        withoutCoverage(function() assert.equals(hook, debug.gethook()) end)
        local actual, mask, count = debug.gethook()
        assert.equals(hook, actual)
        assert.equals('', mask)
        assert.equals(10000, count)
    end)
end)
