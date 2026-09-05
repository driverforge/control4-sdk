local RS256 = require 'rs256'
local openssl = require 'openssl'

-- Deterministic, size-bounded malformed inputs. Keep a separate instruction
-- budget so a regression cannot hang CI, including when verify catches the
-- hook's error internally. Disable JIT while counting VM instructions.
local function boundedVerify(...)
    local hook, mask, count = debug.gethook()
    local wasJit = jit and jit.status()
    if jit then jit.off(); jit.flush() end
    local ticks, exhausted = 0, false
    debug.sethook(function()
        ticks = ticks + 1
        if ticks > 10000 then
            exhausted = true
            error('RS256 instruction budget exceeded')
        end
    end, '', 10000)
    local ok, result, reason = pcall(RS256.verify, ...)
    debug.sethook(hook, mask, count)
    if wasJit then jit.on() end
    assert.is_false(exhausted)
    assert.is_true(ok, result)
    assert.is_boolean(result)
    if not result then assert.is_string(reason) end
    return result
end

describe('RS256 bounded malformed-input checks', function()
    -- Park-Miller: identical sequence in Lua 5.1 and LuaJIT, independent of
    -- math.random's implementation and the rest of the suite's random state.
    local seed = 8017
    local function random(limit)
        seed = (seed * 16807) % 2147483647
        return seed % limit
    end
    local function blob(length)
        local result = {}
        for i = 1, length do result[i] = string.char(random(256)) end
        return table.concat(result)
    end

    it('rejects bounded random signatures and agrees with OpenSSL', function()
        local key = openssl.pkey.new('rsa', 2048)
        local modulus = RS256.hexToBytes(key:parse().rsa:parse().n:tohex())
        for _ = 1, 64 do
            local message, signature = blob(random(257)), blob(256)
            local digest = openssl.digest.digest('sha256', message, false)
            assert.is_falsy(key:verify(message, signature, 'sha256'))
            assert.is_false(boundedVerify(digest, signature, modulus, 65537))
        end
    end)

    it('returns false without throwing for malformed keys and input types', function()
        local digest = string.rep('\0', 32)
        for _, length in ipairs({ 0, 1, 2, 3, 4, 31, 32, 61, 62, 63, 64, 255, 256 }) do
            local signature = string.rep('\0', length)
            for _, modulus in ipairs({ signature, blob(length), string.rep('\255', length) }) do
                for _, exponent in ipairs({ '', '\0', '\1', '\255\255\255\255\255', 3, 65537 }) do
                    assert.is_false(boundedVerify(digest, signature, modulus, exponent))
                end
            end
        end
        for _, value in ipairs({ false, true, {}, function() end, 0, math.huge }) do
            assert.is_false(boundedVerify(value, '', '', 65537))
            assert.is_false(boundedVerify(digest, value, '', 65537))
            assert.is_false(boundedVerify(digest, '', value, 65537))
            assert.is_false(boundedVerify(digest, '', '', value))
        end
    end)
end)
