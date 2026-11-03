-- Real-crypto specs: a genuine attestation root, a genuine per-device
-- keypair + certificate, and a genuinely signed attestation JWT — so the
-- verification path is proven end to end, not against stubs. Requires
-- lua-openssl in the spec environment (the same binding the firmware
-- provides); the whole suite self-gates if it's absent.
local hasOpenssl, openssl = pcall(require, 'openssl')

if not hasOpenssl then
    describe('agent_verify', function()
        it('specs skipped: no openssl in this environment', function() end)
    end)
    return
end

local cjson = require 'cjson'

describe('agent_verify', function()
    local AgentVerify = require 'agent_verify'

    -- === Test PKI (built once) ===
    -- RSA-4096, the size of the production attestation keys (attest-prod-2 and
    -- the standby attest-prod-3), so the pure-Lua verifier is exercised at the
    -- size it meets on a controller.
    local rootKey = openssl.pkey.new('rsa', 4096)
    local rootPublicPem = rootKey:get_public():export('pem')

    local deviceKey = openssl.pkey.new('rsa', 2048)
    local deviceCertPem
    do
        local subject = openssl.x509.name.new({ { commonName = 'anvil-agent' } })
        local req = openssl.x509.req.new(subject, deviceKey)
        local cert = openssl.x509.new(1, req)
        cert:validat(os.time(), os.time() + 3600)
        cert:sign(deviceKey, cert)
        deviceCertPem = cert:export('pem')
    end
    local deviceFingerprint = openssl.digest.digest(
        'sha256', openssl.x509.read(deviceCertPem, 'pem'):export('der'), false):lower()

    -- An unrelated keypair for negative cases.
    local rogueKey = openssl.pkey.new('rsa', 2048)

    local function b64(data)
        return (openssl.base64(data, true):gsub('\n', ''))
    end

    local function b64url(data)
        return (b64(data):gsub('+', '-'):gsub('/', '_'):gsub('=', ''))
    end

    local function hexToBytes(hex)
        return (hex:lower():gsub('%x%x', function(byte)
            return string.char(tonumber(byte, 16))
        end))
    end

    -- The modulus and exponent, in the two shapes this spec needs: hex for the
    -- embedded root (how the build injects it) and base64url for a JWK (how
    -- the cloud attests the device key).
    local function keyHex(pkey)
        local rsa = pkey:parse().rsa:parse()
        return rsa.n:tohex():lower(), rsa.e:tohex():lower()
    end

    local function keyJwk(pkey)
        local n, e = keyHex(pkey)
        return { kty = 'RSA', n = b64url(hexToBytes(n)), e = b64url(hexToBytes(e)) }
    end

    local rootN, rootE = keyHex(rootKey)
    local TRUSTED_ROOT = { ['attest-test-1'] = { n = rootN, e = rootE } }

    -- Mint an attestation JWT signed by `key` (the root, unless a negative
    -- case says otherwise), with header `kid` (default the trusted test kid).
    local function mintAttestation(claims, key, kid)
        key = key or rootKey
        local header = b64url(cjson.encode({ typ = 'JWT', alg = 'RS256', kid = kid or 'attest-test-1' }))
        local body = b64url(cjson.encode(claims))
        local signature = key:sign(header .. '.' .. body, 'sha256')
        return header .. '.' .. body .. '.' .. b64url(signature)
    end

    local MAC = 'AA:BB:CC:DD:EE:FF'
    local NOW = os.time()

    local function goodClaims(overrides)
        local claims = {
            iss = 'https://driverforge.com',
            sub = MAC,
            certFingerprint = deviceFingerprint,
            -- RFC 7800 confirmation claim: the key the cloud attests. The
            -- fingerprint above is still emitted by the cloud but nothing in
            -- the SDK reads it any more.
            cnf = { jwk = keyJwk(deviceKey) },
            aud = 'driverforge-sdk',
            iat = NOW,
            exp = NOW + 3600,
        }
        for k, v in pairs(overrides or {}) do claims[k] = v end
        return claims
    end

    -- Build a full proof the way the agent does.
    local function mintProof(overrides, signingKey, attestation)
        local expected = {
            nonce = 'nonce-123', mac = MAC,
            agentDeviceId = '42', challengerDeviceId = '77',
        }
        local message = table.concat({
            'agent-verify-v1', expected.nonce, expected.mac,
            expected.agentDeviceId, expected.challengerDeviceId,
        }, '|')
        local proof = {
            protocol = 'agent-verify-v1',
            nonce = expected.nonce,
            attestation = attestation or mintAttestation(goodClaims()),
            certPem = deviceCertPem,
            signature = b64((signingKey or deviceKey):sign(message, 'sha256')),
            agentDeviceId = expected.agentDeviceId,
        }
        for k, v in pairs(overrides or {}) do proof[k] = v end
        expected.now = NOW
        return proof, expected
    end

    before_each(function()
        -- The trusted root, keyed by the kid the test attestations carry.
        AgentVerify.ROOT_PUBLIC_KEYS = TRUSTED_ROOT
        _G.C4 = {
            Base64Decode = function(_, s) return openssl.base64(s, false) end,
            JsonDecode = function(_, s) return cjson.decode(s) end,
            -- The only firmware call the verify path makes now.
            Hash = function(_, _, data, _)
                return openssl.digest.digest('sha256', data, false)
            end,
        }
    end)

    after_each(function()
        AgentVerify.ROOT_PUBLIC_KEYS = {}
        _G.C4 = nil
    end)

    it('is disabled until a root key is embedded', function()
        AgentVerify.ROOT_PUBLIC_KEYS = {}
        assert.is_false(AgentVerify.enabled())
        AgentVerify.ROOT_PUBLIC_KEYS = TRUSTED_ROOT
        assert.is_true(AgentVerify.enabled())
    end)

    it('rejects an attestation whose kid the SDK does not hold', function()
        local proof, expected = mintProof(nil, nil,
            mintAttestation(goodClaims(), rootKey, 'attest-unknown-9'))
        local ok, reason = AgentVerify.verifyProof(proof, expected)
        assert.is_nil(ok)
        assert.are.equal('attestation signed by an untrusted key', reason)
    end)

    it('rejects an attestation with a mismatched issuer', function()
        local proof, expected = mintProof(nil, nil,
            mintAttestation(goodClaims({ iss = 'https://evil.example' })))
        local ok, reason = AgentVerify.verifyProof(proof, expected)
        assert.is_nil(ok)
        assert.are.equal('attestation issuer mismatch', reason)
    end)

    it('no longer parses certificates at all', function()
        -- The attested key is the identity; the certificate the agent holds is
        -- a TLS identity for its deploy server and nothing here reads it.
        assert.is_nil(AgentVerify.certFingerprint)
    end)

    describe('verifyProof', function()
        it('accepts a genuine proof', function()
            local proof, expected = mintProof()
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_true(ok, reason)
        end)

        it('rejects an attestation signed by the wrong root', function()
            local proof, expected = mintProof(nil, nil, mintAttestation(goodClaims(), rogueKey))
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('attestation signature invalid', reason)
        end)

        it('rejects an expired attestation', function()
            local proof, expected = mintProof(nil, nil,
                mintAttestation(goodClaims({ exp = NOW - 10 })))
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('attestation expired', reason)
        end)

        it('rejects an attestation for a different audience', function()
            local proof, expected = mintProof(nil, nil,
                mintAttestation(goodClaims({ aud = 'somewhere-else' })))
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('attestation audience mismatch', reason)
        end)

        it('rejects an attestation for a different controller', function()
            local proof, expected = mintProof(nil, nil,
                mintAttestation(goodClaims({ sub = '11:22:33:44:55:66' })))
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('attestation is for a different controller', reason)
        end)

        it('rejects an attestation that names no confirmation key', function()
            local claims = goodClaims()
            claims.cnf = nil
            local proof, expected = mintProof(nil, nil, mintAttestation(claims))
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('attestation carries no confirmation key', reason)
        end)

        it('rejects a proof signed by a key the cloud did not attest', function()
            -- A genuine attestation for the real device key, but the impostor
            -- signs with its own: possession of the attested key is the test,
            -- and presenting a certificate proves nothing.
            local proof, expected = mintProof(nil, rogueKey)
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('challenge signature invalid', reason)
        end)

        it('rejects a proof bound to a different challenger (relay)', function()
            local proof, expected = mintProof()
            expected.challengerDeviceId = '999'  -- we are not who it was signed for
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('challenge signature invalid', reason)
        end)

        it('rejects a proof from a different device id', function()
            local proof, expected = mintProof({ agentDeviceId = '43' })
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('proof from a different device', reason)
        end)

        it('rejects an empty attestation (pre-issuance agent)', function()
            local proof, expected = mintProof({ attestation = '' })
            local ok, reason = AgentVerify.verifyProof(proof, expected)
            assert.is_nil(ok)
            assert.are.equal('missing attestation', reason)
        end)

        it('rejects a garbage proof without raising', function()
            assert.has_no.errors(function()
                assert.is_nil(AgentVerify.verifyProof(nil, {}))
                assert.is_nil(AgentVerify.verifyProof({}, {}))
                assert.is_nil(AgentVerify.verifyProof({
                    protocol = 'agent-verify-v1', certPem = 'not a pem',
                    signature = '!!', agentDeviceId = '42',
                    attestation = 'a.b.c',
                }, { agentDeviceId = '42', now = NOW, mac = MAC,
                     nonce = 'n', challengerDeviceId = '77' }))
            end)
        end)
    end)
end)
