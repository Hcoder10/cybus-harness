--!native
--!strict
-- TexCodec: decodes the texture data the harness writes (harness/tools/texpack.py) into RGBA8 pixel buffers.
-- Pure Luau (standard library and buffer only), so it runs in the game and under the standalone Luau runtime.
--   local pixels = TexCodec.decode(data, 64, 64, "RGBA")   -- buffer of 64 * 64 * 4 bytes, rows top to bottom
--   TexCodec.checksum(pixels) == entry.checksum             -- Adler-32; a mismatch means corrupted data
-- LA textures decode to RGBA with R = G = B = L. decode() errors on data it cannot read; callers pcall it.
-- Format: base85 text -> bytes; an 8-byte header; a 2-bit predictor per row per plane; canonical Huffman codes
-- (at most 12 bits, LSB first) over residual bytes and zero runs; planes alpha first, then R, G, B (or L).

local TexCodec = {}

local ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"
local VERSION = 1
local MAX_BITS = 12
local TABLE_SIZE = 4096
local RUN_BASE = 256

-- base85 character -> digit (255 for characters outside the alphabet)
local DIGIT = buffer.create(256)
buffer.fill(DIGIT, 0, 255)
for i = 1, #ALPHABET do
	buffer.writeu8(DIGIT, string.byte(ALPHABET, i), i - 1)
end

-- zigzag symbol -> residual byte: 0, 1, 2, 3, 4, ... -> 0, -1, 1, -2, 2, ... (mod 256)
local UNZIG = buffer.create(256)
for z = 0, 255 do
	buffer.writeu8(UNZIG, z, if z % 2 == 0 then z // 2 else 255 - z // 2)
end

local function fail(message: string): never
	error("TexCodec: " .. message, 0)
end

local function unbase85(text: string): buffer
	local n = #text
	if n == 0 or n % 5 ~= 0 then
		fail("data length is not a multiple of 5")
	end
	local src = buffer.fromstring(text)
	local out = buffer.create(n // 5 * 4)
	local o = 0
	for i = 0, n - 1, 5 do
		local d0 = buffer.readu8(DIGIT, buffer.readu8(src, i))
		local d1 = buffer.readu8(DIGIT, buffer.readu8(src, i + 1))
		local d2 = buffer.readu8(DIGIT, buffer.readu8(src, i + 2))
		local d3 = buffer.readu8(DIGIT, buffer.readu8(src, i + 3))
		local d4 = buffer.readu8(DIGIT, buffer.readu8(src, i + 4))
		if d0 > 84 or d1 > 84 or d2 > 84 or d3 > 84 or d4 > 84 then
			fail("data has a character outside the alphabet")
		end
		local v = (((d0 * 85 + d1) * 85 + d2) * 85 + d3) * 85 + d4
		if v > 4294967295 then
			fail("data group out of range")
		end
		buffer.writeu32(out, o, v)
		o += 4
	end
	return out
end

local function reverseBits(code: number, bits: number): number
	local r = 0
	for _ = 1, bits do
		r = r * 2 + bit32.band(code, 1)
		code = bit32.rshift(code, 1)
	end
	return r
end

-- Decode table: 12 peeked bits -> value * 16 + code length. value < 256 is a residual byte, 256 + k a zero run.
local function buildTable(src: buffer, at: number, nlit: number, nrun: number): buffer
	local nsym = nlit + nrun
	local lengths = table.create(nsym, 0)
	local count = table.create(MAX_BITS, 0)
	for i = 0, nsym - 1 do
		local len = bit32.extract(buffer.readu8(src, at + bit32.rshift(i, 1)), bit32.band(i, 1) * 4, 4)
		if len > MAX_BITS then
			fail("bad code length")
		end
		lengths[i + 1] = len
		if len > 0 then
			count[len] += 1
		end
	end
	local nextCode = table.create(MAX_BITS, 0)
	local code = 0
	for bits = 1, MAX_BITS do
		code = (code + (if bits > 1 then count[bits - 1] else 0)) * 2
		nextCode[bits] = code
	end
	local tbl = buffer.create(TABLE_SIZE * 2)
	for i = 0, nsym - 1 do
		local len = lengths[i + 1]
		if len > 0 then
			local c = nextCode[len]
			nextCode[len] = c + 1
			if c >= bit32.lshift(1, len) then
				fail("bad code lengths")
			end
			local value = if i < nlit then buffer.readu8(UNZIG, i) else RUN_BASE + (i - nlit)
			local entry = value * 16 + len
			for j = reverseBits(c, len), TABLE_SIZE - 1, bit32.lshift(1, len) do
				buffer.writeu16(tbl, j * 2, entry)
			end
		end
	end
	return tbl
end

-- Huffman stream -> residual bytes of every plane (zero runs are skipped: buffers start zeroed).
local function inflate(src: buffer, bitPos: number, tbl: buffer, n: number): buffer
	local res = buffer.create(n)
	local o = 0
	local bp = bitPos
	while o < n do
		local e = buffer.readu16(tbl, bit32.extract(buffer.readu32(src, bit32.rshift(bp, 3)), bit32.band(bp, 7), MAX_BITS) * 2)
		local len = bit32.band(e, 15)
		if len == 0 then
			fail("corrupt bitstream")
		end
		bp += len
		local v = bit32.rshift(e, 4)
		if v < RUN_BASE then
			buffer.writeu8(res, o, v)
			o += 1
		else
			local k = v - RUN_BASE
			if k >= 2 then
				local eb = k - 1
				o += bit32.lshift(1, eb) + bit32.extract(buffer.readu32(src, bit32.rshift(bp, 3)), bit32.band(bp, 7), eb) + 2
				bp += eb
			else
				o += k + 2
			end
		end
	end
	if o ~= n then
		fail("corrupt bitstream (a run goes past the end)")
	end
	return res
end

-- Undo each row's predictor, writing the plane into channel `ch` of the RGBA output.
local function unfilter(src: buffer, flagsAt: number, res: buffer, out: buffer, w: number, h: number, plane: number, ch: number)
	local stride = w * 4
	local zeroRow = buffer.create(stride)
	for y = 0, h - 1 do
		local row = plane * h + y
		local f = bit32.extract(buffer.readu8(src, flagsAt + bit32.rshift(row, 2)), bit32.band(row, 3) * 2, 2)
		local r = row * w
		local q = y * stride + ch
		local up, u = out, q - stride
		if y == 0 then
			up, u = zeroRow, ch
		end
		if f == 0 then -- left
			local a = 0
			for x = r, r + w - 1 do
				a = bit32.band(a + buffer.readu8(res, x), 255)
				buffer.writeu8(out, q, a)
				q += 4
			end
		elseif f == 1 then -- up
			for x = r, r + w - 1 do
				buffer.writeu8(out, q, bit32.band(buffer.readu8(up, u) + buffer.readu8(res, x), 255))
				q += 4
				u += 4
			end
		elseif f == 2 then -- average of left and up
			local a = 0
			for x = r, r + w - 1 do
				a = bit32.band(bit32.rshift(a + buffer.readu8(up, u), 1) + buffer.readu8(res, x), 255)
				buffer.writeu8(out, q, a)
				q += 4
				u += 4
			end
		else -- gradient: left + up - up-left, clamped
			local a, c = 0, 0
			for x = r, r + w - 1 do
				local b = buffer.readu8(up, u)
				local p = a + b - c
				if p < 0 then
					p = 0
				elseif p > 255 then
					p = 255
				end
				a = bit32.band(p + buffer.readu8(res, x), 255)
				buffer.writeu8(out, q, a)
				c = b
				q += 4
				u += 4
			end
		end
	end
end

-- decode(data, w, h, fmt) -> buffer of w * h * 4 bytes (RGBA8). fmt is "RGBA" or "LA" (from the texture index).
function TexCodec.decode(data: string, w: number, h: number, fmt: string): buffer
	local channels = if fmt == "RGBA" then 4 elseif fmt == "LA" then 2 else fail("unknown format " .. tostring(fmt))
	local src = unbase85(data)
	if buffer.len(src) < 12 then
		fail("data too short")
	end
	if buffer.readu8(src, 0) ~= VERSION then
		fail("unsupported version " .. buffer.readu8(src, 0))
	end
	if buffer.readu8(src, 1) ~= channels or buffer.readu16(src, 2) ~= w or buffer.readu16(src, 4) ~= h then
		fail("data does not match its size or format")
	end
	local nlit = buffer.readu8(src, 6) + 1
	local nrun = buffer.readu8(src, 7)
	local flagsAt = 8
	local lengthsAt = flagsAt + (h * channels + 3) // 4
	local bitPos = (lengthsAt + (nlit + nrun + 1) // 2) * 8
	if bitPos // 8 + 4 > buffer.len(src) then
		fail("data too short")
	end
	local tbl = buildTable(src, lengthsAt, nlit, nrun)
	local res = inflate(src, bitPos, tbl, w * h * channels)
	local out = buffer.create(w * h * 4)
	if channels == 4 then
		unfilter(src, flagsAt, res, out, w, h, 0, 3)
		unfilter(src, flagsAt, res, out, w, h, 1, 0)
		unfilter(src, flagsAt, res, out, w, h, 2, 1)
		unfilter(src, flagsAt, res, out, w, h, 3, 2)
	else
		unfilter(src, flagsAt, res, out, w, h, 0, 3)
		unfilter(src, flagsAt, res, out, w, h, 1, 0)
		for i = 0, w * h * 4 - 1, 4 do
			local l = buffer.readu8(out, i)
			buffer.writeu8(out, i + 1, l)
			buffer.writeu8(out, i + 2, l)
		end
	end
	return out
end

-- Adler-32 of a buffer's bytes (the index stores it for the decoded RGBA8 pixels).
function TexCodec.checksum(buf: buffer): number
	local n = buffer.len(buf)
	local a, b = 1, 0
	local i = 0
	while i < n do
		local stop = math.min(n, i + 1048576) -- reduce every MiB so the sums stay exact
		for j = i, stop - 1 do
			a += buffer.readu8(buf, j)
			b += a
		end
		a %= 65521
		b %= 65521
		i = stop
	end
	return b * 65536 + a
end

return TexCodec
