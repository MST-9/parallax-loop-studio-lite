-- Parallax Loop Studio -- pure-Lua core (no Aseprite API). Images: { w, h, d } with d[y*w+x+1], 0 = transparent.
local S = {}

function S.new(w, h) local d = {} for i = 1, w * h do d[i] = 0 end return { w = w, h = h, d = d } end
function S.get(im, x, y) return im.d[y * im.w + x + 1] end
function S.set(im, x, y, v) im.d[y * im.w + x + 1] = v end

local function gcd(a, b) a, b = math.abs(a), math.abs(b) while b ~= 0 do a, b = b, a % b end return a end
S.gcd = gcd
local CAP = 1000000
local function lcm(a, b) if a > CAP or b > CAP then return CAP + 1 end local r = a // gcd(a, b) * b if r > CAP then return CAP + 1 end return r end
S.lcm = lcm

-- Wrap shift along an axis: out(x) = in((x + off) mod L). axis "x" or "y". Positive off = content moves left / up.
function S.shift(im, axis, off)
  local w, h = im.w, im.h
  local out = S.new(w, h)
  if axis == "x" then
    off = off % w
    for y = 0, h - 1 do local row = y * w
      for x = 0, w - 1 do out.d[row + x + 1] = im.d[row + (x + off) % w + 1] end end
  else
    off = off % h
    for y = 0, h - 1 do local src = ((y + off) % h) * w
      for x = 0, w - 1 do out.d[y * w + x + 1] = im.d[src + x + 1] end end
  end
  return out
end

-- Smallest p dividing L (L = sprite width for "x", height for "y") with the layer p-periodic along the axis.
function S.eff_len(im, axis)
  local L = axis == "x" and im.w or im.h
  for p = 1, L do
    if L % p == 0 then
      local ok = true
      if p < L then
        if axis == "x" then
          for y = 0, im.h - 1 do local row = y * im.w
            for x = 0, im.w - 1 do if im.d[row + x + 1] ~= im.d[row + (x + p) % im.w + 1] then ok = false break end end
            if not ok then break end end
        else
          for y = 0, im.h - 1 do local r1, r2 = y * im.w, ((y + p) % im.h) * im.w
            for x = 0, im.w - 1 do if im.d[r1 + x + 1] ~= im.d[r2 + x + 1] then ok = false break end end
            if not ok then break end end
        end
      end
      if ok then return p end
    end
  end
  return L
end

-- Seam check: lines where the last row/column differs from the first (what a wrap-around would show). Returns diff, total.
function S.seam(im, axis)
  local diff, total = 0, 0
  if axis == "x" then
    total = im.h
    for y = 0, im.h - 1 do if S.get(im, 0, y) ~= S.get(im, im.w - 1, y) then diff = diff + 1 end end
  else
    total = im.w
    for x = 0, im.w - 1 do if S.get(im, x, 0) ~= S.get(im, x, im.h - 1) then diff = diff + 1 end end
  end
  return diff, total
end

-- Speed in hundredths of a pixel per frame (integer) -> reduced fraction p/q.
function S.frac(v100)
  v100 = math.abs(math.floor(v100 + 0.5))
  if v100 == 0 then return 0, 1 end
  local g = gcd(v100, 100)
  return v100 // g, 100 // g
end

-- Offset after t frames at speed p/q: floor(t*p/q), exact integer maths.
function S.offset(t, p, q) return (t * p) // q end

-- Frames until a layer of effective length L at speed p/q is back where it started.
function S.period(L, p, q)
  if p == 0 then return 1 end
  return (L * q) // gcd(L * q, p)
end

-- Fit a speed (hundredths) so the layer completes whole laps in exactly N frames: p/q = k*L/N, k >= 1 laps.
function S.fit(L, v100, N)
  if v100 == 0 then return 0, 1 end
  local k = math.max(1, math.floor(v100 * N / (100 * L) + 0.5))
  local g = gcd(k * L, N)
  return (k * L) // g, N // g
end

-- layers: { { L = , p = , q = } ... } -> loop length (frames), saturated at CAP + 1
function S.loop_length(layers)
  local n = 1
  for _, l in ipairs(layers) do n = lcm(n, S.period(l.L, l.p, l.q)) end
  return n
end

-- Snap: nudge whole-pixel speeds (+-1, +-0.5) so the loop gets strictly shorter. specs: { { L =, v100 = } }.
-- Returns new v100 list, new length, or nil if nothing shorter exists. Zero stays zero, a moving layer keeps moving.
function S.snap(specs, allow_half)
  local cands = {}
  for i, s in ipairs(specs) do
    local c = { s.v100 }
    if s.v100 > 0 then
      local steps = allow_half and { -100, -50, 50, 100 } or { -100, 100 }
      for _, d in ipairs(steps) do if s.v100 + d > 0 then c[#c + 1] = s.v100 + d end end
    end
    cands[i] = c
  end
  local function len_of(choice)
    local ls = {}
    for i, s in ipairs(specs) do local p, q = S.frac(choice[i]); ls[i] = { L = s.L, p = p, q = q } end
    return S.loop_length(ls)
  end
  local cur = {}
  for i, s in ipairs(specs) do cur[i] = s.v100 end
  local base = len_of(cur)
  local best, bestlen, bestdev = nil, base, 0
  local total = 1
  for _, c in ipairs(cands) do total = total * #c end
  local function consider(choice)
    local len, dev = len_of(choice), 0
    for i, s in ipairs(specs) do dev = dev + math.abs(choice[i] - s.v100) end
    if len < bestlen or (len == bestlen and best and dev < bestdev) then best, bestlen, bestdev = { table.unpack(choice) }, len, dev end
  end
  if total <= 30000 then
    local choice = {}
    local function rec(i)
      if i > #specs then consider(choice) return end
      for _, v in ipairs(cands[i]) do choice[i] = v; rec(i + 1) end
    end
    rec(1)
  else
    local choice = { table.unpack(cur) }
    for pass = 1, 2 do
      for i = 1, #specs do
        local keep, kl = choice[i], len_of(choice)
        for _, v in ipairs(cands[i]) do choice[i] = v; local l = len_of(choice) if l < kl then keep, kl = v, l end end
        choice[i] = keep
      end
    end
    consider(choice)
  end
  if best and bestlen < base then return best, bestlen end
  return nil
end

return S
