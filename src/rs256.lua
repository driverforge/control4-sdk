-- RS256 signature verification in pure Lua.
--
-- The Control4 firmware exposes signing, hashing, HMAC and CSR generation, but
-- no signature *verification* primitive at any OS version — the only way to
-- verify is the lua-openssl binding, which arrives in 3.4.1. Verification is
-- the one operation this codebase cannot do without, so this module supplies
-- it and keeps the runtime floor where the rest of the code puts it.
--
-- Scope: RSASSA-PKCS1-v1_5 with SHA-256, public key only. Verification uses
-- nothing secret — the key, the signature and the message are all public — so
-- there is no timing side channel to defend and no key material to protect.
-- The failure mode is a rejected signature, never a leak.
--
-- Deliberately has NO dependency on C4: callers pass in the SHA-256 digest
-- they computed (both consumers already have C4:Hash, available since 1.6.0).
-- That keeps this file testable as plain Lua and portable between the SDK and
-- the agent.
--
-- Arithmetic: little-endian limbs in base 2^24, so a limb product plus carries
-- stays under 2^53 and every intermediate is an exact double on a 5.1 runtime.
-- Modular exponentiation is Montgomery (CIOS), which needs no division; the
-- whole verification is ~600k limb operations, paid once per exchange.

local M = {}

local BITS = 24
local BASE = 2 ^ BITS
local MASK = BASE - 1

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

-- Big-endian byte string -> limb array (little-endian, base 2^24).
local function fromBytes(s)
    local limbs, acc, bits, i = {}, 0, 0, #s
    while i >= 1 do
        acc = acc + string.byte(s, i) * (2 ^ bits)
        bits = bits + 8
        i = i - 1
        if bits >= BITS then
            limbs[#limbs + 1] = acc % BASE
            acc = floor(acc / BASE)
            bits = bits - BITS
        end
    end
    if acc > 0 or #limbs == 0 then limbs[#limbs + 1] = acc end
    return limbs
end

-- Limb array -> big-endian byte string of exactly `len` bytes.
local function toBytes(a, len)
    local out, acc, bits, idx = {}, 0, 0, 1
    for i = 1, len do out[i] = "\0" end
    local pos = len
    while pos >= 1 do
        if bits < 8 then
            acc = acc + (a[idx] or 0) * (2 ^ bits)
            bits = bits + BITS
            idx = idx + 1
        end
        out[pos] = string.char(acc % 256)
        acc = floor(acc / 256)
        bits = bits - 8
        pos = pos - 1
    end
    return table.concat(out)
end

local function hexToBytes(hex)
    return (hex:gsub("%x%x", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

-- ---------------------------------------------------------------------------
-- Limb arithmetic
-- ---------------------------------------------------------------------------

local function trim(a)
    while #a > 1 and a[#a] == 0 do a[#a] = nil end
    return a
end

-- -1, 0, 1 for a < b, a == b, a > b.
local function cmp(a, b, n)
    for i = n, 1, -1 do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

-- a = a - b, assuming a >= b. In place.
local function subInPlace(a, b, n)
    local borrow = 0
    for i = 1, n do
        local d = (a[i] or 0) - (b[i] or 0) - borrow
        if d < 0 then
            d = d + BASE
            borrow = 1
        else
            borrow = 0
        end
        a[i] = d
    end
    return a
end

-- a = (a + a) mod m, for a < m. In place.
local function doubleMod(a, m, n)
    local carry = 0
    for i = 1, n do
        local v = (a[i] or 0) * 2 + carry
        a[i] = v % BASE
        carry = floor(v / BASE)
    end
    -- A carry out means the value exceeded the limb window, so it is
    -- unconditionally >= m; otherwise compare.
    if carry > 0 or cmp(a, m, n) >= 0 then subInPlace(a, m, n) end
    return a
end

-- -n[1]^-1 mod 2^24, by Newton iteration (doubles the correct bit count each
-- round, so five rounds cover 24 bits).
local function montInverse(n0)
    local inv = 1
    for _ = 1, 5 do
        inv = (inv * ((2 - n0 * inv) % BASE)) % BASE
    end
    return (BASE - inv) % BASE
end

-- ---------------------------------------------------------------------------
-- Montgomery domain
-- ---------------------------------------------------------------------------

local Mont = {}
Mont.__index = Mont

-- Montgomery product: a * b * R^-1 mod n, where R = 2^(24k). CIOS form —
-- interleaves multiplication and reduction, so no intermediate ever exceeds
-- 2k+1 limbs and no division is needed.
function Mont:mul(a, b)
    local n, k, n0inv = self.n, self.k, self.n0inv
    local t = self.scratch
    for i = 1, k + 2 do t[i] = 0 end

    for i = 1, k do
        local bi = b[i] or 0
        local c = 0
        for j = 1, k do
            local v = t[j] + (a[j] or 0) * bi + c
            t[j] = v % BASE
            c = floor(v / BASE)
        end
        local v = t[k + 1] + c
        t[k + 1] = v % BASE
        t[k + 2] = floor(v / BASE)

        local m = (t[1] * n0inv) % BASE
        c = floor((t[1] + m * n[1]) / BASE)
        for j = 2, k do
            local w = t[j] + m * n[j] + c
            t[j - 1] = w % BASE
            c = floor(w / BASE)
        end
        local w = t[k + 1] + c
        t[k] = w % BASE
        t[k + 1] = t[k + 2] + floor(w / BASE)
    end

    local out = {}
    for i = 1, k do out[i] = t[i] end
    if t[k + 1] > 0 or cmp(out, n, k) >= 0 then subInPlace(out, n, k) end
    return out
end

-- x^e mod n for a small positive integer exponent, via square-and-multiply
-- over the Montgomery domain.
function Mont:powSmall(x, e)
    local k = self.k

    -- Into the domain: x * R mod n == montMul(x, R^2 mod n).
    local base = self:mul(x, self.rr)

    -- 1 in the domain is R mod n.
    local result = {}
    for i = 1, k do result[i] = self.r[i] or 0 end

    -- Walk the exponent from its top bit down.
    local bit = 1
    while bit * 2 <= e do bit = bit * 2 end
    while bit >= 1 do
        result = self:mul(result, result)
        if e % (bit * 2) >= bit then
            result = self:mul(result, base)
        end
        bit = floor(bit / 2)
    end

    -- Out of the domain.
    local one = { 1 }
    for i = 2, k do one[i] = 0 end
    return self:mul(result, one)
end

-- n must be odd, which every RSA modulus is.
local function newMont(nBytes)
    local n = fromBytes(nBytes)
    trim(n)
    local k = #n
    if n[1] % 2 == 0 then return nil, "even modulus" end
    if k < 2 then return nil, "modulus too small" end

    local self = setmetatable({
        n = n,
        k = k,
        n0inv = montInverse(n[1]),
        scratch = {},
    }, Mont)

    -- R = 2^(24k) and R^2, both mod n, by repeated doubling from 1. The
    -- tempting shortcut R mod n = R - n only holds when n occupies the whole
    -- limb window; a 2048-bit modulus does not, because 2048 is not a multiple
    -- of 24. Doubling costs ~2 * 24k passes over k limbs and is paid once per
    -- verification, which is cheaper than getting the special case wrong.
    local r = { 1 }
    for i = 2, k do r[i] = 0 end
    for _ = 1, k * BITS do doubleMod(r, n, k) end
    self.r = r

    local rr = {}
    for i = 1, k do rr[i] = r[i] end
    for _ = 1, k * BITS do doubleMod(rr, n, k) end
    self.rr = rr

    return self
end

-- ---------------------------------------------------------------------------
-- PKCS#1 v1.5
-- ---------------------------------------------------------------------------

-- DigestInfo prefix for SHA-256 (RFC 8017 A.2.4), followed by the 32-byte hash.
local SHA256_PREFIX = hexToBytes("3031300d060960864801650304020105000420")

-- EM = 0x00 || 0x01 || 0xFF... || 0x00 || DigestInfo || H
local function encode(digest, emLen)
    local tail = SHA256_PREFIX .. digest
    local padding = emLen - #tail - 3
    if padding < 8 then return nil end
    return "\0\1" .. string.rep("\255", padding) .. "\0" .. tail
end

-- ---------------------------------------------------------------------------
-- Public surface
-- ---------------------------------------------------------------------------

M.hexToBytes = hexToBytes

-- Verify an RSASSA-PKCS1-v1_5 / SHA-256 signature.
--
--   digest    the SHA-256 of the signed message: 32 raw bytes, or 64 hex chars
--   signature raw signature bytes, exactly as long as the modulus
--   modulus   raw modulus bytes, big-endian (the JWK `n`, base64url-decoded)
--   exponent  the public exponent as a number, or raw bytes (the JWK `e`)
--
-- Returns true on a good signature, or false plus a reason. Every failure path
-- is a rejection: this never throws on malformed input.
function M.verify(digest, signature, modulus, exponent)
    if type(digest) ~= "string" or type(signature) ~= "string"
        or type(modulus) ~= "string" then
        return false, "malformed input"
    end

    if #digest == 64 and digest:match("^%x+$") then
        digest = hexToBytes(digest)
    end
    if #digest ~= 32 then return false, "digest is not sha-256" end

    -- A signature must be exactly the modulus length; anything else is
    -- malformed rather than merely wrong.
    if #signature ~= #modulus then return false, "signature length mismatch" end

    local e = exponent
    if type(e) == "string" then
        e = 0
        for i = 1, #exponent do
            e = e * 256 + string.byte(exponent, i)
        end
    end
    if type(e) ~= "number" or e < 3 or e % 2 ~= 1 or e > 2 ^ 32 then
        return false, "unsupported exponent"
    end

    local mont, why = newMont(modulus)
    if not mont then return false, why end

    local s = fromBytes(signature)
    for i = #s + 1, mont.k do s[i] = 0 end
    -- s must be strictly less than the modulus.
    if cmp(s, mont.n, mont.k) >= 0 then return false, "signature out of range" end

    local ok, m = pcall(function() return mont:powSmall(s, e) end)
    if not ok then return false, "modular exponentiation failed" end

    local expected = encode(digest, #modulus)
    if not expected then return false, "modulus too small" end

    if toBytes(m, #modulus) ~= expected then
        return false, "signature does not verify"
    end
    return true
end

return M
