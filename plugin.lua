-- Parallax Loop Studio -- Aseprite extension entry point.
-- The maths live in ps.lua; this file reads the layers, builds the scrolling frames and writes the tag.

local core = nil
local LITE = true -- the Lite build flips this to true (see build_bundles.py)
local LITE_LAYERS, LITE_FRAMES, MAX_FRAMES, WARN_FRAMES = 3, 16, 600, 120

-- app.alert cannot be replaced in headless tests, so alerts go through this hook (nil in normal use).
local function alert(a)
  if rawget(_G, "PARALLAX_TEST_ALERT") then return PARALLAX_TEST_ALERT(a) end
  return app.alert(a)
end

local function load_core(dir)
  if not core then core = dofile(app.fs.joinPath(dir, "ps.lua")) end
  return core
end

-- Cel -> sprite-sized core image (0 = transparent). Indexed colours are stored as index+1.
local function cel_to_core(spr, cel)
  local S = core
  local im = S.new(spr.width, spr.height)
  local px = app.pixelColor
  local mode, tc = spr.colorMode, spr.transparentColor
  local cx, cy = cel.position.x, cel.position.y
  for it in cel.image:pixels() do
    local v = it()
    local x, y = it.x + cx, it.y + cy
    if mode == ColorMode.INDEXED then
      if v ~= tc then S.set(im, x, y, v + 1) end
    elseif mode == ColorMode.GRAY then
      if px.grayaA(v) > 0 then S.set(im, x, y, v) end
    else
      if px.rgbaA(v) > 0 then S.set(im, x, y, v) end
    end
  end
  return im
end

local function core_to_image(spr, im)
  local img = Image(im.w, im.h, spr.colorMode)
  local indexed = spr.colorMode == ColorMode.INDEXED
  if indexed then img:clear(spr.transparentColor) end
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then img:drawPixel(x, y, indexed and (v - 1) or v) end
  end end
  return img
end

local function collect_layers(parent, out)
  for _, l in ipairs(parent.layers) do
    if l.isGroup then collect_layers(l, out)
    elseif l.isVisible then out[#out + 1] = l end
  end
end

local DIRS = { "Left", "Right", "Up", "Down" }
local AXIS = { Left = "x", Right = "x", Up = "y", Down = "y" }
local SIGN = { Left = 1, Right = -1, Up = 1, Down = -1 }
-- presets: speeds in px/frame from the bottom (far) layer upwards; extra layers repeat the last value
local PRESETS = {
  ["Forest 4-layer"] = { 0, 1, 2, 4 },
  ["City night"] = { 0, 1, 1, 3 },
  ["Clouds slow"] = { 0.25, 0.5, 1, 1.5 },
}
local PRESET_NAMES = { "Forest 4-layer", "City night", "Clouds slow" }
local LITE_PRESETS = { "Forest 4-layer" }

-- specs: { { layer =, v100 = speed in 1/100 px/frame >= 0, dir = "Left"|... } }. o: { target = frames or 0, duration = ms }.
-- Returns the plan (no pixels touched): { n =, rows = { {layer, im, axis, sign, p, q, L, period} }, seams = {...} } or nil, message.
local function make_plan(spr, fn, specs, o)
  local S = core
  local rows = {}
  for _, sp in ipairs(specs) do
    local c = sp.layer:cel(fn)
    if c then
      local im = cel_to_core(spr, c)
      local axis = AXIS[sp.dir] or "x"
      local full = axis == "x" and spr.width or spr.height
      local L = LITE and full or S.eff_len(im, axis)
      rows[#rows + 1] = { layer = sp.layer, im = im, axis = axis, sign = SIGN[sp.dir] or 1, L = L, full = full, v100 = sp.v100 }
    end
  end
  if #rows == 0 then return nil, "No visible layer has a drawing on this frame." end
  local target = (not LITE and o.target and o.target > 0) and math.floor(o.target) or 0
  for _, r in ipairs(rows) do
    if target > 0 then r.p, r.q = S.fit(r.L, r.v100, target) else r.p, r.q = S.frac(r.v100) end
    r.period = S.period(r.L, r.p, r.q)
  end
  local n = S.loop_length(rows)
  if n <= 1 then return nil, "Nothing moves: set a speed above 0 on at least one layer." end
  return { n = n, rows = rows }
end

local function seam_report(plan)
  local S = core
  local lines = {}
  for _, r in ipairs(plan.rows) do
    if r.v100 > 0 then
      local d, t = S.seam(r.im, r.axis)
      lines[#lines + 1] = string.format("%s: %d of %d %s differ across the wrap seam%s", r.layer.name, d, t,
        r.axis == "x" and "rows" or "columns", d == 0 and " (tileable)" or "")
    end
  end
  return table.concat(lines, "\n")
end

-- Writes frames fn+1 .. fn+n-1 (frame fn is t = 0) and tags fn..fn+n-1 "scroll". Returns frames made or nil, message.
local function generate(spr, fn, plan, duration)
  local S = core
  local made = 0
  app.transaction("Parallax Loop Studio", function()
    local cur = fn
    for t = 1, plan.n - 1 do
      local nf = spr:newFrame(cur)
      nf.duration = duration / 1000
      cur = cur + 1
      for _, r in ipairs(plan.rows) do
        local off = r.sign * S.offset(t, r.p, r.q)
        local im = (off % r.full == 0) and r.im or S.shift(r.im, r.axis, off)
        spr:newCel(r.layer, cur, core_to_image(spr, im), Point(0, 0))
      end
      made = made + 1
    end
    spr.frames[fn].duration = duration / 1000
    local tag = spr:newTag(fn, fn + plan.n - 1)
    tag.name = "scroll"
  end)
  return made
end

local function speed_text(v) return string.format("%g", v) end

local function show_dialog(plugin)
  local spr = app.sprite
  if not spr then alert("Open a sprite first."); return end
  load_core(plugin.path)
  local S = core
  local layers = {}
  collect_layers(spr, layers)
  if LITE and #layers > LITE_LAYERS then
    local keep = {}
    for i = 1, LITE_LAYERS do keep[i] = layers[i] end
    layers = keep
  end
  if #layers == 0 then alert("No visible layer found. Stack your background layers (far layer at the bottom) and make them visible."); return end
  local fn = app.frame and app.frame.frameNumber or 1
  local prefs = plugin.preferences
  local title = LITE and "Parallax Loop Studio (Lite)" or "Parallax Loop Studio"
  local dlg = Dialog(title)

  local function read_specs(data)
    local specs = {}
    for i, l in ipairs(layers) do
      local v = tonumber(data["sp" .. i]) or 0
      if LITE then v = math.floor(v) end
      specs[i] = { layer = l, v100 = math.floor(math.abs(v) * 100 + 0.5), dir = LITE and "Left" or (data["dir" .. i] or "Left") }
    end
    return specs
  end
  local function info_text(data)
    local plan, msg = make_plan(spr, fn, read_specs(data), { target = tonumber(data.target) or 0 })
    if not plan then return msg end
    local s = string.format("Loop: %d frames", plan.n)
    if plan.n > WARN_FRAMES then s = s .. " (long: try Snap or a target length)" end
    if LITE and plan.n > LITE_FRAMES then s = s .. " -- Lite max is " .. LITE_FRAMES end
    return s
  end
  local function apply_preset(name)
    local vals = PRESETS[name]
    if not vals then return end
    for i = 1, #layers do
      local v = vals[math.min(i, #vals)]
      if LITE then v = math.floor(v) end
      dlg:modify { id = "sp" .. i, text = speed_text(v) }
    end
    dlg:modify { id = "info", text = info_text(dlg.data) }
  end

  dlg:combobox { id = "preset", label = "Preset", option = LITE and LITE_PRESETS[1] or (prefs.preset or PRESET_NAMES[1]),
                 options = LITE and LITE_PRESETS or PRESET_NAMES, onchange = function() apply_preset(dlg.data.preset) end }
  dlg:separator { text = "Layers, far (bottom) to near (top): speed in px per frame" }
  local first = PRESETS[LITE and LITE_PRESETS[1] or PRESET_NAMES[1]]
  for i, l in ipairs(layers) do
    local v = first[math.min(i, #first)]
    if LITE then v = math.floor(v) end
    dlg:number { id = "sp" .. i, label = l.name, text = speed_text(v), decimals = LITE and 0 or 2,
                 onchange = function() dlg:modify { id = "info", text = info_text(dlg.data) } end }
    if not LITE then dlg:combobox { id = "dir" .. i, option = "Left", options = DIRS } end
  end
  if LITE then
    dlg:label { text = "Lite: first 3 layers, scrolling left, whole pixels, max 16 frames." }
  else
    dlg:number { id = "target", label = "Fit to frames (0 = auto)", text = tostring(prefs.target or 0), decimals = 0 }
    dlg:number { id = "duration", label = "Frame ms", text = tostring(prefs.duration or 100), decimals = 0 }
  end
  dlg:label { id = "info", text = info_text(dlg.data) }
  dlg:button { text = "Check loop", onclick = function() dlg:modify { id = "info", text = info_text(dlg.data) } end }
  if not LITE then
    dlg:button { text = "Snap speeds", onclick = function()
      local specs = read_specs(dlg.data)
      local plan = make_plan(spr, fn, specs, { target = 0 })
      if not plan then return end
      local ss = {}
      for i, r in ipairs(plan.rows) do ss[i] = { L = r.L, v100 = r.v100 } end
      local best, len = S.snap(ss, true)
      if not best then dlg:modify { id = "info", text = "Already the shortest loop for these speeds (" .. plan.n .. " frames)." }; return end
      for i, v in ipairs(best) do dlg:modify { id = "sp" .. i, text = speed_text(v / 100) } end
      dlg:modify { id = "info", text = string.format("Snapped: %d frames instead of %d.", len, plan.n) }
    end }
  end
  dlg:separator()
  dlg:button { id = "ok", text = "Generate", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  if LITE then dlg:label { text = "Full version: any number of layers, all four directions, fractional speeds, loop snap, fit-to-length, seam check, presets." } end
  dlg:show()
  local d = dlg.data
  if not d.ok then return end
  local o = { target = LITE and 0 or (tonumber(d.target) or 0) }
  local duration = LITE and 100 or math.max(20, tonumber(d.duration) or 100)
  if not LITE then prefs.preset, prefs.target, prefs.duration = d.preset, o.target, duration end
  local plan, msg = make_plan(spr, fn, read_specs(d), o)
  if not plan then alert { title = title, text = msg }; return end
  if LITE and plan.n > LITE_FRAMES then
    alert { title = title, text = string.format("This loop needs %d frames; Lite is limited to %d. Use faster/other speeds or the full version (snap and fit-to-length).", plan.n, LITE_FRAMES) }
    return
  end
  if plan.n > MAX_FRAMES then
    alert { title = title, text = string.format("This loop needs %d frames (limit %d). Change speeds or set Fit to frames.", plan.n, MAX_FRAMES) }
    return
  end
  if plan.n > WARN_FRAMES then
    local r = alert { title = title, text = string.format("This loop needs %d frames. Generate anyway?", plan.n), buttons = { "Generate", "Cancel" } }
    if r ~= 1 then return end
  end
  generate(spr, fn, plan, duration)
  if not LITE then alert { title = title, text = string.format("%d-frame loop tagged 'scroll'.\n%s", plan.n, seam_report(plan)) } end
  app.refresh()
end

function init(plugin)
  local id = LITE and "ParallaxLoopStudioLite" or "ParallaxLoopStudio"
  local title = LITE and "Parallax Loop Studio (Lite)..." or "Parallax Loop Studio..."
  plugin:newCommand { id = id, title = title, group = "cel_popup_properties", onclick = function() show_dialog(plugin) end }
  plugin:newCommand { id = id .. "Edit", title = title, group = "edit_fx", onclick = function() show_dialog(plugin) end }
end

function exit(plugin) end

return { load_core = load_core, make_plan = make_plan, generate = generate }
