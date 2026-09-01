-- Floating Battle HUD: Battle Art / Gen 2 adapter.
--
-- Gen 2 uses src/ui/gen2/BattleState and Battle Art presents it through
-- BattleState:drawWidescreen().  This module deliberately stays separate from
-- the legacy Gen 1 wrappers: the renderer is shared in spirit and assets, while
-- battle data and ownership remain generation-specific.

local mod, host, V = ...

local g = love.graphics
local Font = require("src.render.Font")
local BattleState = require("src.battle.BattleState")
local PartyMenu = require("src.ui.gen2.PartyMenu")
local OverworldBattle = V.require("OverworldBattle")
local BattleCam = V.require("BattleCam")

local FloatingHud = {}

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

mod.options:define({
  {
    key = "floating_status_hud",
    type = "toggle",
    label = "FLOATING HP HUD",
    default = true,
  },
  {
    key = "floating_commands",
    type = "toggle",
    label = "FLOATING COMMANDS",
    default = true,
  },
  {
    key = "hud_scale",
    type = "choice",
    label = "HUD SCALE",
    default = 1.0,
    choices = {
      { "x0.8", 0.8 }, { "x1", 1.0 }, { "x1.5", 1.5 },
      { "x2", 2.0 }, { "x2.5", 2.5 }, { "x3", 3.0 },
    },
  },
  {
    key = "wild_dvs",
    type = "toggle",
    label = "WILD DVS",
    default = false,
  },
})

local function optionToggle(key, fallback)
  local ok, value = pcall(function() return mod.options:get(key) end)
  if not ok or value == nil then return fallback end
  return value == true
end

local HUD_SCALE_CHOICES = {
  [0.8] = true, [1.0] = true, [1.5] = true,
  [2.0] = true, [2.5] = true, [3.0] = true,
}

local function hudScaleOption()
  local ok, value = pcall(function() return mod.options:get("hud_scale") end)
  value = ok and tonumber(value) or 1
  return HUD_SCALE_CHOICES[value] and value or 1
end

-- ---------------------------------------------------------------------------
-- Assets and logical layout
-- ---------------------------------------------------------------------------

-- The authored PNGs are x8 masters.  Every intermediate canvas also uses x8,
-- so an authored pixel is copied 1:1 into the working texture.  Only the final
-- perspective projection resamples it; no frame is made from a previously
-- resized frame.
FloatingHud.ASSET_SOURCE_DENSITY = 8
FloatingHud.ASSET_SCALE = 1 / FloatingHud.ASSET_SOURCE_DENSITY
FloatingHud.CANVAS_RENDER_SCALE = FloatingHud.ASSET_SOURCE_DENSITY
FloatingHud.CANVAS_PAD = 5
FloatingHud.SHADOW_PX = 2
FloatingHud.SHADOW_GROW_PX = 3
FloatingHud.TEXT_SHADOW_GROW_PX = 1
FloatingHud.MAX_SCALE = 3
FloatingHud.MARGIN = 4
FloatingHud.REFERENCE_SPAN = 56
FloatingHud.DISTANCE_SCALE_MIN = 0.68
FloatingHud.DISTANCE_SCALE_MAX = 1.32
FloatingHud.CAMERA_CENTER_OFFSET = 0.12
FloatingHud.MAX_ROTATION_DEG = 3
FloatingHud.PERSPECTIVE_DEPTH = -0.20
FloatingHud.PERSPECTIVE_WIDTH_SQUEEZE = 0.06
FloatingHud.PERSPECTIVE_GRID_X = 12
FloatingHud.PERSPECTIVE_GRID_Y = 6
FloatingHud.HEAD_LIFT = { enemy = 1.05, player = 1.05 }
FloatingHud.EXTRA_RISE = 12
FloatingHud.GAP = 3

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
local CAUGHT_ASSET = "assets/hud/caught.png"
local MESSAGE_PLATE_ASSET = "assets/hud/battle_message_plate.png"
local MESSAGE_CURSOR_ASSET = "assets/hud/battle_message_cursor.png"
local COMMAND_PLATE_ASSET = "assets/hud/battle_command_plate.png"
local COMMAND_SELECTOR_ASSET = "assets/hud/battle_command_selector.png"
local FIGHT_PLATE_ASSET = "assets/hud/fight_command_plate.png"
local FIGHT_DIVIDER_ASSET = "assets/hud/fight_command_divider.png"
local PKMN_PLATE_ASSET = "assets/hud/pkmn_command_plate.png"
local FIGHT_CATEGORY_ASSETS = {
  PHYSICAL = "assets/hud/fight_kind_status.png",
  SPECIAL = "assets/hud/fight_kind_special.png",
  STATUS = "assets/hud/fight_kind_physical.png",
}
local TRAINER_BALL_ASSETS = {
  alive = "assets/hud/battleplate_ball.png",
  active = "assets/hud/battleplate_ball_active.png",
  defeated = "assets/hud/battleplate_ball_defeated.png",
  empty = "assets/hud/battleplate_ball_empty.png",
}
local STAT_STAGE_ASSETS = {
  attack = "attack",
  defense = "defense",
  speed = "speed",
  specialAttack = "sattack",
  specialDefense = "sdefense",
  accuracy = "accuracy",
  evasion = "evasion",
}
local STAT_STAGE_FOLDER = "assets/hud/stat_stages/"

-- `gender.x` and `gender.y` are the requested independent position modifiers.
-- They are logical HUD pixels and can be tuned without moving level/name/status.
FloatingHud.LAYOUT = {
  enemy = {
    name = { x = 13.0, y = 1.0 },
    status = { x = 5.0, y = 11.5 },
    level = { x = 64.5, y = 9.5, scale = 1.15 },
    gender = { x = 81.0, y = 9.5, scale = 1.15 },
    caught = { x = 97.0, y = 8.8 },
    hpFill = { x = 33.5, y = 23.25, w = 61.25, h = 2.50 },
    hpNumbers = { right = 97.0, y = 28.5 },
    dvs = { y = 48.5, scale = 0.75 },
  },
  player = {
    name = { x = 13.0, y = 1.0 },
    status = { x = 7.0, y = 11.5 },
    level = { x = 60.0, y = 9.5, scale = 1.15 },
    gender = { x = 76.5, y = 9.5, scale = 1.15 },
    hpFill = { x = 29.5, y = 23.25, w = 61.25, h = 2.50 },
    hpNumbers = { right = 93.5, y = 28.5 },
    expFill = { x = 5.5, y = 41.9, w = 84.0, h = 2.5 },
  },
}

FloatingHud.TRAINER_TEAM = {
  slots = 6, gap = 1.75, rowGap = 1.5, scale = 1.0, yOffset = -15.0,
}
FloatingHud.STAT_STAGES = {
  -- Independent anchoring offsets, in logical HUD pixels. Negative X moves
  -- left and positive X moves right; negative Y moves up and positive Y down.
  -- They move only this modifier block, never the battleplate itself.
  player = { attach = "left",  x = 0.0, y = 0.0 },
  enemy  = { attach = "right", x =  0.0, y = 0.0 },
  scale = 1.2,
  columnGap = 1.2,
  rowGap = 0.2,
  rowsPerColumn = 3,
  anchorHeight = 25.125,
  valueX = 7.25,
  valueY = 0.75,
  accuracyText = "ACC",
  accuracyTextScale = 0.45,
}
FloatingHud.COMMAND = {
  xGap = 18, yOffset = 4, scale = 1,
  selectorX = 9, selectorYOffset = -1,
  textX = 20, firstY = 13, rowStep = 22,
  labels = { "FIGHT", "PKMN", "ITEM", "RUN" },
}
FloatingHud.FIGHT = {
  xGap = 27, yOffset = 30, scale = 1,
  contentYOffset = -10, canvasTopPad = 12,
  listScale = 1.07, selectorX = 43, selectorYOffset = 0,
  typeX = 55, typeYOffset = 0, typeW = 4, typeH = 7,
  textX = 65, ppRight = 216, ppScale = 1, ppYOffset = -1,
  firstY = 49, rowStep = 17,
  dividerX = 55, dividerY = 30, dividerScale = 1,
  statsY = 25, statsScale = 1, statsAccPercentX = 225,
  statsAccGap = 1, statsCategoryX = 158, statsCategoryY = 24,
  statsCategoryScale = 1, statsPowerX = 170,
}
FloatingHud.PKMN = {
  xGap = 20, yOffset = -10, scale = 1,
  selectorX = 55, selectorYOffset = -1,
  iconX = 63, textX = 82, hpX = 82, hpW = 72,
  firstY = 10, rowStep = 17,
}
FloatingHud.PARTY_CHOICE = {
  logicalW = 96, logicalH = 78,
  rightOffset = -2, aboveGap = 2,
  centerX = 48, firstCenterY = 14, rowStep = 25,
  selectedScale = 1.65, idleScale = 1.05,
}
FloatingHud.MESSAGE = {
  xOffset = 10, yOffset = 35, scale = 1,
  textX = 10, line1Y = 9, line2Y = 27,
  cursorRight = 9, cursorBottom = 6,
  cameraSignalGain = 2.5, cameraInfluence = 0.8,
  perspectiveBias = -0.28, baseRotationDeg = -7,
  cameraRotationDeg = 2, perspectiveDepth = 0.32,
  perspectiveWidthSqueeze = 0.12, pitchSignalGain = 1,
  pitchInfluence = 0.35, pitchPerspectiveDepth = 0.16,
  pitchHeightSqueeze = 0.05,
}

FloatingHud.MOVE_TYPE_COLORS = {
  FIGHTING = { 0.84, 0.00, 0.59, 1 }, NORMAL = { 0.71, 0.75, 0.79, 1 },
  ELECTRIC = { 0.92, 0.80, 0.26, 1 }, POISON = { 0.52, 0.39, 0.80, 1 },
  FIRE = { 1.00, 0.26, 0.00, 1 }, BUG = { 0.59, 0.67, 0.20, 1 },
  DRAGON = { 0.15, 0.35, 0.64, 1 }, GHOST = { 0.41, 0.38, 0.65, 1 },
  GRASS = { 0.24, 0.79, 0.13, 1 }, ROCK = { 0.78, 0.67, 0.58, 1 },
  GROUND = { 0.74, 0.45, 0.25, 1 }, ICE = { 0.66, 0.86, 0.79, 1 },
  WATER = { 0.27, 0.73, 1.00, 1 }, PSYCHIC = { 1.00, 0.48, 0.79, 1 },
  FLYING = { 0.56, 0.68, 0.94, 1 }, DARK = { 0.35, 0.28, 0.25, 1 },
  STEEL = { 0.62, 0.67, 0.72, 1 },
}

local images = {}
local function assetImage(path)
  if images[path] ~= nil then return images[path] or nil end
  local ok, image = pcall(function() return mod.assets:image(path) end)
  if ok and image then
    pcall(image.setFilter, image, "nearest", "nearest")
    images[path] = image
    return image
  end
  images[path] = false
  return nil
end

local function assetLogicalSize(path)
  local image = assetImage(path)
  if not image then return nil, nil end
  local w, h = image:getDimensions()
  return w * FloatingHud.ASSET_SCALE, h * FloatingHud.ASSET_SCALE
end

local function plateImage(side) return assetImage(PLATE_ASSETS[side]) end
local function plateSize(side) return assetLogicalSize(PLATE_ASSETS[side]) end

-- ---------------------------------------------------------------------------
-- Drawing primitives
-- ---------------------------------------------------------------------------

local function clamp(value, lo, hi)
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

local function textWidth(text)
  local ok, width = pcall(Font.width, tostring(text or ""))
  return ok and tonumber(width) or #(tostring(text or "")) * 8
end

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

local function drawMaskedFont(text, x, y, r, gg, b, a)
  local shader = getTextMaskShader()
  if not shader then
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

local function eachShadowOffset(k, extraScale, fn)
  local denom = math.max(0.001, k * (extraScale or 1))
  local origin = FloatingHud.SHADOW_PX / denom
  local grow = math.max(0, FloatingHud.SHADOW_GROW_PX) / denom
  fn(origin, origin)
  if grow <= 0 then return end
  for _, offset in ipairs({
    {-grow, 0}, {grow, 0}, {0, -grow}, {0, grow},
    {-grow, -grow}, {grow, -grow}, {-grow, grow}, {grow, grow},
  }) do
    fn(origin + offset[1], origin + offset[2])
  end
end

-- Keep text shadows coherent. Build a compact outline around the original
-- glyph, then add the independent down-right drop shadow. Structural x8 assets
-- retain their separate chunky expansion above.
local function eachTextShadowOffset(k, extraScale, fn)
  local denom = math.max(0.001, k * (extraScale or 1))
  local origin = FloatingHud.SHADOW_PX / denom
  local growPx = math.max(0, math.floor(
    (tonumber(FloatingHud.TEXT_SHADOW_GROW_PX) or 0) + 0.5))
  if growPx > 0 then
    for dy = -growPx, growPx do
      for dx = -growPx, growPx do
        fn(dx / denom, dy / denom)
      end
    end
  end
  fn(origin, origin)
end

local function drawShadowText(text, x, y, k, scale)
  text, scale = tostring(text or ""), scale or 1
  if scale ~= 1 then
    g.push()
    g.translate(x, y)
    g.scale(scale, scale)
    eachTextShadowOffset(k, scale, function(sx, sy)
      drawMaskedFont(text, sx, sy, 0, 0, 0, 1)
    end)
    drawMaskedFont(text, 0, 0, 1, 1, 1, 1)
    g.pop()
    return
  end
  eachTextShadowOffset(k, 1, function(sx, sy)
    drawMaskedFont(text, x + sx, y + sy, 0, 0, 0, 1)
  end)
  drawMaskedFont(text, x, y, 1, 1, 1, 1)
end

local function drawShadowAsset(image, x, y, k, scale)
  if not image then return false end
  scale = scale or FloatingHud.ASSET_SCALE
  g.setColor(0, 0, 0, 1)
  eachShadowOffset(k, 1, function(sx, sy)
    g.draw(image, x + sx, y + sy, 0, scale, scale)
  end)
  g.setColor(1, 1, 1, 1)
  g.draw(image, x, y, 0, scale, scale)
  return true
end

local function drawPercentGlyph(x, y, k, scale)
  scale = math.max(0.5, tonumber(scale) or 1)
  local px = math.max(0.75, scale)
  local dots = {
    {0,0},{1,0},{0,1},{1,1},{5,5},{6,5},{5,6},{6,6},
    {5,0},{4,1},{3,2},{3,3},{2,4},{1,5},{0,6},
  }
  local function drawAt(ox, oy, color)
    g.setColor(color, color, color, 1)
    for _, point in ipairs(dots) do
      g.rectangle("fill", x + ox + point[1] * px,
        y + oy + point[2] * px, px, px)
    end
  end
  eachTextShadowOffset(k, scale, function(sx, sy) drawAt(sx, sy, 0) end)
  drawAt(0, 0, 1)
end

local cardCanvases, panelCanvases, meshes = {}, {}, {}

local function workingCanvas(cache, key, logicalW, logicalH, topExtra)
  local pad = FloatingHud.CANVAS_PAD
  local raster = FloatingHud.CANVAS_RENDER_SCALE
  topExtra = math.max(0, tonumber(topExtra) or 0)
  local logicalCW = logicalW + pad * 2
  local logicalCH = logicalH + pad * 2 + topExtra
  local cw, ch = math.ceil(logicalCW * raster), math.ceil(logicalCH * raster)
  local canvas = cache[key]
  if not canvas or canvas:getWidth() ~= cw or canvas:getHeight() ~= ch then
    local ok, made = pcall(g.newCanvas, cw, ch, { dpiscale = 1 })
    if not (ok and made) then return nil end
    -- Source art stays nearest; this completed master-density surface is sampled
    -- linearly exactly once by the final perspective mesh.
    pcall(made.setFilter, made, "linear", "linear")
    canvas = made
    cache[key] = canvas
  end
  return canvas, logicalCW, logicalCH, pad, raster
end

local function rotatedPoint(x, y, angle)
  if angle == 0 then return x, y end
  local c, s = math.cos(angle), math.sin(angle)
  return x * c - y * s, x * s + y * c
end

local function drawPerspectiveCanvas(canvas, cx, cy, w, h, signal, roll, key,
                                     depthOverride, squeezeOverride,
                                     pitchSignal, pitchDepth, pitchSqueeze)
  signal = clamp(signal or 0, -1, 1)
  local depth = depthOverride ~= nil and clamp(depthOverride, -0.45, 0.45)
    or clamp(FloatingHud.PERSPECTIVE_DEPTH, -0.45, 0.45)
  local squeeze = squeezeOverride ~= nil and clamp(squeezeOverride, 0, 0.35)
    or clamp(FloatingHud.PERSPECTIVE_WIDTH_SQUEEZE, 0, 0.35)
  local leftScale, rightScale = 1 - signal * depth, 1 + signal * depth
  local widthScale = 1 - math.abs(signal) * squeeze
  local lx, rx = -w * 0.5 * widthScale, w * 0.5 * widthScale
  local lhy, rhy = h * 0.5 * leftScale, h * 0.5 * rightScale
  pitchSignal = clamp(tonumber(pitchSignal) or 0, -1, 1)
  pitchDepth = clamp(tonumber(pitchDepth) or 0, -0.35, 0.35)
  pitchSqueeze = clamp(tonumber(pitchSqueeze) or 0, 0, 0.25)
  local topWidth = 1 - pitchSignal * pitchDepth
  local bottomWidth = 1 + pitchSignal * pitchDepth
  local heightScale = 1 - math.abs(pitchSignal) * pitchSqueeze
  local x1,y1 = rotatedPoint(lx * topWidth, -lhy * heightScale, roll)
  local x2,y2 = rotatedPoint(rx * topWidth, -rhy * heightScale, roll)
  local x3,y3 = rotatedPoint(rx * bottomWidth, rhy * heightScale, roll)
  local x4,y4 = rotatedPoint(lx * bottomWidth, lhy * heightScale, roll)
  local gx, gy = FloatingHud.PERSPECTIVE_GRID_X, FloatingHud.PERSPECTIVE_GRID_Y
  local vertices = {}
  for iy = 0, gy do
    local v = iy / gy
    for ix = 0, gx do
      local u = ix / gx
      local tx, ty = x1 + (x2-x1)*u, y1 + (y2-y1)*u
      local bx, by = x4 + (x3-x4)*u, y4 + (y3-y4)*u
      vertices[#vertices + 1] = { tx + (bx-tx)*v, ty + (by-ty)*v, u, v }
    end
  end
  local meshKey = key .. ":" .. gx .. "x" .. gy
  local mesh = meshes[meshKey]
  if not mesh then
    mesh = g.newMesh(vertices, "triangles", "dynamic")
    local map, row = {}, gx + 1
    for iy = 0, gy - 1 do
      for ix = 0, gx - 1 do
        local a = iy * row + ix + 1
        local b, d = a + 1, a + row
        local c = d + 1
        map[#map+1]=a; map[#map+1]=b; map[#map+1]=c
        map[#map+1]=a; map[#map+1]=c; map[#map+1]=d
      end
    end
    mesh:setVertexMap(map)
    meshes[meshKey] = mesh
  else
    mesh:setVertices(vertices)
  end
  mesh:setTexture(canvas)
  g.setColor(1, 1, 1, 1)
  g.draw(mesh, cx, cy)
end

-- ---------------------------------------------------------------------------
-- Battle Art projection and normalized Gen 2 data
-- ---------------------------------------------------------------------------

local function battleShot()
  local ok, shot = pcall(OverworldBattle.shot)
  return ok and shot and shot.canvas and shot or nil
end

local function cameraYawSignal()
  local arena = nil
  if type(OverworldBattle.arena) == "function" then
    local ok, value = pcall(OverworldBattle.arena)
    if ok then arena = value end
  end
  local range = 1
  if arena and BattleCam and type(BattleCam.orbitRange) == "function" then
    local ok, value = pcall(BattleCam.orbitRange, arena)
    if ok and tonumber(value) and value > 0 then range = value end
  end
  local orbit = clamp(tonumber(BattleCam and BattleCam.orbit) or 0, 0, 1)
  local yaw = -orbit * range
  if BattleCam and not BattleCam.still and tonumber(BattleCam.PAN_PERIOD)
      and BattleCam.PAN_PERIOD > 0 then
    yaw = yaw + (tonumber(BattleCam.PAN_YAW) or 0)
      * math.sin(2 * math.pi * (tonumber(BattleCam.t) or 0) / BattleCam.PAN_PERIOD)
  end
  return clamp(yaw / math.max(range, 1e-6)
    + FloatingHud.CAMERA_CENTER_OFFSET, -1, 1)
end

local function cameraPitchSignal()
  return clamp(tonumber(BattleCam and BattleCam.pitch) or 0, 0, 1)
end

local function hudRotation()
  return math.rad(FloatingHud.MAX_ROTATION_DEG * cameraYawSignal())
end

local function uiScale(shot)
  local source = tonumber(shot and shot.scale) or 1
  return clamp(math.floor(source * 0.5 + 0.5), 1, FloatingHud.MAX_SCALE)
    * hudScaleOption()
end

local function distanceScale(shot, side)
  local span = tonumber(shot and shot[side .. "Span"]) or FloatingHud.REFERENCE_SPAN
  return clamp(span / FloatingHud.REFERENCE_SPAN,
    FloatingHud.DISTANCE_SCALE_MIN, FloatingHud.DISTANCE_SCALE_MAX)
end

local function worldRectFor(shot, side)
  local pos = shot and shot[side]
  local logicalW, logicalH = plateSize(side)
  if not (pos and logicalW and logicalH) then return nil end
  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, side)
  local span = tonumber(shot[side .. "Span"]) or FloatingHud.REFERENCE_SPAN
  local footX = shot.lx + pos[1] * s
  local headY = shot.ly + (pos[2] - span * FloatingHud.HEAD_LIFT[side]) * s
  local w, h = logicalW * drawScale, logicalH * drawScale
  local x = footX - w * 0.5
  local y = headY - h - FloatingHud.GAP * drawScale
    - FloatingHud.EXTRA_RISE * baseScale
  local margin = FloatingHud.MARGIN
  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = clamp(y, margin, math.max(margin, shot.ph - h - margin))
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function hudCleared(state, side)
  if type(state.hudCleared) ~= "function" then return false end
  local ok, value = pcall(state.hudCleared, state, side)
  return ok and value == true
end

local function monName(state, mon)
  if type(state.name) == "function" then
    local ok, value = pcall(state.name, state, mon)
    if ok and value then return tostring(value) end
  end
  return tostring(mon and (mon.nickname or mon.name or mon.species) or "?")
end

local function statusTag(state, mon, side)
  if type(state.statusTag) == "function" then
    local ok, value = pcall(state.statusTag, state, mon, side)
    if ok then return value end
  end
  local map = {
    sleep="SLP", poison="PSN", toxic="PSN", burn="BRN",
    freeze="FRZ", paralyze="PAR",
  }
  return mon and (map[mon.status] or mon.status) or nil
end

local function genderSymbol(state, mon)
  if type(state.genderSymbol) == "function" then
    local ok, value = pcall(state.genderSymbol, state, mon)
    if ok then return value end
  end
  return mon and ((mon.gender == "male" and "♂")
    or (mon.gender == "female" and "♀")) or nil
end

local function shownHp(state, mon, side)
  local hp = mon and mon.hp or 0
  if type(state.hudHp) == "function" then
    local ok, value = pcall(state.hudHp, state, mon, side)
    if ok and tonumber(value) then hp = value end
  end
  local maxHp = mon and (mon.maxHp or (mon.stats and mon.stats.hp)) or 1
  maxHp = math.max(1, tonumber(maxHp) or 1)
  return clamp(math.floor((tonumber(hp) or 0) + 0.5), 0, maxHp), maxHp
end

local function expRatio(state, mon)
  if not mon then return 0 end
  local pixels = tonumber(state.shownExp)
  if pixels == nil and type(state.expPixels) == "function" then
    local ok, value = pcall(state.expPixels, state, mon, mon.level, mon.experience)
    if ok then pixels = tonumber(value) end
  end
  return clamp((pixels or 0) / 64, 0, 1)
end

local function normalizedMon(state, side)
  if type(state.activeMon) ~= "function" then return nil end
  local ok, mon = pcall(state.activeMon, state, side)
  if not (ok and type(mon) == "table") then return nil end
  local hp, maxHp = shownHp(state, mon, side)
  local level = side == "player" and (state.shownLevel or mon.level) or mon.level
  return {
    mon = mon, name = monName(state, mon), level = level or 1,
    hp = hp, maxHp = maxHp, status = statusTag(state, mon, side),
    gender = genderSymbol(state, mon),
    caught = side == "enemy" and state.battle and state.battle.wild
      and state.caughtMark == true,
    expRatio = side == "player" and expRatio(state, mon) or 0,
  }
end

local GEN2_STAGE_ORDER = {
  { id = "attack", label = "ATK" },
  { id = "defense", label = "DEF" },
  { id = "speed", label = "SPD" },
  { id = "specialAttack", label = "SP.ATK" },
  { id = "specialDefense", label = "SP.DEF" },
  { id = "accuracy", label = "ACC" },
  { id = "evasion", label = "EVA" },
}

local function normalizedGen2StatStages(state, side)
  local battle = state and state.battle
  local source = battle and battle.stages and battle.stages[side] or nil
  local out = {}
  for _, def in ipairs(GEN2_STAGE_ORDER) do
    local value = source and tonumber(source[def.id]) or 0
    out[def.id] = clamp(math.floor(value or 0), -6, 6)
  end
  return out
end

function FloatingHud.getPlayerStatStages(state)
  return normalizedGen2StatStages(state, "player")
end

function FloatingHud.getEnemyStatStages(state)
  return normalizedGen2StatStages(state, "enemy")
end

local function activeGen2StatStages(state, side)
  local stages = normalizedGen2StatStages(state, side)
  local active = {}
  for _, def in ipairs(GEN2_STAGE_ORDER) do
    local stage = stages[def.id]
    if stage ~= 0 then
      active[#active + 1] = { id = def.id, label = def.label, stage = stage }
    end
  end
  return active
end

local function hpDv(dvs)
  if not (dvs and dvs.attack ~= nil and dvs.defense ~= nil
      and dvs.speed ~= nil and dvs.special ~= nil) then return nil end
  return (dvs.attack % 2) * 8 + (dvs.defense % 2) * 4
    + (dvs.speed % 2) * 2 + (dvs.special % 2)
end

local function dvText(mon)
  local dvs = mon and mon.dvs
  local hp = hpDv(dvs)
  if hp == nil then return nil end
  return string.format("%02d/%02d/%02d/%02d/%02d",
    hp, dvs.attack, dvs.defense, dvs.speed, dvs.special)
end

local function stageAssetPath(id, tone)
  local stem = STAT_STAGE_ASSETS[id]
  if not stem then return nil end
  return STAT_STAGE_FOLDER .. "battleplate_" .. stem .. "_" .. tone .. ".png"
end

local function stageNumberPath(stage, tone)
  return STAT_STAGE_FOLDER .. "battleplate_" .. tostring(math.abs(stage))
    .. "_" .. tone .. ".png"
end

local function drawColoredShadowText(text, x, y, k, scale, color)
  text, scale = tostring(text or ""), tonumber(scale) or 1
  g.push(); g.translate(x, y); g.scale(scale, scale)
  eachTextShadowOffset(k, scale, function(sx, sy)
    drawMaskedFont(text, sx, sy, 0, 0, 0, 1)
  end)
  drawMaskedFont(text, 0, 0, color[1], color[2], color[3], 1)
  g.pop()
end

local function drawStatStageAsset(image, x, y, k, scale)
  if not image then return false end
  scale = scale or FloatingHud.ASSET_SCALE
  g.setColor(0,0,0,1)
  eachTextShadowOffset(k, 1, function(sx, sy)
    g.draw(image, x+sx, y+sy, 0, scale, scale)
  end)
  g.setColor(1,1,1,1)
  g.draw(image, x, y, 0, scale, scale)
  return true
end

local function statStageMetrics(active)
  if #active == 0 then return nil end
  local cfg = FloatingHud.STAT_STAGES
  local icon = assetImage(stageAssetPath("attack", "buff"))
  local number = assetImage(stageNumberPath(1, "buff"))
  if not (icon and number) then return nil end
  local iconW, iconH = icon:getDimensions()
  local numberW, numberH = number:getDimensions()
  iconW, iconH = iconW * FloatingHud.ASSET_SCALE,
    iconH * FloatingHud.ASSET_SCALE
  numberW, numberH = numberW * FloatingHud.ASSET_SCALE,
    numberH * FloatingHud.ASSET_SCALE
  local itemW = math.max(iconW, (cfg.valueX or 7.25) + numberW)
  if not assetImage(stageAssetPath("accuracy", "buff")) then
    local accuracyW = textWidth(cfg.accuracyText or "ACC")
      * (cfg.accuracyTextScale or 0.45) + 0.5 + numberW
    itemW = math.max(itemW, accuracyW)
  end
  local itemH = math.max(iconH, (cfg.valueY or 0.75) + numberH)
  local stepY = itemH + (cfg.rowGap or 0)
  local rowsPerColumn = math.max(1,
    math.floor(tonumber(cfg.rowsPerColumn) or 3))
  local rows = math.min(rowsPerColumn, #active)
  if #active > rowsPerColumn * 2 then rows = rowsPerColumn + 1 end
  return {
    itemW = itemW, itemH = itemH, stepY = stepY,
    blockW = itemW * 2 + (cfg.columnGap or 1),
    blockH = itemH + math.max(0, rows - 1) * stepY,
  }
end

local function statStageSlot(side, index, metrics)
  local gap = FloatingHud.STAT_STAGES.columnGap or 1
  local rows = math.max(1, math.floor(
    tonumber(FloatingHud.STAT_STAGES.rowsPerColumn) or 3))
  local leftX, rightX = 0, metrics.itemW + gap
  local nearX = side == "player" and rightX or leftX
  local farX = side == "player" and leftX or rightX
  if index <= rows then return nearX, (index - 1) * metrics.stepY end
  if index <= rows * 2 then
    return farX, (index - rows - 1) * metrics.stepY
  end
  return farX, rows * metrics.stepY
end

local function renderStatStageCanvas(side, active, k)
  local cfg = FloatingHud.STAT_STAGES
  local metrics = statStageMetrics(active)
  if not metrics then return nil end
  local scale = math.max(0.25, tonumber(cfg.scale) or 1)
  local logicalW, logicalH = metrics.blockW * scale, metrics.blockH * scale
  local canvas, cw, ch, pad, raster = workingCanvas(panelCanvases,
    "stat_stages_" .. side, logicalW, logicalH)
  if not canvas then return nil end
  local previous = g.getCanvas()
  local ok, err = pcall(function()
    g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
    g.setBlendMode("alpha"); g.setShader(); g.setColor(1,1,1,1)
    g.push(); g.scale(raster,raster); g.translate(pad,pad); g.scale(scale,scale)
    for index, entry in ipairs(active) do
      local x, y = statStageSlot(side, index, metrics)
      local tone = entry.stage > 0 and "buff" or "debuff"
      local icon = assetImage(stageAssetPath(entry.id, tone) or "")
      local valueX = cfg.valueX or 7.25
      if icon then
        drawStatStageAsset(icon, x, y, k, FloatingHud.ASSET_SCALE)
      else
        local color = tone == "buff"
          and { 107 / 255, 252 / 255, 110 / 255 }
          or { 232 / 255, 101 / 255, 98 / 255 }
        local fallback = cfg.accuracyText or entry.label
        local fallbackScale = cfg.accuracyTextScale or 0.45
        drawColoredShadowText(fallback, x, y + 1.5, k, fallbackScale, color)
        valueX = math.max(valueX,
          textWidth(fallback) * fallbackScale + 0.5)
      end
      local number = assetImage(stageNumberPath(entry.stage, tone))
      if number then
        drawStatStageAsset(number, x + valueX,
          y + (cfg.valueY or 0.75), k, FloatingHud.ASSET_SCALE)
      end
    end
    g.pop()
  end)
  if previous then g.setCanvas(previous) else g.setCanvas() end
  g.setShader(); g.setBlendMode("alpha"); g.setColor(1,1,1,1)
  if not ok then error(err, 0) end
  return canvas, cw, ch, logicalW, logicalH
end

local function drawStatStageBlock(state, shot, rect, k, side)
  local active = activeGen2StatStages(state, side)
  if #active == 0 then return false end
  local canvas, cw, ch, blockW, blockH = renderStatStageCanvas(side, active, k)
  if not canvas then return false end
  local cfg = FloatingHud.STAT_STAGES[side]
  local attachLeft = cfg.attach == "left"
  local edge = attachLeft and rect[1] or (rect[1] + rect[3])
  local cx = edge + (cfg.x or 0) * k
    + (attachLeft and -1 or 1) * blockW * k * 0.5
  local blockTop = rect[2] + rect[4] * 0.5 + (cfg.y or 0) * k
    - (FloatingHud.STAT_STAGES.anchorHeight or blockH) * k * 0.5
  local cy = blockTop + blockH * k * 0.5
  local margin = FloatingHud.MARGIN or 4
  cx = clamp(cx, margin + blockW * k * 0.5,
    shot.pw - margin - blockW * k * 0.5)
  cy = clamp(cy, margin + blockH * k * 0.5,
    shot.ph - margin - blockH * k * 0.5)
  drawPerspectiveCanvas(canvas, cx, cy, cw*k, ch*k,
    cameraYawSignal(), hudRotation(), side .. "_stat_stages")
  return true
end

-- ---------------------------------------------------------------------------
-- Status cards
-- ---------------------------------------------------------------------------

local function drawHpFill(layout, ratio)
  local rect = layout.hpFill
  ratio = clamp(ratio, 0, 1)
  if ratio <= 0 then return end
  if ratio <= 0.20 then g.setColor(0.95, 0.16, 0.12, 1)
  elseif ratio <= 0.50 then g.setColor(1.00, 0.82, 0.10, 1)
  else g.setColor(0.15, 0.92, 0.30, 1) end
  g.rectangle("fill", rect.x, rect.y, rect.w * ratio, rect.h)
end

local function drawExpFill(layout, ratio)
  local rect = layout.expFill
  if not rect or ratio <= 0 then return end
  g.setColor(0.12, 0.62, 1, 1)
  g.rectangle("fill", rect.x, rect.y, rect.w * clamp(ratio, 0, 1), rect.h)
end

local function drawStatus(tag, x, y, k)
  if not tag then return end
  local image = assetImage(STATUS_ASSETS[tag] or "")
  if image then drawShadowAsset(image, x, y, k) else drawShadowText(tag, x, y, k) end
end

local function renderCardCanvas(state, side, view, k, logicalW, logicalH)
  local plate = plateImage(side)
  if not plate then return nil end
  local canvas, logicalCW, logicalCH, pad, raster =
    workingCanvas(cardCanvases, side, logicalW, logicalH)
  if not canvas then return nil end
  local layout = FloatingHud.LAYOUT[side]
  local previous = g.getCanvas()
  local ok, err = pcall(function()
    g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
    g.setBlendMode("alpha"); g.setShader(); g.setColor(1,1,1,1)
    g.push(); g.scale(raster, raster); g.translate(pad, pad)
    g.setColor(0,0,0,1)
    eachShadowOffset(k, 1, function(sx, sy)
      g.draw(plate, sx, sy, 0, FloatingHud.ASSET_SCALE, FloatingHud.ASSET_SCALE)
    end)
    drawHpFill(layout, view.hp / view.maxHp)
    if side == "player" then drawExpFill(layout, view.expRatio) end
    g.setColor(1,1,1,1)
    g.draw(plate, 0, 0, 0, FloatingHud.ASSET_SCALE, FloatingHud.ASSET_SCALE)
    drawShadowText(view.name, layout.name.x, layout.name.y, k)
    drawStatus(view.status, layout.status.x, layout.status.y, k)
    drawShadowText(tostring(view.level), layout.level.x, layout.level.y, k,
      layout.level.scale)
    if view.gender and layout.gender then
      drawShadowText(view.gender, layout.gender.x, layout.gender.y, k,
        layout.gender.scale)
    end
    if view.caught then
      local caught = assetImage(CAUGHT_ASSET)
      if caught then drawShadowAsset(caught, layout.caught.x, layout.caught.y, k)
      else drawShadowText("C", layout.caught.x, layout.caught.y, k) end
    end
    local hpText = tostring(view.hp) .. "/" .. tostring(view.maxHp)
    drawShadowText(hpText, layout.hpNumbers.right - textWidth(hpText),
      layout.hpNumbers.y, k)
    local battle = state.battle
    if side == "enemy" and battle and battle.wild
        and optionToggle("wild_dvs", false) then
      local text = dvText(view.mon)
      if text then
        local scale = layout.dvs.scale
        drawShadowText(text, (logicalW - textWidth(text) * scale) / 2,
          layout.dvs.y, k, scale)
      end
    end
    g.pop()
  end)
  if previous then g.setCanvas(previous) else g.setCanvas() end
  g.setShader(); g.setBlendMode("alpha"); g.setColor(1,1,1,1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function teamState(state, slot)
  local battle = state and state.battle
  local party = battle and battle.enemyParty
  local mon = party and party[slot]
  if not mon then return "empty" end
  if slot == tonumber(battle.enemyIndex) and (tonumber(mon.hp) or 0) > 0 then
    return "active"
  end
  return (tonumber(mon.hp) or 0) > 0 and "alive" or "defeated"
end

local function drawTrainerTeam(state, shot, rect, k)
  local battle = state and state.battle
  if not (battle and not battle.wild and type(battle.enemyParty) == "table") then
    return false
  end
  local cfg = FloatingHud.TRAINER_TEAM
  local source = assetImage(TRAINER_BALL_ASSETS.alive)
  if not source then return false end
  local iw, ih = source:getDimensions()
  local iconScale = FloatingHud.ASSET_SCALE * cfg.scale
  local iconW, iconH = iw * iconScale, ih * iconScale
  local logicalW = cfg.slots * iconW + (cfg.slots - 1) * cfg.gap
  local canvas, cw, ch, pad, raster =
    workingCanvas(panelCanvases, "trainer_team", logicalW, iconH)
  if not canvas then return false end
  local previous = g.getCanvas()
  g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
  g.push(); g.scale(raster,raster); g.translate(pad,pad)
  for i = 1, cfg.slots do
    local image = assetImage(TRAINER_BALL_ASSETS[teamState(state, i)])
    if image then drawShadowAsset(image, (i-1)*(iconW+cfg.gap), 0, k, iconScale) end
  end
  g.pop(); if previous then g.setCanvas(previous) else g.setCanvas() end
  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] + (cfg.rowGap + cfg.yOffset) * k + iconH*k*0.5
  drawPerspectiveCanvas(canvas, cx, cy, cw*k, ch*k,
    cameraYawSignal(), hudRotation(), "enemy_team")
  return true
end

local function drawCard(state, shot, side)
  local view = normalizedMon(state, side)
  if not view then return false end
  local rect, k, logicalW, logicalH = worldRectFor(shot, side)
  if not rect then return false end
  local canvas, cw, ch = renderCardCanvas(state, side, view, k, logicalW, logicalH)
  if not canvas then return false end
  drawPerspectiveCanvas(canvas, rect[1]+rect[3]/2, rect[2]+rect[4]/2,
    cw*k, ch*k, cameraYawSignal(), hudRotation(), side)
  drawStatStageBlock(state, shot, rect, k, side)
  if side == "enemy" then drawTrainerTeam(state, shot, rect, k) end
  return true
end

-- ---------------------------------------------------------------------------
-- Gen 2 battle-flow panels
-- ---------------------------------------------------------------------------

local function movesFor(state)
  if type(state.playerMoves) == "function" then
    local ok, moves = pcall(state.playerMoves, state)
    if ok and type(moves) == "table" then return moves end
  end
  local mon = state.battle and state.battle.player
  return mon and mon.moves or {}
end

local function moveDef(state, move)
  local id = type(move) == "table" and move.id or move
  return state.game and state.game.data and state.game.data.moves
    and state.game.data.moves[id] or nil
end

local SPECIAL_TYPES = {
  FIRE=true, WATER=true, GRASS=true, ELECTRIC=true, ICE=true,
  PSYCHIC=true, DRAGON=true, DARK=true,
}

local function typeKey(state, move)
  local def = moveDef(state, move)
  local key = tostring(def and def.type or "NORMAL"):upper()
  if key == "PSYCHIC_TYPE" then key = "PSYCHIC" end
  return key
end

local function moveCategory(state, move)
  local def = moveDef(state, move)
  if not (def and tonumber(def.power) and tonumber(def.power) > 0) then return "STATUS" end
  return SPECIAL_TYPES[typeKey(state, move)] and "SPECIAL" or "PHYSICAL"
end

local function commandRect(shot, asset, layout)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(asset)
  if not (logicalW and logicalH) then return nil end
  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player") * (layout.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w, h = logicalW * drawScale, logicalH * drawScale
  local x = footX - w - (layout.xGap or 10) * baseScale
  local y = footY - h + (layout.yOffset or 0) * baseScale
  local margin = FloatingHud.MARGIN
  x = clamp(x, margin, math.max(margin, shot.pw-w-margin))
  y = math.max(margin, y)
  return {x,y,w,h}, drawScale, logicalW, logicalH
end

local function fightRect(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(FIGHT_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end
  local layout, s = FloatingHud.FIGHT, tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player") * layout.scale
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w, h = logicalW*drawScale, logicalH*drawScale
  local x = footX + layout.xGap*baseScale
  local y = footY - h + layout.yOffset*baseScale
  local margin = FloatingHud.MARGIN
  x = clamp(x, margin, math.max(margin, shot.pw-w-margin))
  return {x,math.max(margin,y),w,h}, drawScale, logicalW, logicalH
end

local function renderCommand(state, k, logicalW, logicalH)
  local plate, selector = assetImage(COMMAND_PLATE_ASSET), assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector) then return nil end
  local canvas, cw, ch, pad, raster =
    workingCanvas(panelCanvases, "command", logicalW, logicalH)
  if not canvas then return nil end
  local layout, selected = FloatingHud.COMMAND,
    clamp(math.floor(tonumber(state.menuIndex) or 1), 1, 4)
  local previous = g.getCanvas()
  g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
  g.push(); g.scale(raster,raster); g.translate(pad,pad)
  drawShadowAsset(plate, 0, 0, k)
  for i = 1, 4 do
    local y = layout.firstY + (i-1)*layout.rowStep
    if i == selected then
      drawShadowAsset(selector, layout.selectorX, y+layout.selectorYOffset, k)
    end
    drawShadowText(layout.labels[i], layout.textX, y, k)
  end
  g.pop(); if previous then g.setCanvas(previous) else g.setCanvas() end
  return canvas, cw, ch
end

local function drawCommand(state, shot)
  if state.phase ~= "menu" or state.contest or state.tutorial or state.link then
    return false
  end
  local rect, k, logicalW, logicalH =
    commandRect(shot, COMMAND_PLATE_ASSET, FloatingHud.COMMAND)
  if not rect then return false end
  local canvas, cw, ch = renderCommand(state, k, logicalW, logicalH)
  if not canvas then return false end
  drawPerspectiveCanvas(canvas, rect[1]+rect[3]/2, rect[2]+rect[4]/2,
    cw*k, ch*k,
    cameraYawSignal(), hudRotation(), "command")
  return true
end

local function renderFight(state, k, logicalW, logicalH)
  local plate = assetImage(FIGHT_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector) then return nil end
  local layout = FloatingHud.FIGHT
  local canvas, cw, ch, pad, raster = workingCanvas(panelCanvases, "fight",
    logicalW, logicalH, layout.canvasTopPad)
  if not canvas then return nil end
  local moves = movesFor(state)
  local count = math.min(4, #moves)
  local selected = clamp(math.floor(tonumber(state.moveIndex) or 1), 1,
    math.max(1, count))
  local previous = g.getCanvas()
  g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
  g.push(); g.scale(raster,raster); g.translate(pad,pad+layout.canvasTopPad)
  drawShadowAsset(plate, 0, 0, k)
  if count > 0 then
    local selectedMove = moves[selected]
    local def = moveDef(state, selectedMove)
    local divider = assetImage(FIGHT_DIVIDER_ASSET)
    if divider then drawShadowAsset(divider, layout.dividerX,
      layout.dividerY+layout.contentYOffset, k) end
    local accuracy = def and tonumber(def.accuracy)
    if accuracy and accuracy > 0 then
      local acc = tostring(clamp(math.floor(accuracy+0.5),1,100))
      local x = layout.statsAccPercentX-layout.statsAccGap-textWidth(acc)
      drawShadowText(acc, x, layout.statsY+layout.contentYOffset, k)
      drawPercentGlyph(layout.statsAccPercentX,
        layout.statsY+layout.contentYOffset+1, k, 0.72)
    end
    local category = moveCategory(state, selectedMove)
    local categoryImage = assetImage(FIGHT_CATEGORY_ASSETS[category])
    if categoryImage then drawShadowAsset(categoryImage, layout.statsCategoryX,
      layout.statsCategoryY+layout.contentYOffset, k) end
    if def and tonumber(def.power) and tonumber(def.power) > 0 then
      drawShadowText(tostring(math.floor(def.power+0.5)), layout.statsPowerX,
        layout.statsY+layout.contentYOffset, k)
    end
    for i = 1, count do
      local move = moves[i]
      local defn = moveDef(state, move)
      local y = layout.firstY+layout.contentYOffset+(i-1)*layout.rowStep*layout.listScale
      if i == selected then drawShadowAsset(selector, layout.selectorX,
        y+layout.selectorYOffset, k, FloatingHud.ASSET_SCALE*layout.listScale) end
      local color = FloatingHud.MOVE_TYPE_COLORS[typeKey(state, move)]
        or FloatingHud.MOVE_TYPE_COLORS.NORMAL
      g.setColor(color[1],color[2],color[3],1)
      g.rectangle("fill", layout.typeX, y+layout.typeYOffset,
        layout.typeW*layout.listScale, layout.typeH*layout.listScale)
      drawShadowText(tostring((defn and defn.name) or move.id or "---"),
        layout.textX, y, k, layout.listScale)
      local current = math.max(0, math.floor(tonumber(move.pp) or 0))
      local maximum = math.max(0, math.floor(tonumber(move.maxPp)
        or tonumber(move.maxPP) or (defn and defn.pp) or current))
      local pp = string.format("%d/%d", current, maximum)
      drawShadowText(pp, layout.ppRight-textWidth(pp)*layout.ppScale,
        y+layout.ppYOffset, k, layout.ppScale)
    end
  end
  g.pop(); if previous then g.setCanvas(previous) else g.setCanvas() end
  return canvas, cw, ch
end

local function drawFight(state, shot)
  if state.phase ~= "moves" or state.contest or state.tutorial or state.link then
    return false
  end
  local rect, k, logicalW, logicalH = fightRect(shot)
  if not rect then return false end
  local canvas, cw, ch = renderFight(state, k, logicalW, logicalH)
  if not canvas then return false end
  local top = FloatingHud.FIGHT.canvasTopPad
  drawPerspectiveCanvas(canvas, rect[1]+rect[3]/2,
    rect[2]+rect[4]/2-top*k*0.5,
    cw*k, ch*k,
    cameraYawSignal(), hudRotation(), "fight")
  return true
end

local function partyRect(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(PKMN_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end
  local layout, s = FloatingHud.PKMN, tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local k = baseScale * distanceScale(shot, "player") * layout.scale
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w, h = logicalW*k, logicalH*k
  local x = footX + layout.xGap*baseScale
  local y = footY - h*0.5 + layout.yOffset*baseScale
  local margin = FloatingHud.MARGIN
  x = clamp(x, margin, math.max(margin, shot.pw-w-margin))
  y = clamp(y, margin, math.max(margin, shot.ph-h-margin))
  return {x,y,w,h},k,logicalW,logicalH
end

local function partyHp(menu, index, mon)
  if type(menu.shownHpFor)=="function" then
    local ok,value=pcall(menu.shownHpFor,menu,index,mon)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return tonumber(mon and mon.hp) or 0
end

local function renderParty(menu,k,logicalW,logicalH)
  local plate,selector=assetImage(PKMN_PLATE_ASSET),assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and menu and type(menu.party)=="table") then return nil end
  local canvas,cw,ch,pad,raster=workingCanvas(panelCanvases,"pkmn",logicalW,logicalH)
  if not canvas then return nil end
  local layout=FloatingHud.PKMN
  local count=math.min(6,#menu.party)
  local selected=math.floor(tonumber(menu.index) or 1)
  local previous=g.getCanvas()
  local ok,err=pcall(function()
    g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
    g.setBlendMode("alpha"); g.setShader(); g.setColor(1,1,1,1)
    g.push(); g.scale(raster,raster); g.translate(pad,pad)
    drawShadowAsset(plate,0,0,k)
    for i=1,count do
      local mon=menu.party[i]
      local y=layout.firstY+(i-1)*layout.rowStep
      if i==selected and selector then
        drawShadowAsset(selector,layout.selectorX,
          y+layout.selectorYOffset,k)
      elseif menu.switchFrom==i then
        drawShadowText("▷",layout.selectorX,y,k)
      end
      if mon and type(menu.drawIcon)=="function" then
        pcall(menu.drawIcon,menu,mon,layout.iconX,y)
      end
      local name=mon and tostring(mon.nickname or mon.name or mon.species or "POKéMON") or ""
      drawShadowText(name,layout.textX,y,k)
      if mon and not mon.isEgg then
        local hp=math.max(0,partyHp(menu,i,mon))
        local maxHp=math.max(1,tonumber(mon.maxHp or (mon.stats and mon.stats.hp)) or 1)
        local ratio=clamp(hp/maxHp,0,1)
        local hx,hy,hw=layout.hpX,y+10,layout.hpW
        g.setColor(0,0,0,1); g.rectangle("fill",hx+1,hy+1,hw,3)
        g.setColor(1,1,1,1); g.rectangle("fill",hx,hy,hw,2)
        if ratio<=0.20 then g.setColor(0.95,0.16,0.12,1)
        elseif ratio<=0.50 then g.setColor(1,0.82,0.10,1)
        else g.setColor(0.15,0.92,0.30,1) end
        g.rectangle("fill",hx,hy,hw*ratio,2)
      end
    end
    if selected>count then
      drawShadowAsset(selector,2,logicalH-12,k)
      drawShadowText("CANCEL",11,logicalH-12,k)
    end
    g.pop()
  end)
  if previous then g.setCanvas(previous) else g.setCanvas() end
  g.setShader(); g.setBlendMode("alpha"); g.setColor(1,1,1,1)
  if not ok then error(err,0) end
  return canvas,cw,ch
end

local function renderPartyChoice(menu,k)
  local submenu=menu and menu.submenu
  local items=submenu and submenu.items
  if type(items)~="table" or #items==0 then return nil end
  local layout=FloatingHud.PARTY_CHOICE
  local count=#items
  local logicalW=layout.logicalW
  local logicalH=math.max(layout.logicalH,
    layout.firstCenterY+(count-1)*layout.rowStep+14)
  local canvas,cw,ch,pad,raster=workingCanvas(panelCanvases,"party_choice",logicalW,logicalH)
  if not canvas then return nil end
  local selected=clamp(math.floor(tonumber(submenu.index) or 1),1,count)
  local previous=g.getCanvas()
  g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
  g.push(); g.scale(raster,raster); g.translate(pad,pad)
  for i,item in ipairs(items) do
    local label=tostring((item and item.label) or "")
    local scale=i==selected and layout.selectedScale or layout.idleScale
    local cy=layout.firstCenterY+(i-1)*layout.rowStep
    drawShadowText(label,layout.centerX-textWidth(label)*scale*0.5,
      cy-4*scale,k,scale)
  end
  g.pop(); if previous then g.setCanvas(previous) else g.setCanvas() end
  return canvas,cw,ch,logicalW,logicalH
end

local function drawParty(menu,shot)
  local rect,k,logicalW,logicalH=partyRect(shot)
  if not rect then return false end
  local canvas,cw,ch=renderParty(menu,k,logicalW,logicalH)
  if not canvas then return false end
  drawPerspectiveCanvas(canvas,rect[1]+rect[3]/2,rect[2]+rect[4]/2,
    cw*k,ch*k,cameraYawSignal(),hudRotation(),"pkmn")
  local sub,sw,sh,slw,slh=renderPartyChoice(menu,k)
  if sub then
    local layout=FloatingHud.PARTY_CHOICE
    local planeW,planeH=slw*k,slh*k
    local cx=rect[1]+rect[3]-planeW*0.5+layout.rightOffset*k
    local cy=rect[2]-planeH*0.5-layout.aboveGap*k
    local margin=FloatingHud.MARGIN
    cx=clamp(cx,margin+planeW*0.5,shot.pw-margin-planeW*0.5)
    cy=clamp(cy,margin+planeH*0.5,shot.ph-margin-planeH*0.5)
    drawPerspectiveCanvas(sub,cx,cy,sw*k,sh*k,
      cameraYawSignal(),hudRotation(),"pkmn_choice")
  end
  return true
end

local function wrapMessage(text, maxWidth)
  text = tostring(text or ""):gsub("[\v\f]", "\n")
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if line ~= "" and textWidth(candidate) > maxWidth then
        lines[#lines+1] = line; line = word
      else
        line = candidate
      end
    end
    if line ~= "" then lines[#lines+1] = line end
    if #lines >= 2 then break end
  end
  return lines
end

local function messageRect(shot)
  local logicalW, logicalH = assetLogicalSize(MESSAGE_PLATE_ASSET)
  if not (shot and logicalW and logicalH) then return nil end
  local baseScale = uiScale(shot)
  local pair = (distanceScale(shot,"player")+distanceScale(shot,"enemy"))*0.5
  local drawScale = baseScale*pair*FloatingHud.MESSAGE.scale
  local s = tonumber(shot.scale) or 1
  local px,py = shot.player and shot.player[1] or 80, shot.player and shot.player[2] or 96
  local ex,ey = shot.enemy and shot.enemy[1] or 80, shot.enemy and shot.enemy[2] or 56
  local cx = shot.lx+(px+ex)*0.5*s+FloatingHud.MESSAGE.xOffset*baseScale
  local cy = shot.ly+(py+ey)*0.5*s+FloatingHud.MESSAGE.yOffset*baseScale
  local w,h = logicalW*drawScale, logicalH*drawScale
  local margin = FloatingHud.MARGIN
  local x = clamp(cx-w/2,margin,math.max(margin,shot.pw-w-margin))
  local y = clamp(cy-h/2,margin,math.max(margin,shot.ph-h-margin))
  return {x,y,w,h},drawScale,logicalW,logicalH
end

local function ownsMessage(state)
  if state.contest or state.tutorial or state.link then return false end
  if not state.message or state.message == "" then return false end
  local phase = tostring(state.phase or "")
  if phase:match("^ask") or phase == "choose-forget"
      or phase == "stop-learning" or phase == "stats-box" then return false end
  return phase ~= "menu" and phase ~= "moves"
end

local function renderMessage(state, k, logicalW, logicalH)
  local plate = assetImage(MESSAGE_PLATE_ASSET)
  if not plate then return nil end
  local canvas,cw,ch,pad,raster =
    workingCanvas(panelCanvases,"message",logicalW,logicalH)
  if not canvas then return nil end
  local lines = wrapMessage(state.message, logicalW-20)
  local previous = g.getCanvas()
  g.setCanvas(canvas); g.origin(); g.clear(0,0,0,0)
  g.push(); g.scale(raster,raster); g.translate(pad,pad)
  drawShadowAsset(plate,0,0,k)
  if lines[1] then drawShadowText(lines[1],FloatingHud.MESSAGE.textX,
    FloatingHud.MESSAGE.line1Y,k) end
  if lines[2] then drawShadowText(lines[2],FloatingHud.MESSAGE.textX,
    FloatingHud.MESSAGE.line2Y,k) end
  if (tonumber(state.messageTimer) or 0) <= 0 then
    local cursor = assetImage(MESSAGE_CURSOR_ASSET)
    if cursor then
      local iw,ih=cursor:getDimensions()
      drawShadowAsset(cursor,logicalW-FloatingHud.MESSAGE.cursorRight-iw*FloatingHud.ASSET_SCALE,
        logicalH-FloatingHud.MESSAGE.cursorBottom-ih*FloatingHud.ASSET_SCALE,k)
    end
  end
  g.pop(); if previous then g.setCanvas(previous) else g.setCanvas() end
  return canvas,cw,ch
end

local function drawMessage(state,shot)
  if not ownsMessage(state) then return false end
  local rect,k,logicalW,logicalH=messageRect(shot)
  if not rect then return false end
  local canvas,cw,ch=renderMessage(state,k,logicalW,logicalH)
  if not canvas then return false end
  local layout=FloatingHud.MESSAGE
  local raw=cameraYawSignal(); local neutral=FloatingHud.CAMERA_CENTER_OFFSET
  local camera=clamp(neutral+(raw-neutral)*layout.cameraSignalGain,-1,1)
  local signal=clamp(layout.perspectiveBias+camera*layout.cameraInfluence,-1,1)
  local roll=math.rad(layout.baseRotationDeg+camera*layout.cameraRotationDeg)
  local pitch=-clamp(cameraPitchSignal()*layout.pitchSignalGain*layout.pitchInfluence,0,1)
  drawPerspectiveCanvas(canvas,rect[1]+rect[3]/2,rect[2]+rect[4]/2,
    cw*k, ch*k,
    signal,roll,"message",layout.perspectiveDepth,
    layout.perspectiveWidthSqueeze,pitch,layout.pitchPerspectiveDepth,
    layout.pitchHeightSqueeze)
  return true
end

local function stadiumActive(state)
  if not (mod.find and state) then return false end
  local ok, handle = pcall(mod.find, "STADIUM2_IMPORTER")
  if not ok or not handle then
    ok, handle = pcall(mod.find, mod, "STADIUM2_IMPORTER")
  end
  local current = ok and handle and handle.exports and handle.exports.getActiveBattleScene
  if type(current) ~= "function" then return false end
  local got, scene = pcall(current)
  if not got then got, scene = pcall(current, handle.exports) end
  return got and type(scene)=="table"
    and (scene.screen==state or scene.battle==state
      or (state.battle and scene.battle==state.battle))
end

local function supported(state)
  if not state or state.contest or state.tutorial or stadiumActive(state) then return false end
  local okVr, vr = pcall(V.require,"VR")
  if okVr and vr and type(vr.active)=="function" then
    local ok, active=pcall(vr.active)
    if ok and active then return false end
  end
  return true
end

local function drawIntoShot(state,shot)
  state._floatingBattleHudGen2StatusDrawn=false
  state._floatingBattleHudGen2BottomDrawn=nil
  if not (supported(state) and shot and shot.canvas and (shot.scale or 0)>0) then
    return false
  end
  local previous=g.getCanvas()
  local statusDrawn,bottomKind=false,nil
  local ok,err=pcall(function()
    g.setCanvas(shot.canvas); g.setBlendMode("alpha"); g.setShader(); g.setColor(1,1,1,1)
    if optionToggle("floating_status_hud",true) then
      if state.showEnemyHud and not hudCleared(state,"enemy") then
        statusDrawn=drawCard(state,shot,"enemy") or statusDrawn
      end
      if state.showPlayerHud and not hudCleared(state,"player") then
        statusDrawn=drawCard(state,shot,"player") or statusDrawn
      end
    end
    if optionToggle("floating_commands",true) then
      if drawMessage(state,shot) then bottomKind="messages"
      elseif drawCommand(state,shot) then bottomKind="menu"
      elseif drawFight(state,shot) then bottomKind="moves" end
    end
  end)
  if previous then g.setCanvas(previous) else g.setCanvas() end
  g.setShader(); g.setBlendMode("alpha"); g.setColor(1,1,1,1)
  if not ok then
    mod.log:warn("Battle Art Gen 2 HUD draw failed: %s",tostring(err))
    return false
  end
  state._floatingBattleHudGen2StatusDrawn=statusDrawn and true or false
  state._floatingBattleHudGen2BottomDrawn=bottomKind
  return statusDrawn or bottomKind~=nil
end

-- ---------------------------------------------------------------------------
-- Ownership and installation
-- ---------------------------------------------------------------------------

local function battleStateForMenu(menu)
  if menu and menu._floatingBattleHudGen2Battle then
    return menu._floatingBattleHudGen2Battle
  end
  local states=menu and menu.game and menu.game.stack and menu.game.stack.states
  if type(states)~="table" then return nil end
  for i=#states,1,-1 do
    local state=states[i]
    if state~=menu and (getmetatable(state)==BattleState
        or state.screenId=="Gen2BattleState") then
      return state
    end
  end
  return nil
end

local PARTY_NEW_KEY="_floatingBattleHudGen2BaseNew"
if not PartyMenu[PARTY_NEW_KEY] then PartyMenu[PARTY_NEW_KEY]=PartyMenu.new end
local basePartyNew=PartyMenu[PARTY_NEW_KEY]
if type(basePartyNew)=="function" then
  function PartyMenu.new(game,opts,...)
    local menu=basePartyNew(game,opts,...)
    if menu and opts and opts.battle then
      menu._floatingBattleHudGen2Battle=battleStateForMenu(menu)
    end
    return menu
  end
end

local partyPresentationCanvas=nil
local function partyOverlayFor(shot)
  local w,h=shot.canvas:getDimensions()
  if not partyPresentationCanvas or partyPresentationCanvas:getWidth()~=w
      or partyPresentationCanvas:getHeight()~=h then
    partyPresentationCanvas=g.newCanvas(w,h,{dpiscale=1})
    pcall(partyPresentationCanvas.setFilter,partyPresentationCanvas,
      "linear","linear")
  end
  return partyPresentationCanvas,w,h
end

local function presentPartyMenu(menu,width,height)
  if not (optionToggle("floating_commands",true) and menu and menu.battle) then
    return false
  end
  local state=battleStateForMenu(menu)
  if not state or state.link or not supported(state) then return false end
  local shot=battleShot()
  if not (shot and shot.canvas) then return false end
  local overlay,cw,ch=partyOverlayFor(shot)
  local previous=g.getCanvas()
  local ok,drawn=pcall(function()
    g.setCanvas(overlay); g.origin(); g.clear(0,0,0,0)
    return drawParty(menu,shot)
  end)
  if previous then g.setCanvas(previous) else g.setCanvas() end
  if not ok or not drawn then
    if not ok then mod.log:warn("Battle Art Gen 2 party HUD failed: %s",tostring(drawn)) end
    return false
  end
  local sw,sh=shot.canvas:getDimensions()
  width=tonumber(width) or sw
  height=tonumber(height) or sh
  g.push("all"); g.origin(); g.setColor(1,1,1,1)
  g.draw(shot.canvas,0,0,0,width/sw,height/sh)
  g.draw(overlay,0,0,0,width/cw,height/ch)
  g.pop()
  return true
end

local PARTY_WIDE_KEY="_floatingBattleHudGen2BaseDrawWidescreen"
if not PartyMenu[PARTY_WIDE_KEY] then
  PartyMenu[PARTY_WIDE_KEY]=PartyMenu.drawWidescreen
end
local basePartyDrawWidescreen=PartyMenu[PARTY_WIDE_KEY]
if type(basePartyDrawWidescreen)=="function" then
  function PartyMenu:drawWidescreen(width,height)
    if presentPartyMenu(self,width,height) then return end
    return basePartyDrawWidescreen(self,width,height)
  end
end

if mod.hooks and type(mod.hooks.wrap)=="function" then
  mod.hooks:wrap("battle.status_hud_visible",function(next,state)
    if state and state._floatingBattleHudGen2StatusDrawn then return false end
    return next(state)
  end,12000)
  mod.hooks:wrap("battle.bottom_ui_visible",function(next,state)
    if state and state._floatingBattleHudGen2BottomDrawn then return false end
    return next(state)
  end,12000)
end

local DRAW_KEY="_floatingBattleHudGen2BaseDrawWidescreen"
if not BattleState[DRAW_KEY] then BattleState[DRAW_KEY]=BattleState.drawWidescreen end
local baseDrawWidescreen=BattleState[DRAW_KEY]
if type(baseDrawWidescreen)~="function" then
  error("FLOATING_BATTLE_HUD: Battle Art Gen 2 drawWidescreen unavailable",0)
end

function BattleState:drawWidescreen(width,height)
  local shot=battleShot()
  if shot then drawIntoShot(self,shot) else
    self._floatingBattleHudGen2StatusDrawn=false
    self._floatingBattleHudGen2BottomDrawn=nil
  end
  return baseDrawWidescreen(self,width,height)
end

-- Keep the native action handlers and sounds, but reinterpret the four-command
-- grid as the vertical list shown by our plate.
local UPDATE_KEY="_floatingBattleHudGen2BaseUpdate"
if not BattleState[UPDATE_KEY] then BattleState[UPDATE_KEY]=BattleState.update end
local baseUpdate=BattleState[UPDATE_KEY]
if type(baseUpdate)=="function" then
  function BattleState:update(...)
    local input=self.game and self.game.input
    local owns=optionToggle("floating_commands",true)
      and self.phase=="menu" and self._floatingBattleHudGen2BottomDrawn=="menu"
      and input and type(input.wasPressed)=="function"
    if owns then
      local up,down=input:wasPressed("up"),input:wasPressed("down")
      local left,right=input:wasPressed("left"),input:wasPressed("right")
      if up or down or left or right then
        local index=clamp(math.floor(tonumber(self.menuIndex) or 1),1,4)
        local delta=(up or left) and -1 or 1
        local nextIndex=((index-1+delta)%4)+1
        local a,b,c=baseUpdate(self,...)
        if self.phase=="menu" then self.menuIndex=nextIndex end
        return a,b,c
      end
    end
    return baseUpdate(self,...)
  end
end

FloatingHud.generation=2
FloatingHud.hostMode="battle_art_gen2"
FloatingHud.assetPolicy={sourceDensity=FloatingHud.ASSET_SOURCE_DENSITY,
  workingDensity=FloatingHud.CANVAS_RENDER_SCALE,finalResamples=1}

return FloatingHud
