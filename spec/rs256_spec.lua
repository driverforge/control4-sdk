local RS256 = require 'rs256'

-- Known-answer vectors, generated with openssl against a throwaway 2048-bit
-- key pair. Only public material is recorded here: the modulus, the public
-- exponent and a signature. The message is the classic pangram and the digest
-- is its SHA-256, so the whole vector can be regenerated with:
--
--   printf 'The quick brown fox jumps over the lazy dog' > msg.txt
--   openssl dgst -sha256 -sign key.pem -out msg.sig msg.txt
--   openssl rsa -in key.pem -noout -modulus
--
-- Two exponents are covered: 65537, which everything issues in practice, and
-- 3, which exercises the short square-and-multiply path.
local DIGEST = 'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592'

local E65537 = {
    e = 65537,
    n = table.concat({
        'ac22595d7bf9e0adbf57285020df2e155b262c1e1ecb4b58fab077a38f323c9f9e0671dc',
        'c58707fe231ae83221b969601a0f92bf30216fd59e809ce89524cd63cf48effb124dbe0b',
        'ced8904ec45230fb5eedda27d1bdc022e8bddb8ab3b92473e0c800879f07a8166cfdfa87',
        '243a0c6a71971f3acf1b53c36baeb9c77bb50a495315cba336f8f119315aeb104955ea34',
        '6353b842a417a71732f1ee7e95df67cf41de92ec1bae118fa88262721b271c0e02666189',
        '2380fb3a5c29bf13c57d15b451d1cecacef6a0db896cc1ba1b8e26807e6965164a17d13d',
        'e533de0a12c7d9410157e9e197d4f450c0e2b42fe2b680f69c5b8a9bac041e1e7d4c5fb9',
        '5c9ee61b',
    }),
    sig = table.concat({
        '89570b495600de3335b96e1b9285ed5d320f74cd1ac4e25200459e3b02eb666819dc4152',
        'dd6a68efe09af5397dda4fde2ee1d5fb616370a4514315c2b077b30d38927cd0064408fe',
        '5ea6fb90fd9101c5b42a41df2d3b07053fe1345ccee25b66c864f52667abce40c181195d',
        'cf04a6a88ed30f1d496f9327774abecc400e29a8bb2bedaf8bce944bb50264658d2e69c8',
        '38f560e32e7f654d888b9ef655ae6fadc37401dd5ba34a4b245fa878745df5a573bf51f6',
        '27f3f9b9bd18ec9ca9abf6a7b4fcefdb46a0fa77d1ddb8b2293af9f072449f7caa958f78',
        'ea9d3c3ff29b99bc43770a75def6917b2212e17d17e33203b346c99af6433551bed236cf',
        'c855716d',
    }),
}

local E3 = {
    e = 3,
    n = table.concat({
        'adf06b08ef6f6227d325b65ed20dc319fa2574c61b717f2b9428050775f95cb4f53ec202',
        '72184c7db54fd88fe2f630b25526d2768f97565b7c21f54949146fea79bc30e4e13989b3',
        '91c8e1acf2e01fe9581cb3ebc230d784e27cfc860f275a5f240cdb76433487de93ad31d8',
        '755a0008b8e39a17f692e277f14230e382a2f93b83cfb55f786efc9029cb2d8a6a6e8e07',
        '2ea628b5624d1701f3870d2eebc2edffc3dcf3f14e6afd03ae100007250630dd91739cdc',
        '705831709c1150c474d54e0e875134451fb7a5185ff13ffbeeebf29637e20f14212bf020',
        '56494db39e5288952097d8415d3de102dfb50db322c5fdb025feb023c673f010d9c5e71b',
        'bb5c5ad3',
    }),
    sig = table.concat({
        '0105a0c76c2c0897aa30266d7daf5dd1fcc10095ffce0052d1dcab4ba9ac864f013191c2',
        '807f925eb27e339155feeffb0d9385ad85b81f8b5a17a36495eb6aa1f8a84b86131646eb',
        'b8c2fc5190f80048835425b4b4c50047867f5a2cd183d6d365305c3b6042d5505392f2ba',
        'afcb19c5c15e6ae9115f038dc21cc985a5c48c5c2b5d08dbaa62d2d24dbe78ced53f9cf0',
        '83ac64a536da026aee3add3907eabbe0215f8de6b35d9972ec6019477a19cb4e4b0b71df',
        'a335d0e6162d1e2db8b73bc78918bb594f7d3c0eb17ecb6c7ca45ad37835b9d240896aae',
        '1707fca56396a8bffeba95429446ecb9d9af5037e15241924795f2b48a36ab9b8451d71b',
        'c314e0b6',
    }),
}

local h = RS256.hexToBytes

describe('rs256', function()
    describe('valid signatures', function()
        it('verifies an e=65537 signature', function()
            assert.is_true(RS256.verify(DIGEST, h(E65537.sig), h(E65537.n), E65537.e))
        end)

        it('verifies an e=3 signature', function()
            assert.is_true(RS256.verify(DIGEST, h(E3.sig), h(E3.n), E3.e))
        end)

        it('accepts the digest as raw bytes as well as hex', function()
            assert.is_true(RS256.verify(h(DIGEST), h(E65537.sig), h(E65537.n), E65537.e))
        end)

        it('accepts the exponent as bytes, the shape a JWK carries', function()
            -- 65537 big-endian, i.e. base64url "AQAB" decoded.
            assert.is_true(
                RS256.verify(DIGEST, h(E65537.sig), h(E65537.n), '\1\0\1'))
        end)
    end)

    describe('rejections', function()
        -- Every one of these must be a clean false, never a throw: the inputs
        -- arrive from another device on the controller and cannot be trusted
        -- to be well formed.
        local function rejects(reason, digest, signature, modulus, exponent)
            local ok, why = RS256.verify(digest, signature, modulus, exponent)
            assert.is_false(ok)
            assert.are.equal(reason, why)
        end

        it('rejects a signature with one bit flipped', function()
            local sig = h(E65537.sig)
            local flipped = sig:sub(1, 99)
                .. string.char((string.byte(sig, 100) + 1) % 256)
                .. sig:sub(101)
            rejects('signature does not verify', DIGEST, flipped, h(E65537.n), E65537.e)
        end)

        it('rejects a signature over a different digest', function()
            rejects('signature does not verify',
                string.rep('ab', 32), h(E65537.sig), h(E65537.n), E65537.e)
        end)

        it('rejects a signature checked against the wrong exponent', function()
            rejects('signature does not verify', DIGEST, h(E65537.sig), h(E65537.n), 3)
        end)

        it('rejects a signature checked against the wrong key', function()
            rejects('signature does not verify', DIGEST, h(E65537.sig), h(E3.n), E65537.e)
        end)

        it('rejects a signature that is not the modulus length', function()
            rejects('signature length mismatch',
                DIGEST, h(E65537.sig):sub(2), h(E65537.n), E65537.e)
        end)

        it('rejects a signature that is not less than the modulus', function()
            rejects('signature out of range',
                DIGEST, h(E65537.n), h(E65537.n), E65537.e)
        end)

        it('rejects an even modulus', function()
            local n = h(E65537.n)
            rejects('even modulus',
                DIGEST, h(E65537.sig), n:sub(1, #n - 1) .. '\0', E65537.e)
        end)

        it('rejects an even exponent', function()
            rejects('unsupported exponent', DIGEST, h(E65537.sig), h(E65537.n), 4)
        end)

        it('rejects an exponent of 1', function()
            rejects('unsupported exponent', DIGEST, h(E65537.sig), h(E65537.n), 1)
        end)

        it('rejects a digest that is not sha-256 length', function()
            rejects('digest is not sha-256', 'abcd', h(E65537.sig), h(E65537.n), E65537.e)
        end)

        it('rejects non-string input rather than throwing', function()
            rejects('malformed input', nil, h(E65537.sig), h(E65537.n), E65537.e)
            rejects('malformed input', DIGEST, nil, h(E65537.n), E65537.e)
            rejects('malformed input', DIGEST, h(E65537.sig), nil, E65537.e)
        end)
    end)
end)
