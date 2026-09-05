local RS256 = require 'rs256'
local openssl = require 'openssl'
local json = require 'cjson'
local withoutCoverage = require 'spec.support.without_coverage'

local function verify(...)
    return withoutCoverage(RS256.verify, ...)
end

local bytes = RS256.hexToBytes
local function digest(message)
    return openssl.digest.digest('sha256', message, false)
end

describe('RS256 RFC 8017 conformance (Wycheproof)', function()
    for _, size in ipairs({ 2048, 3072, 4096 }) do
        local filename = 'rsa_signature_' .. size .. '_sha256_test.json'
        local file = assert(io.open('spec/fixtures/wycheproof/' .. filename, 'rb'))
        local corpus = json.decode(file:read('*a'))
        file:close()
        local count = 0
        for _, group in ipairs(corpus.testGroups) do
            assert.equals('SHA-256', group.sha)
            -- ASN.1 INTEGER's sign byte is not part of the unsigned JWK n.
            local modulus = bytes(group.publicKey.modulus):gsub('^%z+', '')
            local exponent = bytes(group.publicKey.publicExponent)
            for _, case in ipairs(group.tests) do
                count = count + 1
                it(filename .. ' #' .. case.tcId .. ': ' .. case.comment, function()
                    local expected = case.result == 'valid'
                    if case.result == 'acceptable' then
                        -- RFC 8017 A.2.4 requires the SHA-256 NULL parameters.
                        -- Reject this legacy encoding; do not silently adopt
                        -- a policy for new acceptable categories on updates.
                        assert.same({ 'MissingNull' }, case.flags)
                    else
                        assert.is_true(case.result == 'valid' or case.result == 'invalid')
                    end
                    local actual, reason = verify(
                        digest(bytes(case.msg)), bytes(case.sig), modulus, exponent)
                    assert.equals(expected, actual, reason)
                end)
            end
        end
        assert.equals(corpus.numberOfTests, count)
    end
end)

describe('RS256 differential checks against OpenSSL', function()
    -- Include sizes on either side of a 24-bit arithmetic limb boundary and
    -- a modulus whose bit length is not a multiple of eight. Small keys are
    -- arithmetic fixtures only, not a recommendation for deployment.
    for _, bits in ipairs({ 1024, 2047, 2048, 2049, 2064, 2065 }) do
        for _, exponent in ipairs({ 3, 65537 }) do
            it('agrees for fresh ' .. bits .. '-bit keys, e=' .. exponent, function()
                local key = openssl.pkey.new('rsa', bits, exponent)
                local rsa = key:parse().rsa:parse()
                assert.equals(exponent, rsa.e:tonumber())
                local hex = rsa.n:tohex()
                if #hex % 2 == 1 then hex = '0' .. hex end
                local modulus = bytes(hex)
                for _, message in ipairs({ '', 'a\0b\255', string.rep('boundary', 128) }) do
                    local signature = key:sign(message, 'sha256')
                    assert.is_true(key:verify(message, signature, 'sha256'))
                    assert.is_true(verify(digest(message), signature, modulus, exponent))
                    local changed = message .. '\0'
                    assert.is_falsy(key:verify(changed, signature, 'sha256'))
                    assert.is_false(verify(digest(changed), signature, modulus, exponent))
                    local corrupted = string.char((signature:byte(1) + 1) % 256) .. signature:sub(2)
                    assert.is_falsy(key:verify(message, corrupted, 'sha256'))
                    assert.is_false(verify(digest(message), corrupted, modulus, exponent))
                end
            end)
        end
    end
end)
