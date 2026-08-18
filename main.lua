-- Floating Battle HUD v0.5.7
-- Companion mod for Dramatic Shape / PotatoVoxel 1.6.x.
--
-- v0.3 is the visual reset: the frosted cards are gone. The HUD is built
-- around x8 transparent battleplate art inspired by Gen I's original battle
-- furniture, while the live information remains code-driven and follows
-- Dramatic Shape's projected Pokemon positions every frame.

local mod = ...

-- Dramatic Shape and PotatoVoxel expose the same companion-module seam, but
-- Potato may ship under a different manifest id. Probe the known ids and then
-- adapt to whichever OverworldBattle HUD integration that host provides.
local HOST_IDS = { "DRAMATIC_SHAPE", "POTATO_VOXEL", "POTATO_VOXEL_MOD", "potato_voxel" }
local ds, hostId = nil, nil
if mod.find then
  for _, id in ipairs(HOST_IDS) do
    local hit = mod.find(id)
    if hit and hit.exports and hit.exports.lib then
      ds, hostId = hit, id
      break
    end
  end
end
if not (ds and ds.exports and ds.exports.lib) then
  error("FLOATING_BATTLE_HUD: Dramatic Shape or PotatoVoxel with exports.lib is required", 0)
end

local V = ds.exports.lib
local OverworldBattle = V.require("OverworldBattle")
local BattleCam = V.require("BattleCam")

-- Legacy Dramatic Shape has BattleHud/textRects/snapHUDs. PotatoVoxel 1.6.1
-- removed that composite path and leaves its text box on the native UI canvas.
local BattleHud = nil
if type(OverworldBattle.snapHUDs) == "function" then
  local ok, value = pcall(V.require, "BattleHud")
  if ok then BattleHud = value end
end

-- Private engine modules: manifest requests engine_internals.
local Font = require("src.render.Font")
local Growth = require("src.pokemon.Growth")

local g = love.graphics
local FloatingHud = {}

-- The engine font sheet is black-on-transparent. LOVE tinting multiplies RGB,
-- so setting white cannot turn those black pixels white. Draw the exact same
-- glyphs through a mask shader instead: source alpha supplies the shape and
-- `ink` supplies the requested colour.
local TEXT_MASK_SHADER_SOURCE = [[
  uniform vec4 ink;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 src = Texel(tex, tc);
    return vec4(ink.rgb, ink.a * src.a * color.a);
  }
]]

local textMaskShader = nil
local function getTextMaskShader()
  if textMaskShader == false then return nil end
  if textMaskShader then return textMaskShader end
  local ok, shader = pcall(g.newShader, TEXT_MASK_SHADER_SOURCE)
  textMaskShader = (ok and shader) or false
  return textMaskShader or nil
end

-- ---------------------------------------------------------------------------
-- User-facing options
-- ---------------------------------------------------------------------------

mod.options:define({
  {
    key = "wild_dvs",
    type = "toggle",
    label = "WILD DVS",
    default = false,
  },
})

-- ---------------------------------------------------------------------------
-- Asset convention
-- ---------------------------------------------------------------------------

-- All authored HUD art is exported at x8. One logical HUD pixel therefore
-- corresponds to eight source pixels, regardless of the window/UI scale.
FloatingHud.ASSET_SCALE = 1 / 8
FloatingHud.SHADOW_PX = 3       -- final framebuffer pixels, not logical pixels
FloatingHud.MAX_SCALE = 3
FloatingHud.MARGIN = 4

-- Camera-distance response. Dramatic Shape reports how wide the Pokemon's
-- overworld cell projects on screen (`playerSpan` / `enemySpan`). A full-size
-- Gen-I front sprite is authored around a 56px slot, so span / 56 is a useful
-- approximation of the Pokemon's own apparent scale. Clamp it so the HUD keeps
-- breathing with perspective without ever becoming unreadably tiny or huge.
FloatingHud.REFERENCE_SPAN = 56
FloatingHud.DISTANCE_SCALE_MIN = 0.68
FloatingHud.DISTANCE_SCALE_MAX = 1.32
FloatingHud.CAMERA_CENTER_OFFSET = 0.12

-- Very small 2D Z-roll driven only by Dramatic Shape camera yaw. Zoom no longer
-- contributes to orientation; it is reserved exclusively for distance scaling.
FloatingHud.MAX_ROTATION_DEG = 3.0

-- Faux Y-axis perspective. At full camera travel the near vertical edge is
-- PERSPECTIVE_DEPTH taller than neutral and the far edge the same amount
-- shorter. The whole plane also narrows slightly, like a card yawed away from
-- the viewer. Set PERSPECTIVE_DEPTH = 0 to return to the flat v0.4.1 HUD.
FloatingHud.PERSPECTIVE_DEPTH = -0.20
FloatingHud.PERSPECTIVE_WIDTH_SQUEEZE = 0.06
-- Subdivide the projected card so texture interpolation does not reveal LOVE's
-- underlying two-triangle split on strongly skewed quads.
FloatingHud.PERSPECTIVE_GRID_X = 12
FloatingHud.PERSPECTIVE_GRID_Y = 6
FloatingHud.CANVAS_PAD = 5
-- Render the intermediate HUD texture at higher resolution, then project it
-- back to the same on-screen size. This preserves the aligned logical layout
-- while giving the perspective mesh substantially more texels to work with.
FloatingHud.CANVAS_RENDER_SCALE = 4

local PLATE_ASSETS = {
  enemy = "assets/hud/battleplate_enemy.png",
  player = "assets/hud/battleplate_player.png",
}

local STATUS_ASSETS = {
  SLP = "assets/hud/status_sleep.png",
  PSN = "assets/hud/status_poison.png",
  BRN = "assets/hud/status_burn.png",
  PAR = "assets/hud/status_paralysis.png",
  FRZ = "assets/hud/status_frozen.png",
}

local STATUS_FALLBACK = {
  SLP = "SLP",
  PSN = "PSN",
  BRN = "BRN",
  PAR = "PAR",
  FRZ = "FRZ",
}

local CAUGHT_ASSET = "assets/hud/caught.png"
local images = {}

local function assetImage(path)
  if images[path] ~= nil then return images[path] or nil end
  local ok, img = pcall(function() return mod.assets:image(path) end)
  if ok and img then
    pcall(img.setFilter, img, "nearest", "nearest")
    images[path] = img
    return img
  end
  images[path] = false
  return nil
end

local function plateImage(side)
  return assetImage(PLATE_ASSETS[side])
end

local function plateSize(side)
  local img = plateImage(side)
  if not img then return nil, nil end
  local w, h = img:getDimensions()
  return w * FloatingHud.ASSET_SCALE, h * FloatingHud.ASSET_SCALE
end

-- ---------------------------------------------------------------------------
-- Layout map, in logical HUD pixels
-- ---------------------------------------------------------------------------
--
-- The x8 battleplates are ~105.4 x 63.4 logical pixels. These coordinates are
-- deliberately centralized: after a screenshot, tuning is just moving numbers
-- here rather than touching drawing code.

FloatingHud.LAYOUT = {
  enemy = {
    name       = { x = 13.0,  y = 1.0 },
    status     = { x = 5.0,  y = 11.5 },
    level      = { x = 64.5, y = 9.5, scale = 1.15 }, -- digits only; :L is in plate
    caught     = { x = 97.0, y = 8.8 },
    hpFill     = { x = 33.5, y = 23.25, w = 61.25, h = 2.50 },
    hpNumbers  = { right = 97.0, y = 28.5 },
    dvs        = { y = 48.5, scale = 0.75 },
  },

  player = {
    name       = { x = 13.0,  y = 1.0 },
    status     = { x = 7.0,  y = 11.5 },
    level      = { x = 60.0, y = 9.5, scale = 1.15 }, -- digits only; :L is in plate
    hpFill     = { x = 29.5, y = 23.25, w = 61.25, h = 2.50 },
    hpNumbers  = { right = 93.5, y = 28.5 },
    -- Blue EXP rides on top of the battleplate's lower support line.
    expFill    = { x = 5.5, y = 41.9, w = 84.0, h = 2.5 },
  },
}

-- The projected point supplied by Dramatic Shape is the Pokemon's FEET. This
-- is still an estimated head lift; true sprite ink bounds are a later step.
FloatingHud.HEAD_LIFT = {
  enemy = 1.05,
  player = 1.05,
}
FloatingHud.EXTRA_RISE = 12
FloatingHud.GAP = 3

-- PotatoVoxel projects the staged mons a little differently from Dramatic Shape.
-- These offsets move ONLY our floating nameplates on PotatoVoxel, without touching
-- the camera, Pokemon, or Dramatic Shape placement. Values are logical HUD pixels:
-- positive = DOWN, negative = UP.
FloatingHud.POTATO_ENEMY_Y_OFFSET = 0
FloatingHud.POTATO_PLAYER_Y_OFFSET = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function textWidth(s)
  s = tostring(s or "")
  local ok, w = pcall(Font.width, s)
  return (ok and tonumber(w)) or (#s * 8)
end

local function shownHP(battler)
  if not (battler and battler.mon) then return 0, 1 end
  local hp = battler.shownHP
  if hp == nil then hp = battler.mon.hp or 0 end
  local actual = battler.mon.hp or 0
  if hp > actual then hp = math.ceil(hp) else hp = math.floor(hp) end
  local maxHP = math.max(1, battler.mon.stats and battler.mon.stats.hp or 1)
  return clamp(hp, 0, maxHP), maxHP
end

local function expRatio(battle, battler)
  local mon = battler and battler.mon
  if not (battle and mon) then return 0 end
  local def = battle.data and battle.data.pokemon and battle.data.pokemon[mon.species]
  if not def then return 0 end

  local cap = (battle.data.constants and battle.data.constants.levelCap) or 100
  local level = mon.level or 1
  if level >= cap then return 1 end

  local rates = battle.data.growth_rates
  local from = Growth.expForLevel(def.growthRate, level, rates)
  local to = Growth.expForLevel(def.growthRate, level + 1, rates)
  if to <= from then return 0 end
  return clamp(((mon.exp or from) - from) / (to - from), 0, 1)
end

local function uiScale(shot)
  local s = tonumber(shot and shot.scale) or 1
  return clamp(math.floor(s * 0.5 + 0.5), 1, FloatingHud.MAX_SCALE)
end

local function distanceScale(shot, side)
  local span = tonumber(shot and shot[side .. "Span"]) or FloatingHud.REFERENCE_SPAN
  local ratio = span / FloatingHud.REFERENCE_SPAN
  return clamp(ratio, FloatingHud.DISTANCE_SCALE_MIN,
                      FloatingHud.DISTANCE_SCALE_MAX)
end

-- Camera-only orientation signal. Unlike projected Pokemon displacement, this
-- does NOT change when the player merely zooms the lens. It follows the same
-- yaw Dramatic Shape uses for the battle camera: manual orbit plus its tiny
-- automatic drift. 0 is the authored camera angle; magnitude grows as the
-- camera swings toward side-on.
local function cameraYawSignal()
  local arena = OverworldBattle.arena and OverworldBattle.arena() or nil
  local range = 1

  if arena and BattleCam and BattleCam.orbitRange then
    local ok, r = pcall(BattleCam.orbitRange, arena)
    if ok and tonumber(r) and r > 1e-6 then
      range = r
    end
  end

  local orbit = clamp(tonumber(BattleCam and BattleCam.orbit) or 0, 0, 1)
  local yaw = -orbit * range

  -- Dramatic Shape's own slow +/-2 degree camera drift.
  if BattleCam and not BattleCam.still
     and tonumber(BattleCam.PAN_PERIOD)
     and BattleCam.PAN_PERIOD > 0 then

    local t = tonumber(BattleCam.t) or 0
    local drift = (tonumber(BattleCam.PAN_YAW) or 0)
                  * math.sin(2 * math.pi * t / BattleCam.PAN_PERIOD)

    yaw = yaw + drift
  end

  local signal = yaw / math.max(range, 1e-6)
  signal = signal + FloatingHud.CAMERA_CENTER_OFFSET

  return clamp(signal, -1, 1)
end

local function hudRotation()
  return math.rad((FloatingHud.MAX_ROTATION_DEG or 0) * cameraYawSignal())
end

local function wildBattle(battle)
  return battle and (battle.kind == "wild" or battle.kind == "safari")
end

local function showWildDVs(battle, side, battler)
  return side == "enemy"
     and wildBattle(battle)
     and battler and battler.mon and battler.mon.dvs
     and mod.options:get("wild_dvs") == true
end

local function caughtSpecies(battle, side, battler)
  if side ~= "enemy" or not wildBattle(battle) or not (battler and battler.mon) then
    return false
  end
  local dex = battle.game and battle.game.save and battle.game.save.pokedex
  return (dex and dex.owned and dex.owned[battler.mon.species]) and true or false
end

local function hpDV(dvs)
  if not dvs then return nil end
  local atk, def, spd, spc = dvs.attack, dvs.defense, dvs.speed, dvs.special
  if atk == nil or def == nil or spd == nil or spc == nil then return nil end
  return (atk % 2) * 8 + (def % 2) * 4 + (spd % 2) * 2 + (spc % 2)
end

local function dvText(mon)
  local dvs = mon and mon.dvs
  local hp = hpDV(dvs)
  if hp == nil then return nil end
  return string.format("%02d/%02d/%02d/%02d/%02d",
                       hp, dvs.attack, dvs.defense, dvs.speed, dvs.special)
end

local function toWorld(rect, shot)
  local s = shot.scale
  return {
    shot.lx + rect[1] * s,
    shot.ly + rect[2] * s,
    rect[3] * s,
    rect[4] * s,
  }
end

local function worldRectFor(shot, side)
  local pos = shot and shot[side]
  if not pos then return nil end

  local logicalW, logicalH = plateSize(side)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local perspective = distanceScale(shot, side)
  local drawScale = baseScale * perspective
  local span = tonumber(shot[side .. "Span"]) or FloatingHud.REFERENCE_SPAN
  local lift = FloatingHud.HEAD_LIFT[side] or 1

  local footX = shot.lx + pos[1] * s
  local headY = shot.ly + (pos[2] - span * lift) * s

  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local gap = FloatingHud.GAP * drawScale
  -- Keep this extra breathing room tied to UI scale rather than perspective:
  -- the HUD shrinks with a distant mon, but does not collapse onto its head.
  local extra = FloatingHud.EXTRA_RISE * baseScale
  local margin = FloatingHud.MARGIN

  local x = footX - w / 2
  local y = headY - h - gap - extra

  -- PotatoVoxel-only vertical tuning. Keep it tied to UI scale (not distance
  -- perspective), so a chosen offset remains visually consistent while zooming.
  local potatoHost = type(OverworldBattle.snapHUDs) ~= "function"
                  and type(OverworldBattle.drawHudPanels) == "function"
  if potatoHost then
    local yOffset = side == "enemy"
      and (FloatingHud.POTATO_ENEMY_Y_OFFSET or 0)
       or (FloatingHud.POTATO_PLAYER_Y_OFFSET or 0)
    y = y + yOffset * baseScale
  end

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = clamp(y, margin, math.max(margin, shot.ph - h - margin))

  return { x, y, w, h }, drawScale, logicalW, logicalH
end

-- A 3px shadow in FINAL framebuffer pixels, even though the HUD itself changes
-- integer scale with the window. Called after g.scale(k,k), hence division by k.
local function shadowLogical(k, extraScale)
  return FloatingHud.SHADOW_PX / math.max(0.001, k * (extraScale or 1))
end

local function drawMaskedFont(text, x, y, r, gg, b, a)
  local shader = getTextMaskShader()
  if not shader then
    -- Fallback is the engine's native black font. This path should only happen
    -- on a driver that cannot compile the tiny mask shader.
    g.setShader()
    g.setColor(r, gg, b, a or 1)
    return Font.draw(text, x, y)
  end

  local previous = g.getShader()
  g.setShader(shader)
  pcall(shader.send, shader, "ink", { r, gg, b, a or 1 })
  g.setColor(1, 1, 1, 1)
  local out = Font.draw(text, x, y)
  g.setShader(previous)
  return out
end

local function drawShadowText(text, x, y, k, extraScale)
  text = tostring(text or "")
  extraScale = extraScale or 1

  if extraScale ~= 1 then
    g.push()
    g.translate(x, y)
    g.scale(extraScale, extraScale)
    local o = shadowLogical(k, extraScale)
    drawMaskedFont(text, o, o, 0, 0, 0, 1)
    drawMaskedFont(text, 0, 0, 1, 1, 1, 1)
    g.pop()
    return
  end

  local o = shadowLogical(k, 1)
  drawMaskedFont(text, x + o, y + o, 0, 0, 0, 1)
  drawMaskedFont(text, x, y, 1, 1, 1, 1)
end

local function drawShadowAsset(img, x, y, k, scale, colored)
  if not img then return false end
  scale = scale or FloatingHud.ASSET_SCALE
  local o = shadowLogical(k, 1)

  -- Silhouette shadow first. Tinting an Image black preserves its alpha mask.
  g.setColor(0, 0, 0, 1)
  g.draw(img, x + o, y + o, 0, scale, scale)

  -- Battleplates are white masks; status/caught keep their authored colors.
  g.setColor(1, 1, 1, 1)
  g.draw(img, x, y, 0, scale, scale)
  return true
end

local function drawStatus(mon, x, y, k)
  local status = mon and mon.status
  if not status then return false end

  local path = STATUS_ASSETS[status]
  local img = path and assetImage(path) or nil
  if img then
    drawShadowAsset(img, x, y, k, FloatingHud.ASSET_SCALE, true)
    return true
  end

  local fallback = STATUS_FALLBACK[status]
  if fallback then
    drawShadowText(fallback, x, y, k)
    return true
  end
  return false
end

local function drawCaughtMarker(x, y, k)
  local img = assetImage(CAUGHT_ASSET)
  if img then
    return drawShadowAsset(img, x, y, k, FloatingHud.ASSET_SCALE, true)
  end
  drawShadowText("C", x, y, k)
  return true
end

local function drawHPFill(layout, ratio)
  local r = layout.hpFill
  ratio = clamp(ratio or 0, 0, 1)
  local w = r.w * ratio
  if w <= 0 then return end

  -- Gen-I style HP states: green above half, yellow from 21-50%, red at 20%
  -- or lower. Only the fill changes colour; the authored plate remains white.
  if ratio <= 0.20 then
    g.setColor(0.95, 0.16, 0.12, 1)
  elseif ratio <= 0.50 then
    g.setColor(1.00, 0.82, 0.10, 1)
  else
    g.setColor(0.15, 0.92, 0.30, 1)
  end
  g.rectangle("fill", r.x, r.y, w, r.h)
end

local function drawEXPFill(layout, ratio)
  local r = layout.expFill
  if not r then return end
  ratio = clamp(ratio or 0, 0, 1)
  local w = r.w * ratio
  if w <= 0 then return end

  g.setColor(0.12, 0.62, 1.00, 1)
  g.rectangle("fill", r.x, r.y, w, r.h)
end

local cardCanvases = {}
local cardMeshes = {}

local function cardCanvas(side, logicalW, logicalH)
  local pad = FloatingHud.CANVAS_PAD or 0
  local raster = math.max(1, tonumber(FloatingHud.CANVAS_RENDER_SCALE) or 1)

  -- cw/ch are texture pixels; logicalCW/logicalCH are the exact same plane in
  -- HUD coordinates. The mesh later uses the logical size, so increasing raster
  -- density never changes the HUD's size or any hand-tuned layout coordinate.
  local logicalCW = logicalW + pad * 2
  local logicalCH = logicalH + pad * 2
  local cw = math.ceil(logicalCW * raster)
  local ch = math.ceil(logicalCH * raster)
  local canvas = cardCanvases[side]
  if not canvas or canvas:getWidth() ~= cw or canvas:getHeight() ~= ch then
    local ok, made = pcall(g.newCanvas, cw, ch, { dpiscale = 1 })
    if not (ok and made) then return nil end
    -- The authored assets themselves remain nearest-filtered. The completed
    -- supersampled card is sampled linearly only during its final perspective
    -- projection, avoiding the broken/stair-stepped glyph edges of the old
    -- ~105x63 intermediate texture.
    pcall(made.setFilter, made, "linear", "linear")
    canvas = made
    cardCanvases[side] = canvas
  end
  return canvas, cw, ch, pad, raster, logicalCW, logicalCH
end

local function renderCardCanvas(battle, side, battler, k, logicalW, logicalH)
  local plate = plateImage(side)
  if not plate then return nil end
  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    cardCanvas(side, logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.LAYOUT[side]
  local mon = battler.mon
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local prevShader = g.getShader()
  local ok, err = pcall(function()
    g.setCanvas(canvas)
    g.origin()
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setShader()
    g.setColor(1, 1, 1, 1)
    g.push()
    -- Draw the exact same logical HUD at a denser raster resolution. Nothing
    -- below this line needs new coordinates: one logical pixel simply occupies
    -- `raster` texture pixels while this offscreen capture is being made.
    g.scale(raster, raster)
    g.translate(pad, pad)

    -- Structural shadow first.
    local plateShadow = shadowLogical(k, 1)
    g.setColor(0, 0, 0, 1)
    g.draw(plate, plateShadow, plateShadow, 0,
           FloatingHud.ASSET_SCALE, FloatingHud.ASSET_SCALE)

    -- Dynamic fills remain behind the authored white support.
    local hp, maxHP = shownHP(battler)
    drawHPFill(layout, hp / maxHP)
    if side == "player" then drawEXPFill(layout, expRatio(battle, battler)) end

    g.setColor(1, 1, 1, 1)
    g.draw(plate, 0, 0, 0, FloatingHud.ASSET_SCALE, FloatingHud.ASSET_SCALE)

    local name = tostring(battler.name or mon.species or "")
    drawShadowText(name, layout.name.x, layout.name.y, k)
    drawStatus(mon, layout.status.x, layout.status.y, k)
    drawShadowText(tostring(mon.level or "?"), layout.level.x, layout.level.y, k,
                   layout.level.scale or 1)

    if side == "enemy" and caughtSpecies(battle, side, battler) then
      drawCaughtMarker(layout.caught.x, layout.caught.y, k)
    end

    local hpText = tostring(hp) .. "/" .. tostring(maxHP)
    local hpX = layout.hpNumbers.right - textWidth(hpText)
    drawShadowText(hpText, hpX, layout.hpNumbers.y, k)

    if side == "enemy" and showWildDVs(battle, side, battler) then
      local text = dvText(mon)
      if text then
        local scale = layout.dvs.scale or 1
        local visualW = textWidth(text) * scale
        local x = (logicalW - visualW) / 2
        drawShadowText(text, x, layout.dvs.y, k, scale)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH, pad
end

local function rotatedPoint(x, y, angle)
  if angle == 0 then return x, y end
  local c, s = math.cos(angle), math.sin(angle)
  return x * c - y * s, x * s + y * c
end

local function drawPerspectiveCanvas(canvas, cx, cy, w, h, signal, roll, side)
  signal = clamp(signal or 0, -1, 1)
  local depth = clamp(FloatingHud.PERSPECTIVE_DEPTH or 0, 0, 0.45)
  local squeeze = clamp(FloatingHud.PERSPECTIVE_WIDTH_SQUEEZE or 0, 0, 0.35)

  -- Positive signal makes the RIGHT edge the near edge; negative makes LEFT near.
  local leftScale  = 1 - signal * depth
  local rightScale = 1 + signal * depth
  local widthScale = 1 - math.abs(signal) * squeeze
  local lx, rx = -w * 0.5 * widthScale, w * 0.5 * widthScale
  local lhy, rhy = h * 0.5 * leftScale, h * 0.5 * rightScale

  local x1,y1 = rotatedPoint(lx, -lhy, roll) -- top-left
  local x2,y2 = rotatedPoint(rx, -rhy, roll) -- top-right
  local x3,y3 = rotatedPoint(rx,  rhy, roll) -- bottom-right
  local x4,y4 = rotatedPoint(lx,  lhy, roll) -- bottom-left

  -- A single quad is rasterized as two triangles, whose affine UV interpolation
  -- makes the diagonal visible when the four corners form a strong trapezoid.
  -- Subdivide the card and bilinearly place a small grid across the same four
  -- corners. The remaining per-triangle error is tiny and the whole HUD now reads
  -- as one continuous plane instead of two halves pulling in different directions.
  local gx = math.max(2, math.floor(FloatingHud.PERSPECTIVE_GRID_X or 12))
  local gy = math.max(2, math.floor(FloatingHud.PERSPECTIVE_GRID_Y or 6))
  local verts = {}

  for iy = 0, gy do
    local v = iy / gy
    for ix = 0, gx do
      local u = ix / gx
      local tx = x1 + (x2 - x1) * u
      local ty = y1 + (y2 - y1) * u
      local bx = x4 + (x3 - x4) * u
      local by = y4 + (y3 - y4) * u
      local x = tx + (bx - tx) * v
      local y = ty + (by - ty) * v
      verts[#verts + 1] = { x, y, u, v }
    end
  end

  local key = side .. ":" .. gx .. "x" .. gy
  local mesh = cardMeshes[key]
  if not mesh then
    mesh = g.newMesh(verts, "triangles", "dynamic")
    local map = {}
    local row = gx + 1
    for iy = 0, gy - 1 do
      for ix = 0, gx - 1 do
        local a = iy * row + ix + 1
        local b = a + 1
        local d = a + row
        local c = d + 1
        map[#map + 1] = a; map[#map + 1] = b; map[#map + 1] = c
        map[#map + 1] = a; map[#map + 1] = c; map[#map + 1] = d
      end
    end
    mesh:setVertexMap(map)
    cardMeshes[key] = mesh
  else
    mesh:setVertices(verts)
  end

  mesh:setTexture(canvas)
  g.setColor(1, 1, 1, 1)
  g.draw(mesh, cx, cy)
end

local function drawCard(battle, shot, side, battler)
  if not (battler and battler.mon) then return false end
  local rect, k, logicalW, logicalH = worldRectFor(shot, side)
  if not rect then return false end

  local canvas, cw, ch = renderCardCanvas(battle, side, battler, k,
                                          logicalW, logicalH)
  if not canvas then return false end

  local signal = cameraYawSignal()
  local roll = hudRotation()
  local cx = rect[1] + rect[3] / 2
  local cy = rect[2] + rect[4] / 2

  -- Canvas padding is transparent and symmetric, so it can be included in the
  -- projected plane without changing the HUD's visual centre.
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k, signal, roll, side)
  return true
end

local function drawTextGlass(battle, shot)
  -- Legacy Dramatic Shape only. PotatoVoxel removed the frosted text composite
  -- and intentionally keeps the native white text/menu paper.
  if not (BattleHud and OverworldBattle.textRects) then return end
  for _, rect in pairs(OverworldBattle.textRects(battle)) do
    BattleHud.panel(toWorld(rect, shot), shot, true)
  end
end

local function vrActive()
  local ok, vr = pcall(V.require, "VR")
  return ok and vr and vr.active and vr.active() or false
end

local function specialLayout(battle)
  if not battle then return true end
  if vrActive() then return true end
  if OverworldBattle.backPinned and OverworldBattle.backPinned() then return true end
  if battle.safari or battle.demo or battle.blankForAskName then return true end
  if battle.introBalls or battle.showEnemyBalls then return true end
  if battle.showEnemyTrainer or battle.showPlayerBack then return true end
  return false
end

-- ---------------------------------------------------------------------------
-- Host integration
-- ---------------------------------------------------------------------------

local hostMode = nil

-- PotatoVoxel's public hudLive() begins by asking statusHUDVisible().  On the
-- Potato backend we deliberately suppress that native surface through the
-- launcher's visibility hook, so using hudLive() here would also hide OUR HUD.
-- Mirror only its structural/lifecycle guards for our replacement plates.
local function floatingHudLive(battle, slide)
  if not battle then return false, false end

  -- PotatoVoxel: take ownership as soon as each battler exists, matching the
  -- replacement UI's lifecycle rather than waiting for Gen I's native HUD
  -- intro guards (slide/grow/introBalls). This prevents the stock opponent
  -- nameplate from getting an opening frame before ours appears.
  if hostMode == "potato_voxel" then
    local enemy = battle.enemy and not battle.showEnemyTrainer
                  and not battle.enemySendingOut
    local player = battle.player and not (battle.safari or battle.demo)
                   and not battle.showPlayerBack
    return enemy and true or false, player and true or false
  end

  local enemy = battle.enemy and not battle.showEnemyTrainer
                and not battle.enemySendingOut
                and not battle:growInScale(battle.enemy) and slide == 0
                and not battle.introBalls
                and not battle.enemy.fainted
  local player = battle.player and not (battle.safari or battle.demo)
                 and not battle.showPlayerBack and slide == 0
  return enemy and true or false, player and true or false
end

local function drawFloatingPair(battle, shot, includeTextGlass)
  if not (battle and shot and shot.canvas and (shot.scale or 0) > 0) then
    return false
  end
  -- Dramatic Shape keeps its conservative fallback layouts. PotatoVoxel can
  -- own the status plates during the battle intro itself; per-side visibility
  -- below decides whether player/enemy is ready, so introBalls/grow/slide do
  -- not need to force a fallback to the native nameplates.
  if hostMode ~= "potato_voxel" and specialLayout(battle) then return false end
  if hostMode == "potato_voxel" then
    if vrActive() then return false end
    if OverworldBattle.backPinned and OverworldBattle.backPinned() then return false end
    if battle.safari or battle.demo or battle.blankForAskName then return false end
  end
  if not (plateImage("enemy") and plateImage("player")) then return false end

  local slide = (battle.introSlide or 0) * 4
  local enemyLive, playerLive
  if hostMode == "potato_voxel" then
    enemyLive, playerLive = floatingHudLive(battle, slide)
  else
    enemyLive, playerLive = OverworldBattle.hudLive(battle, slide)
    if battle.statusHUDVisible and not battle:statusHUDVisible() then
      enemyLive, playerLive = false, false
    end
  end
  if not enemyLive and not playerLive then return false end

  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local prevShader = g.getShader()
  local ok, err = pcall(function()
    g.setCanvas(shot.canvas)
    g.setBlendMode("alpha")
    g.setShader()
    g.setColor(1, 1, 1, 1)

    if includeTextGlass then drawTextGlass(battle, shot) end
    if enemyLive then drawCard(battle, shot, "enemy", battle.enemy) end
    if playerLive then drawCard(battle, shot, "player", battle.player) end
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)

  if not ok then
    mod.log:warn("floating HUD draw failed: %s", tostring(err))
    return false
  end
  return true
end

if type(OverworldBattle.snapHUDs) == "function" then
  -- Dramatic Shape 1.6.0 path: it asks snapHUDs to composite HUD furniture into
  -- the window-resolution world canvas, then suppresses the native HUD itself.
  hostMode = "dramatic_shape"
  local BASE_KEY = "_floatingBattleHudBaseSnapHUDs"
  if not OverworldBattle[BASE_KEY] then
    OverworldBattle[BASE_KEY] = OverworldBattle.snapHUDs
  end
  local baseSnapHUDs = OverworldBattle[BASE_KEY]

  function FloatingHud.snapHUDs(battle, shot)
    if drawFloatingPair(battle, shot, true) then return true end
    return baseSnapHUDs(battle, shot)
  end

  OverworldBattle.snapHUDs = FloatingHud.snapHUDs

elseif type(OverworldBattle.drawHudPanels) == "function" then
  -- PotatoVoxel 1.6.1 path. It no longer has snapHUDs: BattleState:draw first
  -- points Renderer at shot.canvas, then calls drawHudPanels before the native
  -- battle UI. We use that moment to paint our floating HUD into shot.canvas,
  -- and suppress only the native Pokemon HUD blocks later in the same frame.
  hostMode = "potato_voxel"

  local PANEL_KEY = "_floatingBattleHudBaseDrawHudPanels"
  if not OverworldBattle[PANEL_KEY] then
    OverworldBattle[PANEL_KEY] = OverworldBattle.drawHudPanels
  end
  local baseDrawHudPanels = OverworldBattle[PANEL_KEY]

  function FloatingHud.drawPotatoHudPanels(battle)
    if not battle then return baseDrawHudPanels(battle) end
    battle._floatingBattleHudPotatoDrawn = false
    local shot = battle.dramaticShapeShot
    if drawFloatingPair(battle, shot, false) then
      battle._floatingBattleHudPotatoDrawn = true
      return
    end
    return baseDrawHudPanels(battle)
  end

  OverworldBattle.drawHudPanels = FloatingHud.drawPotatoHudPanels

  -- Potato's status_hud_visible predicate is not the only path that can emit
  -- Gen I HUD pixels: BattleState.drawHUDs also owns the actual status blocks
  -- (and transient party-ball chrome).  The reference replacement UI keeps the
  -- method alive but runs it under an empty scissor, so lifecycle side effects
  -- still happen while every native HUD pixel is discarded.  Importantly, the
  -- command/menu/text UI is NOT drawn by drawHUDs, so it remains untouched.
  local BattleState = require("src.battle.BattleState")
  local DRAW_KEY = "_floatingBattleHudBaseDrawHUDs"
  if not BattleState[DRAW_KEY] then
    BattleState[DRAW_KEY] = BattleState.drawHUDs
  end
  local baseDrawHUDs = BattleState[DRAW_KEY]
  if type(baseDrawHUDs) == "function" then
    function BattleState:drawHUDs(...)
      local owns = self.dramaticShapeShot
                   and not self.blankForAskName
                   and plateImage("enemy") and plateImage("player")
      if owns then
        local oldScissor = { g.getScissor() }
        g.push("all")
        g.setScissor(0, 0, 0, 0)
        local ok, result = pcall(baseDrawHUDs, self, ...)
        g.pop()
        if oldScissor[1] then
          g.setScissor(oldScissor[1], oldScissor[2], oldScissor[3], oldScissor[4])
        else
          g.setScissor()
        end
        if not ok then error(result, 0) end
        return result
      end
      return baseDrawHUDs(self, ...)
    end
  end

  -- Suppress ONLY the native Pokemon status/nameplate surface.  Do not touch
  -- battle.bottom_ui_visible: the stock command menu and message box remain
  -- fully engine-owned.  This hook is evaluated before the native HUD draws,
  -- so there is no one-frame flash of the original plates.
  local statusHookInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("battle.status_hud_visible", function(next, state)
      if state and state.dramaticShapeShot and state._floatingBattleHudPotatoDrawn then
        return false
      end
      return next(state)
    end, 12000)
    statusHookInstalled = true
  end

  -- Compatibility fallback for engines/renderers that bypass the launcher hook.
  -- The drawHUDs scissor above is the visual hard-stop; this predicate fallback
  -- keeps any status-HUD queries consistent without touching bottom UI.
  if not statusHookInstalled then
    local STATUS_KEY = "_floatingBattleHudBaseStatusHUDVisible"
    if not BattleState[STATUS_KEY] then
      BattleState[STATUS_KEY] = BattleState.statusHUDVisible
    end
    local baseStatusHUDVisible = BattleState[STATUS_KEY]
    if type(baseStatusHUDVisible) == "function" then
      function BattleState:statusHUDVisible(...)
        if self.dramaticShapeShot and self._floatingBattleHudPotatoDrawn then
          return false
        end
        return baseStatusHUDVisible(self, ...)
      end
    end
  end

else
  error("FLOATING_BATTLE_HUD: unsupported OverworldBattle HUD API", 0)
end

mod.exports.version = "0.5.7"
mod.exports.floatingHud = FloatingHud
mod.exports.hostMode = hostMode
mod.log:info("Floating Battle HUD 0.5.7 installed over %s %s (%s)",
             tostring(hostId or "voxel host"), tostring(ds.version), tostring(hostMode))
