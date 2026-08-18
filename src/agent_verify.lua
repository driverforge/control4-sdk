-- Agent identity verification for the SDK↔agent handshake.
--
-- The SDK discovers the agent by driver filename, which any co-installed
-- driver can imitate on a controller where the real agent (a Composer
-- singleton) is absent. Before sending telemetry, the SDK challenges the
-- discovered device; only the real agent can answer, because the proof is
-- signed with the per-controller device key that the cloud attested at device
-- registration and names in the attestation's confirmation claim.
--
-- Everything verifies OFFLINE against ROOT_PUBLIC_KEY below — the SDK
-- makes no network calls. This module holds the pure verification
-- primitives; the challenge state machine lives in anvil.lua.
--
-- Signature checking is pure Lua (see the rs256 module), so nothing here needs
-- the firmware's openssl binding and the SDK runs on any controller that can
-- hash. Certificates are not parsed at all: the attested key is the identity.

local RS256 = require 'rs256'
local hexToBytes = RS256.hexToBytes

local M = {}

-- Attestation root PUBLIC keys, keyed by the attestation JWT's `kid`, each a
-- table of the RSA modulus and exponent as lowercase hex:
--
--     { ["attest-prod-1"] = { n = "ac22…", e = "010001" } }
--
-- Empty in committed source; the build injects the target's key(s) at the
-- marker below — prod keys from sdk/keys/** (which mirror to the OSS repo),
-- the dev key from the out-of-tree dev-keys/** (which never mirrors). These
-- are PUBLIC keys only; there is nothing secret in this file or its build
-- output. Hex rather than PEM because the verifier wants the raw integers and
-- nothing here parses ASN.1.
--
-- Embedding a key is the enforcement flip: while the map is empty,
-- verification is disabled and agent discovery trusts the filename match
-- (the legacy behaviour). A kid-keyed map (rather than a single key) lets a
-- rotation embed several prod keys at once, each selected by the kid the
-- cloud stamps in the JWT header.
M.ROOT_PUBLIC_KEYS = {} --[[SDK_ATTESTATION_KEYS]]

M.PROTOCOL = "agent-verify-v1"
M.CHALLENGE_COMMAND = "AGENT_VERIFY"
M.PROOF_COMMAND = "AGENT_VERIFY_PROOF"
-- The agent's unsolicited "I can answer now" announcement, sent to every
-- challenger it could not satisfy. It carries no authority whatsoever: all it
-- does is prompt this SDK to re-run discovery and challenge again, and that
-- challenge still demands a real attestation from whatever answers. A spoofed
-- announcement therefore buys an attacker one wasted round trip, not trust.
M.READY_COMMAND = "AGENT_READY"
M.EXPECTED_ISSUER = "https://driverforge.com"
M.EXPECTED_AUDIENCE = "driverforge-sdk"
M.TIMEOUT_MS = 10000

-- Backstop retry ladder for a driver latched off by a failed verification.
-- The announcement above is the primary recovery path, but it travels the same
-- fire-and-forget SendToDevice channel as everything else and fails silently;
-- recovery must not hinge on one unacknowledged message. The common cause of a
-- latch is an agent that was installed but has not yet finished its interactive
-- login + registration, so the ladder is spaced to cover the minutes that takes
-- (~15 min in total) and then stops. Bounded, because a genuine impostor must
-- still end up terminally refused rather than challenged forever.
M.RETRY_DELAYS_MS = { 30000, 60000, 120000, 240000, 480000 }

-- Cap on announcement-triggered recovery attempts. One real agent readiness
-- produces one announcement, so this is generous for the honest case while
-- keeping a peer driver that spams the command from making this SDK re-challenge
-- indefinitely.
M.MAX_ANNOUNCE_RETRIES = 10

-- Verification is enabled by embedding at least one root key.
function M.enabled()
    return next(M.ROOT_PUBLIC_KEYS) ~= nil
end

-- Signature verification is pure Lua; the only firmware call the verify path
-- makes is C4:Hash, which has been there since long before anything else this
-- SDK touches. Kept as a probe because the caller fails closed on it, and a
-- runtime that somehow cannot hash cannot be trusted to verify either.
function M.available()
    local ok, hash = pcall(function() return C4 and C4.Hash end)
    return ok and hash ~= nil
end

-- SHA-256 of the signing input, lowercase hex, which is what the verifier
-- consumes. nil if the runtime cannot hash.
local function sha256Hex(data)
    local ok, digest = pcall(function()
        return C4:Hash('SHA256', data, { return_encoding = 'HEX', data_encoding = 'NONE' })
    end)
    if ok and type(digest) == "string" and #digest == 64 then
        return digest:lower()
    end
    return nil
end

local function b64urlDecode(input)
    local remainder = #input % 4
    if remainder > 0 then
        input = input .. string.rep('=', 4 - remainder)
    end
    input = input:gsub('-', '+'):gsub('_', '/')
    return C4:Base64Decode(input)
end

-- Verify the cloud-signed attestation JWT against the embedded root.
-- Returns the claims table, or nil + reason.
function M.verifyAttestation(jwt, expectedMac, now)
    if type(jwt) ~= "string" or jwt == "" then return nil, "missing attestation" end

    local headerB64, claimsB64, sigB64 = jwt:match("^([^%.]+)%.([^%.]+)%.([^%.]+)$")
    if not headerB64 then return nil, "malformed attestation" end

    local decoded, header, claims, signature = pcall(function()
        return C4:JsonDecode(b64urlDecode(headerB64)),
            C4:JsonDecode(b64urlDecode(claimsB64)),
            b64urlDecode(sigB64)
    end)
    if not decoded or type(header) ~= "table" or type(claims) ~= "table" then
        return nil, "undecodable attestation"
    end
    if header.alg ~= "RS256" then return nil, "unexpected attestation algorithm" end

    -- Select the signing key by kid. An unknown (or missing) kid means the
    -- SDK does not hold the key that signed this — reject, never fall through
    -- to some default key.
    local root = type(header.kid) == "string" and M.ROOT_PUBLIC_KEYS[header.kid] or nil
    if type(root) ~= "table" then return nil, "attestation signed by an untrusted key" end

    local digest = sha256Hex(headerB64 .. "." .. claimsB64)
    if not digest then return nil, "runtime cannot hash" end
    if not RS256.verify(digest, signature, hexToBytes(root.n), hexToBytes(root.e)) then
        return nil, "attestation signature invalid"
    end

    if claims.iss ~= M.EXPECTED_ISSUER then return nil, "attestation issuer mismatch" end
    if claims.aud ~= M.EXPECTED_AUDIENCE then return nil, "attestation audience mismatch" end
    if type(claims.exp) ~= "number" or now >= claims.exp then return nil, "attestation expired" end
    if expectedMac == nil or claims.sub ~= expectedMac then
        return nil, "attestation is for a different controller"
    end

    -- The attested key itself, per RFC 7800. Binding the key rather than a
    -- certificate fingerprint is what lets this SDK check the challenge
    -- without parsing X.509 — the certificate the agent holds is now only a
    -- TLS identity for its deploy server, and nothing here looks at it.
    local jwk = type(claims.cnf) == "table" and claims.cnf.jwk or nil
    if type(jwk) ~= "table" or jwk.kty ~= "RSA"
        or type(jwk.n) ~= "string" or type(jwk.e) ~= "string" then
        return nil, "attestation carries no confirmation key"
    end

    return claims
end

-- Verify the challenge signature against the key the cloud attested.
local function verifyChallengeSignature(jwk, message, signatureB64)
    local digest = sha256Hex(message)
    if not digest then return false end
    local ok, valid = pcall(function()
        return RS256.verify(digest, C4:Base64Decode(signatureB64),
            b64urlDecode(jwk.n), b64urlDecode(jwk.e)) == true
    end)
    return ok and valid == true
end

-- Full proof check. `proof` is the agent's reply; `expected` carries what
-- this SDK knows independently: the nonce it minted, the local controller
-- MAC, the device id it challenged, its own device id, and the current
-- time. Returns true, or nil + reason.
function M.verifyProof(proof, expected)
    if type(proof) ~= "table" then return nil, "malformed proof" end
    if proof.protocol ~= M.PROTOCOL then return nil, "protocol mismatch" end
    if type(proof.signature) ~= "string" or proof.signature == "" then
        return nil, "proof carries no signature"
    end
    -- The responding device must be the one this SDK challenged.
    if proof.agentDeviceId ~= expected.agentDeviceId then
        return nil, "proof from a different device"
    end

    local claims, reason = M.verifyAttestation(proof.attestation, expected.mac, expected.now)
    if not claims then return nil, reason end

    -- The challenge must be signed by the attested key, over the
    -- domain-separated message binding nonce, controller, and both device
    -- ids (no replay, no cross-controller relay, bound to this discovery).
    local message = table.concat({
        M.PROTOCOL, expected.nonce, expected.mac,
        expected.agentDeviceId, expected.challengerDeviceId,
    }, "|")
    if not verifyChallengeSignature(claims.cnf.jwk, message, proof.signature) then
        return nil, "challenge signature invalid"
    end

    return true
end

return M
