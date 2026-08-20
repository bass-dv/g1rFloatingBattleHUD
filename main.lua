-- Floating Battle HUD v0.7.5
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
local BattleState = require("src.battle.BattleState")
local Font = require("src.render.Font")
local Growth = require("src.pokemon.Growth")
local BagInventory = require("src.inventory.Bag")
local ItemEffects = require("src.inventory.ItemEffects")

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
      { "x0.8", 0.8 },
      { "x1",   1.0 },
      { "x1.5", 1.5 },
      { "x2",   2.0 },
      { "x2.5", 2.5 },
      { "x3",   3.0 },
    },
  },
  {
    key = "wild_dvs",
    type = "toggle",
    label = "WILD DVS",
    default = false,
  },
})

-- Keep the two major presentation layers independently switchable. This is
-- intentionally queried at draw/update time rather than cached at startup so a
-- launcher that applies mod options live can hand ownership back to another UI
-- mod without requiring separate compatibility builds.
local function optionToggle(key, fallback)
  local ok, value = pcall(function() return mod.options:get(key) end)
  if not ok or value == nil then return fallback end
  return value == true
end

local function floatingStatusHudEnabled()
  return optionToggle("floating_status_hud", true)
end

local function floatingCommandsEnabled()
  return optionToggle("floating_commands", true)
end

local HUD_SCALE_CHOICES = {
  [0.8] = true, [1.0] = true, [1.5] = true,
  [2.0] = true, [2.5] = true, [3.0] = true,
}

local function floatingHudScale()
  local ok, value = pcall(function() return mod.options:get("hud_scale") end)
  value = ok and tonumber(value) or 1.0
  if not HUD_SCALE_CHOICES[value] then return 1.0 end
  return value
end

-- ---------------------------------------------------------------------------
-- Asset convention
-- ---------------------------------------------------------------------------

-- All authored HUD art is exported at x8. One logical HUD pixel therefore
-- corresponds to eight source pixels, regardless of the window/UI scale.
FloatingHud.ASSET_SCALE = 1 / 8
FloatingHud.SHADOW_PX = 2       -- shadow offset in final framebuffer pixels
-- Expand the hard pixel shadow around its offset silhouette without moving it farther
-- from the white HUD. 0 = original single copy; 1 is the recommended default; 2 is
-- a chunkier outline if the HUD is being viewed at a large window scale.
FloatingHud.SHADOW_GROW_PX = 1
FloatingHud.MAX_SCALE = 3
FloatingHud.MARGIN = 4

-- Overall HUD size is now a platform-independent user option. v0.7.1 used a
-- hard-coded mobile x1.20 multiplier; the same seam is generalized so desktop,
-- handheld and mobile users can choose one consistent scale from the mod menu.

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

-- Floating battle-flow furniture. These follow the exact same x8 white-mask
-- convention as the Pokemon nameplates.
local MESSAGE_PLATE_ASSET = "assets/hud/battle_message_plate.png"
local MESSAGE_CURSOR_ASSET = "assets/hud/battle_message_cursor.png"
local COMMAND_PLATE_ASSET = "assets/hud/battle_command_plate.png"
local COMMAND_SELECTOR_ASSET = "assets/hud/battle_command_selector.png"
local FIGHT_PLATE_ASSET = "assets/hud/fight_command_plate.png"
-- Optional dedicated move-learning support. Until select_command_plate.png is
-- authored, the renderer intentionally falls back to the normal FIGHT plate.
local SELECT_PLATE_ASSET = "assets/hud/select_command_plate.png"
local PKMN_PLATE_ASSET = "assets/hud/pkmn_command_plate.png"
local ITEM_PLATE_ASSET = "assets/hud/item_command_plate.png"
local PKMN_ICON_FOLDER = "assets/hud/pkmn_icons/"

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

local function assetLogicalSize(path)
  local img = assetImage(path)
  if not img then return nil, nil end
  local w, h = img:getDimensions()
  return w * FloatingHud.ASSET_SCALE, h * FloatingHud.ASSET_SCALE
end

local function selectPlateImage()
  return assetImage(SELECT_PLATE_ASSET) or assetImage(FIGHT_PLATE_ASSET)
end

local function selectPlateLogicalSize()
  local img = selectPlateImage()
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

-- Battle-message plate. It is anchored between the two projected Pokemon and
-- pushed toward the lower/front part of the battlefield. Unlike the status
-- plates it deliberately keeps a strong authored perspective even when the
-- camera is near its neutral angle.
FloatingHud.MESSAGE = {
  xOffset = 10.0,
  yOffset = 35.0,
  scale = 1.0,

  textX = 10.0,
  line1Y = 9.0,
  line2Y = 27.0,

  cursorRight = 9.0,
  cursorBottom = 6.0,

  -- The host camera only traverses part of its theoretical orbit range in normal
  -- play. Amplify only the movement around the authored neutral point so the
  -- message plane actually reaches its intended perspective extremes.
  cameraSignalGain = 2.50,
  -- Much wider response than v0.6.1: the authored bias no longer saturates the
  -- plane through most of the host camera's reachable orbit.
  cameraInfluence = 0.80,
  perspectiveBias = -0.28,
  baseRotationDeg = -7.0,
  cameraRotationDeg = 2.0,
  perspectiveDepth = 0.32,
  perspectiveWidthSqueeze = 0.12,

  -- A gentler second-axis response driven by BattleCam.pitch (0 = the rig's
  -- low authored seat, 1 = the camera raised to its vertical stop). Positive
  -- values below control the amount only; drawMessagePanel intentionally flips
  -- the pitch sign so raising the camera makes the plate face UP toward it rather
  -- than visually lying down into the battlefield.
  pitchSignalGain = 1.00,
  pitchInfluence = 0.35,
  pitchPerspectiveDepth = 0.16,
  pitchHeightSqueeze = 0.05,
}

-- YES / NO battle-choice overlay. It deliberately has no authored plate: the two
-- words float just above the message box and inherit the exact same camera
-- orientation. Selection is communicated by scale rather than a cursor.
FloatingHud.CHOICE = {
  -- A taller plane so YES / NO can sit vertically while retaining the message
  -- plate's exact perspective transform. The plane remains right-anchored to the
  -- message box, so increasing its size grows mainly up/left rather than drifting.
  logicalW = 64.0,
  logicalH = 54.0,
  rightOffset = -2.0, -- positive = farther right
  aboveGap = 2.0,     -- distance above the message plate

  -- Text is positioned by CENTER rather than top-left. That makes the selected
  -- option zoom in place instead of visibly walking down/right as its scale grows.
  centerX = 32.0,
  yesCenterY = 15.0,
  noCenterY = 40.0,

  selectedScale = 2.20,
  idleScale = 1.20,
}


-- Main four-command plate. Its bottom edge follows the player's projected feet
-- and it sits immediately to the player's left. It uses the exact same camera
-- yaw signal, roll and faux perspective settings as the Pokemon nameplates.
FloatingHud.COMMAND = {
  xGap = 18.0,
  yOffset = 4.0,
  scale = 1.0,

  selectorX = 9.0,
  selectorYOffset = -1.0,
  textX = 20.0,
  firstY = 13.0,
  rowStep = 22.0,

  labels = { "FIGHT", "PKMN", "ITEM", "RUN" },
}

-- Move-selection furniture. The authored plate already contains the large
-- vertical FIGHT word/support, so code only supplies the live move names,
-- selector and one coloured type glyph per row.
FloatingHud.FIGHT = {
  xGap = 27.0,
  yOffset = 30.0,

  -- Keep the authored FIGHT support at its original v0.6.0 size. Only the live
  -- attack-list contents are enlarged inside it.
  scale = 1.0,
  listScale = 1.14,
  listAnchorX = 48.0,
  listAnchorY = 13.0,

  selectorX = 48.0,
  selectorYOffset = -1.0,
  typeX = 57.0,
  typeYOffset = 1.0,
  typeW = 4.0,
  typeH = 7.0,
  textX = 66.0,
  firstY = 13.0,
  rowStep = 22.0,
}

-- Move-learning replacement picker. It deliberately starts as an exact geometry
-- clone of FIGHT so the flow is usable before the dedicated SELECT art exists.
-- Drop assets/hud/select_command_plate.png into the mod later and it will be used
-- automatically without changing code or the normal FIGHT plate.
FloatingHud.LEARN = {
  xGap = 27.0,
  yOffset = 30.0,
  scale = 1.0,
  listScale = 1.14,
  listAnchorX = 48.0,
  listAnchorY = 13.0,

  selectorX = 48.0,
  selectorYOffset = -1.0,
  typeX = 57.0,
  typeYOffset = 1.0,
  typeW = 4.0,
  typeH = 7.0,
  textX = 66.0,
  firstY = 13.0,
  rowStep = 22.0,
}

-- Battle-party overlay. The plate is authored at x8, while optional species icon
-- sheets are native 16x32 two-frame menu art. Drop them into pkmn_icons using the
-- engine species id (e.g. GYARADOS.png). Missing custom art falls back to the
-- engine PartyMenu icon renderer, so this screen is testable before the full set
-- is copied in.
FloatingHud.PKMN = {
  xGap = 20.0,
  yOffset = -10.0,
  scale = 1.0,

  selectorX = 55.0,
  selectorYOffset = -1.0,
  iconX = 63.0,
  textX = 82.0,
  hpX = 82.0,
  hpW = 72.0,
  firstY = 10.0,
  rowStep = 17.0,

  -- One icon frame every N battle frames. 18 = ~0.3 s at 60 fps, intentionally
  -- much calmer than the reference mod's fast alternating menu animation.
  iconFrameTicks = 18,
}

-- Battle-item overlay. The native Bag/ListMenu remains the gameplay authority,
-- but its flat list is mirrored into a seven-row battle-only view. Categories
-- are ordered BALLS -> HEALING -> BATTLE while preserving the player's actual
-- Bag order inside each category. The continuation-arrow asset doubles as the
-- scroll indicator; the upper copy is rotated 180 degrees.
FloatingHud.ITEM = {
  xGap = 20.0,
  yOffset = -10.0,
  scale = 1.0,

  visibleRows = 7,
  selectorX = 55.0,
  selectorYOffset = -1.0,
  textX = 65.0,
  firstY = 7.0,
  rowStep = 12.5,

  arrowRight = 8.0,
  arrowTop = 4.0,
  arrowBottom = 7.0,
  arrowScale = 1.0,
}

-- Gen-I items that can sensibly appear in the battle Bag. Balls are detected
-- dynamically too; these tables cover healing/status/PP items and battle boosts.
FloatingHud.ITEM_HEAL_IDS = {
  POTION=true, SUPER_POTION=true, HYPER_POTION=true, MAX_POTION=true,
  FULL_RESTORE=true, FULL_HEAL=true, ANTIDOTE=true, BURN_HEAL=true,
  ICE_HEAL=true, AWAKENING=true, PARLYZ_HEAL=true, REVIVE=true,
  MAX_REVIVE=true, ETHER=true, MAX_ETHER=true, ELIXER=true, MAX_ELIXER=true,
  FRESH_WATER=true, SODA_POP=true, LEMONADE=true,
}
FloatingHud.ITEM_BATTLE_IDS = {
  X_ATTACK=true, X_DEFEND=true, X_SPEED=true, X_SPECIAL=true,
  X_ACCURACY=true, DIRE_HIT=true, GUARD_SPEC=true,
  POKE_DOLL=true, POKE_FLUTE=true,
}

-- Gen-I type accents supplied for the floating move list. FLYING still
-- falls back to the neutral colour until an authored colour is supplied.
FloatingHud.MOVE_TYPE_COLORS = {
  FIGHTING = { 0xD7 / 255, 0x00 / 255, 0x96 / 255, 1 },
  NORMAL   = { 0xB6 / 255, 0xC0 / 255, 0xC9 / 255, 1 },
  ELECTRIC = { 0xEA / 255, 0xCD / 255, 0x43 / 255, 1 },
  POISON   = { 0x85 / 255, 0x64 / 255, 0xCD / 255, 1 },
  FIRE     = { 0xFF / 255, 0x42 / 255, 0x00 / 255, 1 },
  BUG      = { 0x96 / 255, 0xAB / 255, 0x32 / 255, 1 },
  DRAGON   = { 0x25 / 255, 0x59 / 255, 0xA4 / 255, 1 },
  GHOST    = { 0x68 / 255, 0x61 / 255, 0xA7 / 255, 1 },
  GRASS    = { 0x3E / 255, 0xCA / 255, 0x21 / 255, 1 },
  ROCK     = { 0xC7 / 255, 0xAB / 255, 0x95 / 255, 1 },
  GROUND   = { 0xBD / 255, 0x74 / 255, 0x3F / 255, 1 },
  ICE      = { 0xA8 / 255, 0xDB / 255, 0xCA / 255, 1 },
  WATER    = { 0x44 / 255, 0xBA / 255, 0xFF / 255, 1 },
  PSYCHIC  = { 0xFF / 255, 0x7B / 255, 0xCA / 255, 1 },
}

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

local function splitBattleMessageText(text)
  text = tostring(text or "")
  local out = {}
  local pos = 1
  while true do
    local a, b = text:find("[\n\v]", pos)
    if not a then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, a - 1)
    pos = b + 1
  end
  return out
end

local function revealedGlyphText(source, count)
  source = tostring(source or "")
  count = math.max(0, tonumber(count) or 0)
  if count == 0 then return "" end

  local ok, spans = pcall(Font.split, source)
  if not (ok and type(spans) == "table") then
    return source:sub(1, count)
  end
  if count >= #spans then return source end
  local last = spans[count]
  return last and source:sub(1, last.to) or ""
end

-- Gen1Recomp already owns the typewriter/CONT state in battle.shown. Reuse that
-- rolling two-line window instead of inventing a second message state machine.
local function visibleBattleMessageLines(battle)
  if not battle then return {} end

  local shown = battle.shown
  local source = battle.current and battle.current.text or nil
  if shown and source and #shown > 0 then
    local sourceLines = splitBattleMessageText(source)
    local lineIndex = math.max(1, tonumber(battle.lineIndex) or 1)
    local firstSource = math.max(1, lineIndex - #shown + 1)
    local complete = battle.msgWaiting or battle.msgPrompt or battle.msgHold
                     or (battle.current and battle.current.done)
    local out = {}

    for visibleIndex, codes in ipairs(shown) do
      local sourceIndex = firstSource + visibleIndex - 1
      local full = sourceLines[sourceIndex] or ""
      if complete then
        out[#out + 1] = full
      else
        out[#out + 1] = revealedGlyphText(full, #(codes or {}))
      end
    end

    battle._floatingBattleMessageLines = out
    return out
  end

  -- Animations can keep the previous page visible after current is cleared.
  return battle._floatingBattleMessageLines or {}
end

local function visibleTextBoxMessageLines(box)
  if not box then return {} end
  local full = nil
  if type(box.visibleText) == "function" then
    local ok, value = pcall(box.visibleText, box)
    if ok and type(value) == "table" then full = value end
  end
  if not full then return {} end

  local shown = type(box.shown) == "table" and box.shown or {}
  local out = {}
  for i = 1, math.min(2, #full) do
    local codes = shown[i]
    if type(codes) == "table" then
      out[#out + 1] = revealedGlyphText(full[i] or "", #codes)
    else
      out[#out + 1] = tostring(full[i] or "")
    end
  end
  return out
end

local function battleMessageActive(battle)
  if not (battle and battle.phase == "messages") then return false end
  return battle.current ~= nil
      or battle.msgHold
      or battle.msgWaiting
      or battle.msgPrompt
      or #(battle.shown or {}) > 0
end

local function moveDefinition(battle, move)
  if not (battle and battle.data and battle.data.moves and move) then return nil end
  local id = type(move) == "table" and (move.id or move.moveId or move.move) or move
  return id and battle.data.moves[id] or nil
end

local function moveDisplayName(battle, move)
  local def = moveDefinition(battle, move)
  local name = def and def.name
  if not name and type(move) == "table" then
    name = move.name or move.id or move.moveId or move.move
  end
  return tostring(name or "---"):upper()
end

local function moveTypeKey(battle, move)
  local def = moveDefinition(battle, move)
  local t = def and (def.type or def.moveType or def.damageType) or nil
  if type(t) == "table" then t = t.name or t.id end
  local key = tostring(t or "NORMAL"):upper()
  key = key:gsub("[%s_%-]+TYPE$", ""):gsub("[%s_%-]+", "")
  if key == "FIGHT" then key = "FIGHTING" end
  if key == "LIGHTNING" then key = "ELECTRIC" end
  if key == "LEAF" then key = "GRASS" end
  return key
end

local function moveTypeColor(battle, move)
  local key = moveTypeKey(battle, move)
  return FloatingHud.MOVE_TYPE_COLORS[key]
      or FloatingHud.MOVE_TYPE_COLORS.NORMAL
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
  local base = clamp(math.floor(s * 0.5 + 0.5), 1, FloatingHud.MAX_SCALE)
  return base * floatingHudScale()
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

-- Vertical camera steering is already normalized by both voxel hosts: 0 is the
-- authored low seat and 1 is the raised/top stop. Unlike yaw there is no
-- automatic pitch drift, so this signal is intentionally simple and independent
-- from zoom.
local function cameraPitchSignal()
  return clamp(tonumber(BattleCam and BattleCam.pitch) or 0, 0, 1)
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

-- Shadow offset in FINAL framebuffer pixels, even though the HUD itself changes
-- integer scale with the window. Called after g.scale(k,k), hence division by k.
local function shadowLogical(k, extraScale)
  return FloatingHud.SHADOW_PX / math.max(0.001, k * (extraScale or 1))
end

-- Draw the same hard silhouette around the original shadow origin. This deliberately
-- uses only eight neighbouring copies (plus the original), rather than a shader or a
-- large NxN dilation loop: it keeps the pixel-art edge crisp and avoids the much more
-- invasive shadow rewrite that made the abandoned v0.6.8 branch unstable.
local function eachShadowOffset(k, extraScale, fn)
  local denom = math.max(0.001, k * (extraScale or 1))
  local o = FloatingHud.SHADOW_PX / denom
  local growPx = math.max(0, tonumber(FloatingHud.SHADOW_GROW_PX) or 0)
  local grow = growPx / denom

  fn(o, o)
  if grow <= 0 then return end

  fn(o - grow, o)
  fn(o + grow, o)
  fn(o, o - grow)
  fn(o, o + grow)
  fn(o - grow, o - grow)
  fn(o + grow, o - grow)
  fn(o - grow, o + grow)
  fn(o + grow, o + grow)
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
    eachShadowOffset(k, extraScale, function(sx, sy)
      drawMaskedFont(text, sx, sy, 0, 0, 0, 1)
    end)
    drawMaskedFont(text, 0, 0, 1, 1, 1, 1)
    g.pop()
    return
  end

  eachShadowOffset(k, 1, function(sx, sy)
    drawMaskedFont(text, x + sx, y + sy, 0, 0, 0, 1)
  end)
  drawMaskedFont(text, x, y, 1, 1, 1, 1)
end

local function drawShadowTextCentered(text, centerX, y, k, extraScale)
  extraScale = extraScale or 1
  local w = textWidth(text) * extraScale
  drawShadowText(text, centerX - w * 0.5, y, k, extraScale)
end

local function drawShadowAsset(img, x, y, k, scale, colored)
  if not img then return false end
  scale = scale or FloatingHud.ASSET_SCALE

  -- Silhouette shadow first. Tinting an Image black preserves its alpha mask.
  g.setColor(0, 0, 0, 1)
  eachShadowOffset(k, 1, function(sx, sy)
    g.draw(img, x + sx, y + sy, 0, scale, scale)
  end)

  -- Battleplates are white masks; status/caught keep their authored colors.
  g.setColor(1, 1, 1, 1)
  g.draw(img, x, y, 0, scale, scale)
  return true
end

local function drawShadowAssetRotated(img, x, y, k, scale, angle)
  if not img then return false end
  scale = scale or FloatingHud.ASSET_SCALE
  angle = angle or 0
  local iw, ih = img:getDimensions()
  local w, h = iw * scale, ih * scale
  local cx, cy = x + w * 0.5, y + h * 0.5

  g.setColor(0, 0, 0, 1)
  eachShadowOffset(k, 1, function(sx, sy)
    g.draw(img, cx + sx, cy + sy, angle, scale, scale, iw * 0.5, ih * 0.5)
  end)
  g.setColor(1, 1, 1, 1)
  g.draw(img, cx, cy, angle, scale, scale, iw * 0.5, ih * 0.5)
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

    -- Structural shadow first. Keep the same global growth treatment as every
    -- other authored HUD asset, but do not draw the white plate yet because HP/EXP
    -- fills still have to land underneath it.
    g.setColor(0, 0, 0, 1)
    eachShadowOffset(k, 1, function(sx, sy)
      g.draw(plate, sx, sy, 0,
             FloatingHud.ASSET_SCALE, FloatingHud.ASSET_SCALE)
    end)

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

-- Message/command planes use the same supersampled intermediate-canvas strategy
-- as the Pokemon plates, but keep their own cache because their aspect ratios
-- and content are unrelated to either battler.

local partyIconImages = {}

local function partyIconImage(species)
  species = tostring(species or "")
  if species == "" then return nil end
  if partyIconImages[species] ~= nil then return partyIconImages[species] or nil end
  local path = PKMN_ICON_FOLDER .. species .. ".png"
  local ok, img = pcall(function() return mod.assets:image(path) end)
  if ok and img then
    pcall(img.setFilter, img, "nearest", "nearest")
    partyIconImages[species] = img
    return img
  end
  partyIconImages[species] = false
  return nil
end

local function battleStateInStack(game)
  local states = game and game.stack and game.stack.states
  if not states then return nil end
  for i = #states, 1, -1 do
    local state = states[i]
    if getmetatable(state) == BattleState
        or (state and state.game == game and state.player and state.enemy
            and state.phase ~= nil) then
      return state
    end
  end
  return nil
end

local function stateInStack(game, wanted)
  local states = game and game.stack and game.stack.states
  if not (states and wanted) then return false end
  for i = #states, 1, -1 do
    if states[i] == wanted then return true end
  end
  return false
end

local function topState(game)
  local stack = game and game.stack
  if not stack then return nil end
  if type(stack.top) == "function" then
    local ok, value = pcall(stack.top, stack)
    if ok and value ~= nil then return value end
  end
  local states = stack.states
  return states and states[#states] or nil
end

local function isTextBoxState(state)
  return state and (state.isTextBox == true
    or (type(state.visibleText) == "function"
        and type(state.shown) == "table"
        and state.pageIndex ~= nil))
end

local function moveLearnTextBoxInStack(game)
  local states = game and game.stack and game.stack.states
  if not states then return nil end
  for i = #states, 1, -1 do
    local state = states[i]
    if state and state.__floatingBattleMoveLearnText then return state end
  end
  return nil
end

local function moveLearnOverlayActiveForBattle(battle)
  if not battle then return false end
  local game = battle.game
  local menu = battle._floatingBattleMoveLearnMenu
  if menu and stateInStack(game, menu) then return true end
  if menu then battle._floatingBattleMoveLearnMenu = nil end

  local text = battle._floatingBattleMoveLearnText
  if text and stateInStack(game, text) then return true end
  if text then battle._floatingBattleMoveLearnText = nil end
  return false
end

local function partyOverlayActiveForBattle(battle)
  local menu = battle and battle._floatingBattlePartyMenu
  if not menu then return false end
  if stateInStack(menu.game or battle.game, menu) then return true end
  battle._floatingBattlePartyMenu = nil
  return false
end

local function itemOverlayActiveForBattle(battle)
  local menu = battle and battle._floatingBattleItemMenu
  if not menu then return false end
  if stateInStack(menu.game or battle.game, menu) then return true end
  battle._floatingBattleItemMenu = nil
  return false
end

-- Build a presentation-only battle Bag. Never rewrite ListMenu.items: native Bag
-- actions and reorder semantics depend on those flat indices. We keep a parallel
-- filtered view and sync its selected item back to the native index only on A.
local function battleItemCategory(battle, game, id)
  if id == nil then return nil end
  local key = tostring(id):upper()
  local def = game and game.data and game.data.items and game.data.items[id]
  local okBall, isBall = pcall(ItemEffects.isBall, id)

  if (def and def.ball) or (okBall and isBall) or key:find("BALL", 1, true) then
    if wildBattle(battle) then return "BALLS", 1 end
    return nil
  end

  if FloatingHud.ITEM_HEAL_IDS[key]
      or key:find("POTION", 1, true)
      or key:find("HEAL", 1, true)
      or key:find("REVIVE", 1, true)
      or key:find("RESTORE", 1, true)
      or key:find("ETHER", 1, true)
      or key:find("ELIXER", 1, true) then
    return "HEALING", 2
  end

  if FloatingHud.ITEM_BATTLE_IDS[key] or key:match("^X_") then
    -- POKé DOLL is meaningful only against a wild encounter.
    if key == "POKE_DOLL" and not wildBattle(battle) then return nil end
    return "BATTLE", 3
  end
  return nil
end

local function battleItemRows(menu, battle)
  local game = menu and menu.game or battle and battle.game
  local save = game and game.save
  local inventory = save and save.inventory or nil
  if not (game and save and inventory) then return {} end

  local rows, seen = {}, {}
  local ordinal = 0
  local function add(id)
    if id == nil or seen[id] then return end
    seen[id] = true
    local count = tonumber(inventory[id]) or 0
    if count <= 0 then return end
    local category, rank = battleItemCategory(battle, game, id)
    if not category then return end
    ordinal = ordinal + 1
    local def = game.data and game.data.items and game.data.items[id]
    rows[#rows + 1] = {
      value = id,
      label = tostring((def and def.name) or id):upper(),
      count = count,
      category = category,
      rank = rank,
      ordinal = ordinal,
    }
  end

  -- Bag.order() is the engine read-side of save.bagOrder, so any order the player
  -- authored elsewhere is preserved inside each battle category.
  local okOrder, order = pcall(BagInventory.order, save)
  if okOrder and type(order) == "table" then
    for _, id in ipairs(order) do add(id) end
  end
  for _, row in ipairs(menu.items or {}) do add(row and row.value) end
  for id in pairs(inventory) do add(id) end

  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.ordinal ~= b.ordinal then return a.ordinal < b.ordinal end
    return a.label < b.label
  end)
  return rows
end

local function selectedBattleItemRow(menu)
  local rows = menu and menu.__floatingBattleItemRows or nil
  if not rows then return nil end
  return rows[menu.__floatingBattleItemViewIndex or 1]
end

local function refreshBattleItemView(menu, battle, preserveId)
  if not menu then return end
  local rows = battleItemRows(menu, battle)
  menu.__floatingBattleItemRows = rows
  local oldIndex = menu.__floatingBattleItemViewIndex or 1
  local nextIndex = nil
  if preserveId ~= nil then
    for i, row in ipairs(rows) do
      if row.value == preserveId then nextIndex = i break end
    end
  end

  local visible = math.max(1, math.floor(FloatingHud.ITEM.visibleRows or 7))
  if #rows == 0 then
    menu.__floatingBattleItemViewIndex = 1
    menu.__floatingBattleItemViewScroll = 0
    return
  end

  local index = nextIndex or clamp(oldIndex, 1, #rows)
  local scroll = clamp(menu.__floatingBattleItemViewScroll or 0,
                       0, math.max(0, #rows - visible))
  if index - scroll < 1 then
    scroll = index - 1
  elseif index - scroll > visible then
    scroll = index - visible
  end
  menu.__floatingBattleItemViewIndex = index
  menu.__floatingBattleItemViewScroll = clamp(scroll, 0, math.max(0, #rows - visible))
end

local function nativeBattleItemIndex(menu, id)
  if not (menu and id ~= nil) then return nil end
  for i, row in ipairs(menu.items or {}) do
    if row and row.value == id then return i end
  end
  return nil
end

local function moveBattleItemView(menu, delta)
  local rows = menu and menu.__floatingBattleItemRows or {}
  if #rows == 0 then return false end
  local old = clamp(menu.__floatingBattleItemViewIndex or 1, 1, #rows)
  local index = clamp(old + delta, 1, #rows)
  if index == old then return false end
  menu.__floatingBattleItemViewIndex = index
  local visible = math.max(1, math.floor(FloatingHud.ITEM.visibleRows or 7))
  local scroll = menu.__floatingBattleItemViewScroll or 0
  if index - scroll < 1 then
    scroll = index - 1
  elseif index - scroll > visible then
    scroll = index - visible
  end
  menu.__floatingBattleItemViewScroll = clamp(scroll, 0, math.max(0, #rows - visible))
  return true
end

local panelCanvases = {}

local function panelCanvas(key, logicalW, logicalH)
  local pad = FloatingHud.CANVAS_PAD or 0
  local raster = math.max(1, tonumber(FloatingHud.CANVAS_RENDER_SCALE) or 1)
  local logicalCW = logicalW + pad * 2
  local logicalCH = logicalH + pad * 2
  local cw = math.ceil(logicalCW * raster)
  local ch = math.ceil(logicalCH * raster)
  local canvas = panelCanvases[key]

  if not canvas or canvas:getWidth() ~= cw or canvas:getHeight() ~= ch then
    local ok, made = pcall(g.newCanvas, cw, ch, { dpiscale = 1 })
    if not (ok and made) then return nil end
    pcall(made.setFilter, made, "linear", "linear")
    canvas = made
    panelCanvases[key] = canvas
  end

  return canvas, cw, ch, pad, raster, logicalCW, logicalCH
end

local function renderMessageCanvas(battle, k, logicalW, logicalH)
  local plate = assetImage(MESSAGE_PLATE_ASSET)
  if not plate then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("message", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.MESSAGE
  local lines = visibleBattleMessageLines(battle)
  local cursor = assetImage(MESSAGE_CURSOR_ASSET)
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    if lines[1] ~= nil then
      drawShadowText(lines[1], layout.textX or 10, layout.line1Y or 9, k)
    end
    if lines[2] ~= nil then
      drawShadowText(lines[2], layout.textX or 10, layout.line2Y or 27, k)
    end

    -- Match the original wait prompt: blink only while the engine is waiting
    -- for acknowledgement. If the tiny authored cursor ever fails to load, the
    -- message remains perfectly usable; only the cosmetic marker disappears.
    local waiting = battle.msgWaiting or battle.msgPrompt
    if waiting and cursor and ((tonumber(battle.frame) or 0) % 60 < 30) then
      local cursorW, cursorH = assetLogicalSize(MESSAGE_CURSOR_ASSET)
      if cursorW and cursorH then
        local x = logicalW - cursorW - (layout.cursorRight or 9)
        local y = logicalH - cursorH - (layout.cursorBottom or 6)
        drawShadowAsset(cursor, x, y, k, FloatingHud.ASSET_SCALE)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end


local function renderMoveLearnMessageCanvas(box, k, logicalW, logicalH)
  local plate = assetImage(MESSAGE_PLATE_ASSET)
  if not (plate and box) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("learn_message", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.MESSAGE
  local lines = visibleTextBoxMessageLines(box)
  local cursor = assetImage(MESSAGE_CURSOR_ASSET)
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)
    if lines[1] ~= nil then
      drawShadowText(lines[1], layout.textX or 10, layout.line1Y or 9, k)
    end
    if lines[2] ~= nil then
      drawShadowText(lines[2], layout.textX or 10, layout.line2Y or 27, k)
    end

    -- Mirror TextBox's own more-arrow condition. Choice prompts do not need the
    -- arrow: as soon as the page completes, their YES/NO surface owns attention.
    local waiting = box.waiting
      or (box.done and not box.choice and not box.auto and not box.stay)
    if waiting and cursor and ((tonumber(box.blink) or 0) % 60 < 30) then
      local cursorW, cursorH = assetLogicalSize(MESSAGE_CURSOR_ASSET)
      if cursorW and cursorH then
        local x = logicalW - cursorW - (layout.cursorRight or 9)
        local y = logicalH - cursorH - (layout.cursorBottom or 6)
        drawShadowAsset(cursor, x, y, k, FloatingHud.ASSET_SCALE)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function renderChoiceCanvas(choice, k)
  if not choice then return nil end
  local layout = FloatingHud.CHOICE
  local logicalW = layout.logicalW or 48
  local logicalH = layout.logicalH or 18
  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("choice", logicalW, logicalH)
  if not canvas then return nil end

  local selected = clamp(math.floor(tonumber(choice.index) or 1), 1, 2)
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    local yesScale = selected == 1
      and (layout.selectedScale or 1.28) or (layout.idleScale or 0.82)
    local noScale = selected == 2
      and (layout.selectedScale or 1.28) or (layout.idleScale or 0.82)

    local function drawCenteredChoice(label, cx, cy, scale)
      local w = textWidth(label) * scale
      -- Gen-I's battle font is an 8px cell. Offset by the scaled cell height too,
      -- so scale changes happen around the visual center on both axes.
      local h = 8 * scale
      drawShadowText(label, cx - w * 0.5, cy - h * 0.5, k, scale)
    end

    local centerX = layout.centerX or (logicalW * 0.5)
    drawCenteredChoice("YES", centerX, layout.yesCenterY or 15, yesScale)
    drawCenteredChoice("NO",  centerX, layout.noCenterY or 40, noScale)

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH, logicalW, logicalH
end


local function renderCommandCanvas(battle, k, logicalW, logicalH)
  local plate = assetImage(COMMAND_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("command", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.COMMAND
  local labels = layout.labels or { "FIGHT", "PKMN", "ITEM", "RUN" }
  local selected = clamp(math.floor(tonumber(battle.menuIndex) or 1), 1, 4)
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    for i = 1, 4 do
      local y = (layout.firstY or 13) + (i - 1) * (layout.rowStep or 22)
      if i == selected then
        drawShadowAsset(selector,
                        layout.selectorX or 9,
                        y + (layout.selectorYOffset or -1),
                        k, FloatingHud.ASSET_SCALE)
      end
      drawShadowText(labels[i] or "", layout.textX or 20, y, k)
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function renderFightCanvas(battle, k, logicalW, logicalH)
  local plate = assetImage(FIGHT_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector and battle and battle.player) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("fight", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.FIGHT
  local moves = battle.player.curMoves or {}
  local selected = clamp(math.floor(tonumber(battle.moveIndex) or 1), 1,
                         math.max(1, math.min(4, #moves)))
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    -- Enlarge only the attack list, not the authored vertical FIGHT support.
    -- Every live element grows away from one shared top-left anchor so selector,
    -- type chip, text and row spacing keep their relative alignment.
    local listScale = math.max(0.5, tonumber(layout.listScale) or 1)
    local anchorX = tonumber(layout.listAnchorX) or (layout.selectorX or 48)
    local anchorY = tonumber(layout.listAnchorY) or (layout.firstY or 13)
    local function sx(value)
      return anchorX + ((tonumber(value) or anchorX) - anchorX) * listScale
    end

    for i = 1, 4 do
      local move = moves[i]
      local y = anchorY + (i - 1) * (layout.rowStep or 22) * listScale
      if move then
        if i == selected then
          drawShadowAsset(selector,
                          sx(layout.selectorX or 48),
                          y + (layout.selectorYOffset or -1) * listScale,
                          k, FloatingHud.ASSET_SCALE * listScale)
        end

        local color = moveTypeColor(battle, move)
        g.setColor(color[1], color[2], color[3], color[4] or 1)
        g.rectangle("fill",
                    sx(layout.typeX or 57),
                    y + (layout.typeYOffset or 1) * listScale,
                    (layout.typeW or 4) * listScale,
                    (layout.typeH or 7) * listScale)

        drawShadowText(moveDisplayName(battle, move),
                       sx(layout.textX or 66), y, k, listScale)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end


local function renderLearnCanvas(menu, battle, k, logicalW, logicalH)
  local plate = selectPlateImage()
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector and menu and menu.mon) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("learn", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.LEARN
  local moves = menu.mon.moves or {}
  local count = math.min(4, #moves)
  local selected = clamp(math.floor(tonumber(menu.index) or 1), 1, math.max(1, count))
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    local listScale = math.max(0.5, tonumber(layout.listScale) or 1)
    local anchorX = tonumber(layout.listAnchorX) or (layout.selectorX or 48)
    local anchorY = tonumber(layout.listAnchorY) or (layout.firstY or 13)
    local function sx(value)
      return anchorX + ((tonumber(value) or anchorX) - anchorX) * listScale
    end

    for i = 1, count do
      local move = moves[i]
      local y = anchorY + (i - 1) * (layout.rowStep or 22) * listScale
      if i == selected then
        drawShadowAsset(selector,
                        sx(layout.selectorX or 48),
                        y + (layout.selectorYOffset or -1) * listScale,
                        k, FloatingHud.ASSET_SCALE * listScale)
      end

      local color = moveTypeColor(battle, move)
      g.setColor(color[1], color[2], color[3], color[4] or 1)
      g.rectangle("fill",
                  sx(layout.typeX or 57),
                  y + (layout.typeYOffset or 1) * listScale,
                  (layout.typeW or 4) * listScale,
                  (layout.typeH or 7) * listScale)

      drawShadowText(moveDisplayName(battle, move),
                     sx(layout.textX or 66), y, k, listScale)
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function renderPartyCanvas(menu, battle, k, logicalW, logicalH)
  local plate = assetImage(PKMN_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and menu) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("pkmn", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.PKMN
  local party = menu.party or (menu.game and menu.game.save and menu.game.save.party) or {}
  local count = math.min(6, #party)
  local selected = clamp(math.floor(tonumber(menu.index) or 1), 1, math.max(1, count))
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    for i = 1, count do
      local mon = party[i]
      local y = (layout.firstY or 10) + (i - 1) * (layout.rowStep or 17)

      if i == selected and selector then
        drawShadowAsset(selector,
                        layout.selectorX or 55,
                        y + (layout.selectorYOffset or -1),
                        k, FloatingHud.ASSET_SCALE)
      end

      -- Prefer our own per-species 16x32 two-frame sheet when supplied.
      local icon = partyIconImage(mon and mon.species)
      local drewIcon = false
      if icon then
        local iw, ih = icon:getDimensions()
        local frameH = (ih >= 2 and ih >= iw * 1.5) and math.floor(ih / 2) or ih
        local frameCount = frameH < ih and 2 or 1
        local ticks = math.max(1, math.floor(layout.iconFrameTicks or 18))
        local frame = frameCount > 1
          and (math.floor((tonumber(battle and battle.frame) or 0) / ticks) % frameCount)
          or 0
        local quad = g.newQuad(0, frame * frameH, iw, frameH, iw, ih)
        local targetH = 16
        local scale = targetH / math.max(1, frameH)
        g.setColor(0,0,0,1)
        local o = shadowLogical(k, 1)
        g.draw(icon, quad, (layout.iconX or 63) + o, y + o, 0, scale, scale)
        g.setColor(1,1,1,1)
        g.draw(icon, quad, layout.iconX or 63, y, 0, scale, scale)
        drewIcon = true
      end

      -- Fallback to Gen1Recomp's resolved icon registry. This also means the
      -- Unique Menu Icons mod can supply its registered silhouettes without
      -- becoming a hard dependency of Floating Battle HUD.
      if not drewIcon then
        local okParty, PartyMenu = pcall(require, "src.ui.PartyMenu")
        if okParty and PartyMenu and type(PartyMenu.drawIcon) == "function" and mon then
          local slowBlink = math.floor((tonumber(battle and battle.frame) or 0)
                            / math.max(1, math.floor(layout.iconFrameTicks or 18)))
          pcall(PartyMenu.drawIcon, menu.game, mon, layout.iconX or 63, y,
                false, slowBlink)
        end
      end

      local def = battle and battle.data and battle.data.pokemon
                  and mon and battle.data.pokemon[mon.species]
      local name = mon and tostring(mon.nickname or (def and def.name)
                                    or mon.species or "POKéMON") or ""
      drawShadowText(name, layout.textX or 82, y, k)

      if mon then
        local hp = math.max(0, tonumber(mon.hp) or 0)
        local maxHP = math.max(1, tonumber(mon.stats and mon.stats.hp) or 1)
        local ratio = clamp(hp / maxHP, 0, 1)
        local hx = layout.hpX or 82
        local hy = y + 10
        local hw = layout.hpW or 72

        -- Thin white track + Gen-I HP colour, intentionally no numbers/level.
        g.setColor(0,0,0,1)
        g.rectangle("fill", hx + 1, hy + 1, hw, 3)
        g.setColor(1,1,1,1)
        g.rectangle("fill", hx, hy, hw, 2)
        if ratio <= 0.20 then
          g.setColor(0.95, 0.16, 0.12, 1)
        elseif ratio <= 0.50 then
          g.setColor(1.00, 0.82, 0.10, 1)
        else
          g.setColor(0.15, 0.92, 0.30, 1)
        end
        g.rectangle("fill", hx, hy, hw * ratio, 2)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1,1,1,1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function renderItemCanvas(menu, battle, k, logicalW, logicalH)
  local plate = assetImage(ITEM_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  local arrow = assetImage(MESSAGE_CURSOR_ASSET)
  if not (plate and menu) then return nil end

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("item", logicalW, logicalH)
  if not canvas then return nil end

  local layout = FloatingHud.ITEM
  local oldSelected = selectedBattleItemRow(menu)
  refreshBattleItemView(menu, battle, oldSelected and oldSelected.value or nil)
  local rows = menu.__floatingBattleItemRows or {}
  local visible = math.max(1, math.floor(layout.visibleRows or 7))
  local selected = menu.__floatingBattleItemViewIndex or 1
  local scroll = menu.__floatingBattleItemViewScroll or 0
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
    g.scale(raster, raster)
    g.translate(pad, pad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)

    if #rows == 0 then
      drawShadowText("NO USABLE ITEMS", layout.textX or 65,
                     layout.firstY or 7, k, 0.85)
    else
      for slot = 1, visible do
        local index = scroll + slot
        local row = rows[index]
        if row then
          local y = (layout.firstY or 7) + (slot - 1) * (layout.rowStep or 12.5)
          if index == selected and selector then
            drawShadowAsset(selector,
                            layout.selectorX or 55,
                            y + (layout.selectorYOffset or -1),
                            k, FloatingHud.ASSET_SCALE)
          end
          drawShadowText(row.label, layout.textX or 65, y, k)
        end
      end
    end

    if arrow then
      local iw, ih = arrow:getDimensions()
      local arrowScale = FloatingHud.ASSET_SCALE * math.max(0.25, layout.arrowScale or 1)
      local aw, ah = iw * arrowScale, ih * arrowScale
      local ax = logicalW - (layout.arrowRight or 8) - aw
      if scroll > 0 then
        drawShadowAssetRotated(arrow, ax, layout.arrowTop or 4, k,
                               arrowScale, math.pi)
      end
      if scroll + visible < #rows then
        local ay = logicalH - (layout.arrowBottom or 7) - ah
        drawShadowAssetRotated(arrow, ax, ay, k, arrowScale, 0)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1,1,1,1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH
end

local function rotatedPoint(x, y, angle)
  if angle == 0 then return x, y end
  local c, s = math.cos(angle), math.sin(angle)
  return x * c - y * s, x * s + y * c
end

local function drawPerspectiveCanvas(canvas, cx, cy, w, h, signal, roll, side,
                                     depthOverride, squeezeOverride,
                                     pitchSignal, pitchDepthOverride,
                                     pitchSqueezeOverride)
  signal = clamp(signal or 0, -1, 1)

  -- Status/command planes preserve the established v0.5 behavior. A caller may
  -- opt into a signed custom depth (the message plate does) without changing
  -- the hand-tuned Pokemon plates.
  local depth
  if depthOverride ~= nil then
    depth = clamp(tonumber(depthOverride) or 0, -0.45, 0.45)
  else
    depth = clamp(FloatingHud.PERSPECTIVE_DEPTH or 0, 0, 0.45)
  end

  local squeeze
  if squeezeOverride ~= nil then
    squeeze = clamp(tonumber(squeezeOverride) or 0, 0, 0.35)
  else
    squeeze = clamp(FloatingHud.PERSPECTIVE_WIDTH_SQUEEZE or 0, 0, 0.35)
  end

  -- Positive signal makes the RIGHT edge the near edge; negative makes LEFT near.
  local leftScale  = 1 - signal * depth
  local rightScale = 1 + signal * depth
  local widthScale = 1 - math.abs(signal) * squeeze
  local lx, rx = -w * 0.5 * widthScale, w * 0.5 * widthScale
  local lhy, rhy = h * 0.5 * leftScale, h * 0.5 * rightScale

  -- Optional second-axis perspective. BattleCam.pitch is 0..1, so positive pitch
  -- means the camera has climbed above the authored low seat. Narrow the top edge
  -- and open the bottom edge a little, plus a tiny height compression. Existing
  -- status/command callers omit these parameters and therefore remain bit-for-bit
  -- on their established geometry.
  pitchSignal = clamp(tonumber(pitchSignal) or 0, -1, 1)
  local pitchDepth = clamp(tonumber(pitchDepthOverride) or 0, -0.35, 0.35)
  local pitchSqueeze = clamp(tonumber(pitchSqueezeOverride) or 0, 0, 0.25)
  local topWidth = 1 - pitchSignal * pitchDepth
  local bottomWidth = 1 + pitchSignal * pitchDepth
  local heightScale = 1 - math.abs(pitchSignal) * pitchSqueeze

  local x1,y1 = rotatedPoint(lx * topWidth,    -lhy * heightScale, roll) -- top-left
  local x2,y2 = rotatedPoint(rx * topWidth,    -rhy * heightScale, roll) -- top-right
  local x3,y3 = rotatedPoint(rx * bottomWidth,  rhy * heightScale, roll) -- bottom-right
  local x4,y4 = rotatedPoint(lx * bottomWidth,  lhy * heightScale, roll) -- bottom-left

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

local function commandRectFor(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(COMMAND_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player")
                    * (FloatingHud.COMMAND.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = footX - w - (FloatingHud.COMMAND.xGap or 8) * baseScale
  -- Right-edge/middle anchor: the player's projected feet sit beside the middle
  -- of the command plate instead of beside its lower-right corner.
  local y = footY - h * 0.5 + (FloatingHud.COMMAND.yOffset or 0) * baseScale
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  -- Deliberately no lower-screen clamp: this plate belongs to the projected
  -- player position. Let it continue down with the mon instead of pinning it
  -- against the viewport and colliding with the player's status plate.
  y = math.max(margin, y)
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function fightRectFor(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(FIGHT_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player")
                    * (FloatingHud.FIGHT.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = footX + (FloatingHud.FIGHT.xGap or 10) * baseScale
  local y = footY - h + (FloatingHud.FIGHT.yOffset or 0) * baseScale
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = math.max(margin, y)
  return { x, y, w, h }, drawScale, logicalW, logicalH
end


local function learnRectFor(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = selectPlateLogicalSize()
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player")
                    * (FloatingHud.LEARN.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = footX + (FloatingHud.LEARN.xGap or 10) * baseScale
  local y = footY - h + (FloatingHud.LEARN.yOffset or 0) * baseScale
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = math.max(margin, y)
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function partyRectFor(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(PKMN_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player")
                    * (FloatingHud.PKMN.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = footX + (FloatingHud.PKMN.xGap or 10) * baseScale
  local y = footY - h * 0.5 + (FloatingHud.PKMN.yOffset or -10) * baseScale
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = math.max(margin, y)
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function drawPartyPanel(menu, battle, shot)
  if not (menu and battle and shot and assetImage(PKMN_PLATE_ASSET)) then
    return false
  end
  local rect, k, logicalW, logicalH = partyRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderPartyCanvas(menu, battle, k, logicalW, logicalH)
  if not canvas then return false end

  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  g.push("all")
  g.origin()
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "pkmn")
  g.pop()
  return true
end

local function itemRectFor(shot)
  if not (shot and shot.player) then return nil end
  local logicalW, logicalH = assetLogicalSize(ITEM_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local drawScale = baseScale * distanceScale(shot, "player")
                    * (FloatingHud.ITEM.scale or 1)
  local footX = shot.lx + shot.player[1] * s
  local footY = shot.ly + shot.player[2] * s
  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = footX + (FloatingHud.ITEM.xGap or 10) * baseScale
  local y = footY - h * 0.5 + (FloatingHud.ITEM.yOffset or -10) * baseScale
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = math.max(margin, y)
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function drawItemPanel(menu, battle, shot)
  if not (menu and battle and shot and assetImage(ITEM_PLATE_ASSET)) then
    return false
  end
  local rect, k, logicalW, logicalH = itemRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderItemCanvas(menu, battle, k, logicalW, logicalH)
  if not canvas then return false end

  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  g.push("all")
  g.origin()
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "item")
  g.pop()
  return true
end

local function messageRectFor(shot)
  if not shot then return nil end
  local logicalW, logicalH = assetLogicalSize(MESSAGE_PLATE_ASSET)
  if not (logicalW and logicalH) then return nil end

  local s = tonumber(shot.scale) or 1
  local baseScale = uiScale(shot)
  local playerScale = shot.player and distanceScale(shot, "player") or 1
  local enemyScale = shot.enemy and distanceScale(shot, "enemy") or 1
  local pairScale = (playerScale + enemyScale) * 0.5
  local drawScale = baseScale * pairScale * (FloatingHud.MESSAGE.scale or 1)

  local px = shot.player and shot.player[1] or 80
  local py = shot.player and shot.player[2] or 96
  local ex = shot.enemy and shot.enemy[1] or 80
  local ey = shot.enemy and shot.enemy[2] or 56
  local cx = shot.lx + ((px + ex) * 0.5) * s
             + (FloatingHud.MESSAGE.xOffset or 0) * baseScale
  local cy = shot.ly + ((py + ey) * 0.5) * s
             + (FloatingHud.MESSAGE.yOffset or 25) * baseScale

  local w = logicalW * drawScale
  local h = logicalH * drawScale
  local x = cx - w * 0.5
  local y = cy - h * 0.5
  local margin = FloatingHud.MARGIN

  x = clamp(x, margin, math.max(margin, shot.pw - w - margin))
  y = clamp(y, margin, math.max(margin, shot.ph - h - margin))
  return { x, y, w, h }, drawScale, logicalW, logicalH
end

local function drawCommandPanel(battle, shot)
  if not (battle and battle.phase == "menu" and not battle.demo and not battle.safari) then
    return false
  end

  local rect, k, logicalW, logicalH = commandRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderCommandCanvas(battle, k, logicalW, logicalH)
  if not canvas then return false end

  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "command")
  return true
end

local function drawFightPanel(battle, shot)
  if not (battle and battle.phase == "moveSelect"
      and battle.player and battle.player.curMoves
      and not battle.demo and not battle.safari) then
    return false
  end

  local rect, k, logicalW, logicalH = fightRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderFightCanvas(battle, k, logicalW, logicalH)
  if not canvas then return false end

  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "fight")
  return true
end

local function drawLearnPanel(menu, battle, shot)
  if not (menu and menu.selecting and battle and shot and selectPlateImage()) then
    return false
  end
  local rect, k, logicalW, logicalH = learnRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderLearnCanvas(menu, battle, k, logicalW, logicalH)
  if not canvas then return false end

  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "learn")
  return true
end

local function messageCameraTransform()
  local layout = FloatingHud.MESSAGE
  local rawCameraSignal = cameraYawSignal()
  local neutralSignal = FloatingHud.CAMERA_CENTER_OFFSET or 0
  local cameraSignal = clamp(
    neutralSignal
      + (rawCameraSignal - neutralSignal) * (layout.cameraSignalGain or 2.50),
    -1, 1)
  local signal = clamp((layout.perspectiveBias or -0.28)
                       + cameraSignal * (layout.cameraInfluence or 0.80), -1, 1)
  local roll = math.rad((layout.baseRotationDeg or -7.0)
                        + cameraSignal * (layout.cameraRotationDeg or 2.0))
  local pitchSignal = -clamp(
    cameraPitchSignal() * (layout.pitchSignalGain or 1.0)
      * (layout.pitchInfluence or 0.35),
    0, 1)
  return signal, roll, pitchSignal
end

local function drawMessagePanel(battle, shot)
  if not battleMessageActive(battle) then return false end
  if battle.safari or battle.demo then return false end

  local rect, k, logicalW, logicalH = messageRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderMessageCanvas(battle, k, logicalW, logicalH)
  if not canvas then return false end

  local layout = FloatingHud.MESSAGE
  local signal, roll, pitchSignal = messageCameraTransform()
  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5

  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k, signal, roll, "message",
                        layout.perspectiveDepth or 0.32,
                        layout.perspectiveWidthSqueeze or 0.12,
                        pitchSignal,
                        layout.pitchPerspectiveDepth or 0.16,
                        layout.pitchHeightSqueeze or 0.05)
  return true
end


local function drawMoveLearnMessagePanel(box, battle, shot)
  if not (box and battle and shot) then return false end
  local rect, k, logicalW, logicalH = messageRectFor(shot)
  if not rect then return false end
  local canvas, cw, ch = renderMoveLearnMessageCanvas(box, k, logicalW, logicalH)
  if not canvas then return false end

  local layout = FloatingHud.MESSAGE
  local signal, roll, pitchSignal = messageCameraTransform()
  local cx = rect[1] + rect[3] * 0.5
  local cy = rect[2] + rect[4] * 0.5
  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k, signal, roll,
                        "learn_message",
                        layout.perspectiveDepth or 0.32,
                        layout.perspectiveWidthSqueeze or 0.12,
                        pitchSignal,
                        layout.pitchPerspectiveDepth or 0.16,
                        layout.pitchHeightSqueeze or 0.05)
  return true
end

local function drawChoicePanel(choice, battle, shot)
  if not (choice and battle and shot) then return false end
  local messageRect, k = messageRectFor(shot)
  if not (messageRect and k) then return false end

  local canvas, cw, ch, logicalW, logicalH = renderChoiceCanvas(choice, k)
  if not canvas then return false end

  local layout = FloatingHud.CHOICE
  local planeW = logicalW * k
  local planeH = logicalH * k
  local cx = messageRect[1] + messageRect[3]
             - planeW * 0.5 + (layout.rightOffset or -2) * k
  local cy = messageRect[2] - planeH * 0.5 - (layout.aboveGap or 2) * k
  local signal, roll, pitchSignal = messageCameraTransform()
  local msg = FloatingHud.MESSAGE

  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k, signal, roll, "choice",
                        msg.perspectiveDepth or 0.32,
                        msg.perspectiveWidthSqueeze or 0.12,
                        pitchSignal,
                        msg.pitchPerspectiveDepth or 0.16,
                        msg.pitchHeightSqueeze or 0.05)
  return true
end

local function drawBattleFlowPanel(battle, shot)
  if not floatingCommandsEnabled() then return nil end

  local game = battle and battle.game
  local top = game and topState(game) or nil

  -- Pushed foregrounds (MoveLearnMenu/TextBox/ChoiceBox) must be painted into
  -- shot.canvas too. Desktop can get away with drawing these in render.hud after
  -- the battle viewport is composed; Android/iOS cannot reliably do so. This is
  -- the same fix that made PKMN and ITEM visible on mobile in v0.7.1.
  if moveLearnOverlayActiveForBattle(battle) then
    local choice = battle._floatingBattleChoice
    if choice and top == choice and stateInStack(game, choice) then
      local sourceText = choice.__floatingBattleChoiceText
      local drewMessage = false
      if sourceText and stateInStack(game, sourceText) then
        drewMessage = drawMoveLearnMessagePanel(sourceText, battle, shot)
      end
      local drewChoice = drawChoicePanel(choice, battle, shot)
      if drewMessage or drewChoice then
        battle._floatingBattleMoveLearnSceneFrame = battle.frame
        battle._floatingBattleChoiceSceneFrame = battle.frame
      end
      return "learn"
    end

    local text = battle._floatingBattleMoveLearnText
    if text and top == text and stateInStack(game, text) then
      if drawMoveLearnMessagePanel(text, battle, shot) then
        battle._floatingBattleMoveLearnSceneFrame = battle.frame
      end
      return "learn"
    end

    local menu = battle._floatingBattleMoveLearnMenu
    if menu and top == menu and menu.selecting and stateInStack(game, menu) then
      menu.isOpaque = false
      if drawLearnPanel(menu, battle, shot) then
        battle._floatingBattleMoveLearnSceneFrame = battle.frame
      end
      return "learn"
    end

    -- Keep the old battle text suppressed during a transient learn-flow frame,
    -- even if the pushed state changed between update and draw.
    return "learn"
  end

  -- Ordinary battle ChoiceBox uses the same scene-canvas route. This also keeps
  -- trainer switch YES/NO prompts visible on mobile before their PKMN picker is
  -- created.
  local choice = battle and battle._floatingBattleChoice or nil
  if choice and top == choice and stateInStack(game, choice) then
    local drewMessage = drawMessagePanel(battle, shot)
    local drewChoice = drawChoicePanel(choice, battle, shot)
    if drewMessage or drewChoice then
      battle._floatingBattleChoiceSceneFrame = battle.frame
    end
    return "messages"
  end

  -- PKMN and ITEM are pushed states rather than BattleState phases. Paint them
  -- directly into the staged scene; render.hud remains only a fallback.
  if partyOverlayActiveForBattle(battle) then
    local menu = battle._floatingBattlePartyMenu
    if menu and drawPartyPanel(menu, battle, shot) then
      battle._floatingBattlePartySceneFrame = battle.frame
    end
    return "party"
  end
  if itemOverlayActiveForBattle(battle) then
    local menu = battle._floatingBattleItemMenu
    if menu and drawItemPanel(menu, battle, shot) then
      battle._floatingBattleItemSceneFrame = battle.frame
    end
    return "item"
  end
  if drawMessagePanel(battle, shot) then return "messages" end
  if drawCommandPanel(battle, shot) then return "menu" end
  if drawFightPanel(battle, shot) then return "moves" end
  return nil
end

local function bottomOwnedThisFrame(battle)
  if not battle then return false end
  local owned = battle._floatingBattleBottomDrawn
  return (owned == "messages" and battle.phase == "messages")
      or (owned == "menu" and battle.phase == "menu")
      or (owned == "moves" and battle.phase == "moveSelect")
      or (owned == "party" and partyOverlayActiveForBattle(battle))
      or (owned == "item" and itemOverlayActiveForBattle(battle))
      or (owned == "learn" and moveLearnOverlayActiveForBattle(battle))
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

local function supportedFloatingLayout(battle)
  if not battle then return false end
  if vrActive() then return false end
  if OverworldBattle.backPinned and OverworldBattle.backPinned() then return false end
  if battle.safari or battle.demo or battle.blankForAskName then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- Host integration
-- ---------------------------------------------------------------------------

local hostMode = nil

-- Replacement-HUD lifecycle shared by both voxel hosts. The native Gen I HUD
-- waits for introSlide/growIn/introBalls before exposing its status blocks. A
-- replacement should not: as soon as a battler exists in the scene, its own
-- plate owns that side. This is intentionally independent of statusHUDVisible(),
-- because Potato suppresses that native surface and consulting it would hide us.
local function floatingHudLive(battle, slide)
  if not battle then return false, false end

  local enemy = battle.enemy and not battle.showEnemyTrainer
                and not battle.enemySendingOut
  local player = battle.player and not (battle.safari or battle.demo)
                 and not battle.showPlayerBack
  return enemy and true or false, player and true or false
end

-- Draw every piece of floating battle UI that belongs in the 3D world canvas.
-- Return two independent ownership flags: status plates and bottom flow UI.
-- This separation lets unfinished phases (party/items) keep using the native
-- renderer until their own floating replacement exists.
local function drawFloatingSceneUI(battle, shot, includeTextGlass)
  if battle then battle._floatingBattleBottomDrawn = nil end
  if not (battle and shot and shot.canvas and (shot.scale or 0) > 0) then
    return false, false
  end
  if not supportedFloatingLayout(battle) then return false, false end

  local wantsStatus = floatingStatusHudEnabled()
  local wantsCommands = floatingCommandsEnabled()
  if not wantsStatus and not wantsCommands then return false, false end

  local statusAssetsReady = plateImage("enemy") and plateImage("player")
  local slide = (battle.introSlide or 0) * 4
  local enemyLive, playerLive = floatingHudLive(battle, slide)
  local statusDrawn = false
  local bottomKind = nil

  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local prevShader = g.getShader()
  local ok, err = pcall(function()
    g.setCanvas(shot.canvas)
    g.setBlendMode("alpha")
    g.setShader()
    g.setColor(1, 1, 1, 1)

    if wantsStatus and statusAssetsReady and enemyLive then
      statusDrawn = drawCard(battle, shot, "enemy", battle.enemy) or statusDrawn
    end
    if wantsStatus and statusAssetsReady and playerLive then
      statusDrawn = drawCard(battle, shot, "player", battle.player) or statusDrawn
    end

    if wantsCommands then
      bottomKind = drawBattleFlowPanel(battle, shot)
    end

    -- Dramatic Shape's frosted donor panel remains useful for battle phases we
    -- have not replaced yet. Never lay it behind our new message/command art.
    if includeTextGlass and not bottomKind then
      drawTextGlass(battle, shot)
    end
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)

  if not ok then
    battle._floatingBattleBottomDrawn = nil
    mod.log:warn("floating battle UI draw failed: %s", tostring(err))
    return false, false
  end

  battle._floatingBattleBottomDrawn = bottomKind
  return statusDrawn, bottomKind ~= nil
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
    local wantStatus = floatingStatusHudEnabled()
    local wantCommands = floatingCommandsEnabled()

    -- With both layers disabled, hand the complete pass back untouched. This is
    -- the clean compatibility mode for another battle-UI mod.
    if not wantStatus and not wantCommands then
      return baseSnapHUDs(battle, shot)
    end

    local statusDrawn, bottomDrawn = drawFloatingSceneUI(battle, shot, true)

    -- Commands can remain floating while status plates are delegated. Dramatic
    -- Shape's stock snapHUDs couples status bands with text-panel glass, so call
    -- it with textRects temporarily empty: native/third-party status survives,
    -- while our custom message/command surface is not given a second backdrop.
    if not wantStatus and bottomDrawn then
      local nativeTextRects = OverworldBattle.textRects
      if type(nativeTextRects) == "function" then
        OverworldBattle.textRects = function() return {} end
      end
      local ok, nativeUp = pcall(baseSnapHUDs, battle, shot)
      OverworldBattle.textRects = nativeTextRects
      if not ok then error(nativeUp, 0) end
      return nativeUp or true
    end

    if statusDrawn or bottomDrawn then return true end
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
    local statusDrawn = drawFloatingSceneUI(battle, shot, false)
    if statusDrawn then
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
  local DRAW_KEY = "_floatingBattleHudBaseDrawHUDs"
  if not BattleState[DRAW_KEY] then
    BattleState[DRAW_KEY] = BattleState.drawHUDs
  end
  local baseDrawHUDs = BattleState[DRAW_KEY]
  if type(baseDrawHUDs) == "function" then
    function BattleState:drawHUDs(...)
      local owns = floatingStatusHudEnabled()
                   and self.dramaticShapeShot
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

  -- Suppress the native Pokemon status/nameplate surface. Bottom message/menu
  -- ownership is handled separately below and only for phases whose floating
  -- replacement already exists. Party/item UI remains native for now.
  local statusHookInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("battle.status_hud_visible", function(next, state)
      if floatingStatusHudEnabled()
          and state and state.dramaticShapeShot
          and state._floatingBattleHudPotatoDrawn then
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
        if floatingStatusHudEnabled()
            and self.dramaticShapeShot and self._floatingBattleHudPotatoDrawn then
          return false
        end
        return baseStatusHUDVisible(self, ...)
      end
    end
  end

else
  error("FLOATING_BATTLE_HUD: unsupported OverworldBattle HUD API", 0)
end

-- ---------------------------------------------------------------------------
-- Vertical navigation semantics for our vertical battle lists
-- ---------------------------------------------------------------------------
--
-- Gen1Recomp's stock command menu is a 2x2 grid, so native DOWN walks 1 -> 3:
-- exactly why a vertical visual list could only reach FIGHT and ITEM. Keep every
-- action/confirmation native, but own the directional cursor step while our
-- command panel is active. The same engine exposes moveGridNavigation(), so for
-- move selection we simply advertise a vertical list instead of its 2x2 mode.
local UPDATE_KEY = "_floatingBattleHudBaseUpdate"
if not BattleState[UPDATE_KEY] then
  BattleState[UPDATE_KEY] = BattleState.update
end
local baseBattleUpdate = BattleState[UPDATE_KEY]

if type(baseBattleUpdate) == "function" then
  function BattleState:update(...)
    local input = self.game and self.game.input
    local commandsEnabled = floatingCommandsEnabled()
    if not commandsEnabled then
      self._floatingBattlePartyPending = nil
      self._floatingBattleItemPending = nil
      self._floatingBattleItemTargetPending = nil
      self._floatingBattleChoicePartyPending = nil
    end
    local ownsCommand = commandsEnabled
                        and self.phase == "menu"
                        and self._floatingBattleBottomDrawn == "menu"
                        and input and type(input.wasPressed) == "function"

    -- Remember the exact frame a pushed battle menu is confirmed. The native
    -- battle can change phase while constructing PartyMenu/BagMenu, so testing
    -- phase inside their constructors is racy. These latches survive the handoff
    -- and are consumed only when the concrete pushed state is claimed.
    if ownsCommand and input:wasPressed("a") then
      if self.menuIndex == 2 then
        self._floatingBattlePartyPending = true
      elseif self.menuIndex == 3 then
        self._floatingBattleItemPending = true
      end
    end

    if ownsCommand then
      local up = input:wasPressed("up")
      local down = input:wasPressed("down")
      local left = input:wasPressed("left")
      local right = input:wasPressed("right")

      if up or down or left or right then
        local index = clamp(math.floor(tonumber(self.menuIndex) or 1), 1, 4)
        local delta = (up or left) and -1 or 1
        local nextIndex = ((index - 1 + delta) % 4) + 1

        -- Let the native update see the direction as usual so its cursor sound
        -- and every non-visual side effect stay intact. Afterwards replace only
        -- the cursor field with our vertical-list interpretation. No action logic
        -- is reimplemented here.
        local a, b, c = baseBattleUpdate(self, ...)
        if self.phase == "menu" then self.menuIndex = nextIndex end
        return a, b, c
      end
    end

    -- Do NOT clear the PKMN intent immediately after native update. Depending on
    -- the active renderer/UI stack, PartyMenu may be constructed or first become
    -- render-visible on the following frame. The latch is consumed only when the
    -- concrete PartyMenu is claimed.
    return baseBattleUpdate(self, ...)
  end
end

if type(BattleState.moveGridNavigation) == "function" then
  local MOVE_NAV_KEY = "_floatingBattleHudBaseMoveGridNavigation"
  if not BattleState[MOVE_NAV_KEY] then
    BattleState[MOVE_NAV_KEY] = BattleState.moveGridNavigation
  end
  local baseMoveGridNavigation = BattleState[MOVE_NAV_KEY]
  function BattleState:moveGridNavigation(...)
    if floatingCommandsEnabled()
        and self.phase == "moveSelect"
        and self._floatingBattleBottomDrawn == "moves" then
      return false
    end
    return baseMoveGridNavigation(self, ...)
  end
end

-- ---------------------------------------------------------------------------
-- Battle PartyMenu presentation
-- ---------------------------------------------------------------------------
--
-- Keep PartyMenu input/callbacks completely native. The authoritative signal
-- is the PKMN-confirmation latch set on BattleState before the engine pushes the
-- PartyMenu. `opts.battle` remains a useful hint, but some UI mods rebuild those
-- options, so the final screen.render_visible seam can claim the concrete state
-- directly from the stack even when that field has disappeared.
do
  local okParty, PartyMenu = pcall(require, "src.ui.PartyMenu")
  if okParty and type(PartyMenu) == "table"
      and not PartyMenu.__floatingBattleHudPartyPatched then
    PartyMenu.__floatingBattleHudPartyPatched = true
    local baseNew = PartyMenu.new
    local baseDraw = PartyMenu.draw
    local baseWide = PartyMenu.drawWidescreen

    local function claimBattleParty(menu, battle)
      if not floatingCommandsEnabled() then return menu end
      if not (menu and battle and assetImage(PKMN_PLATE_ASSET)) then return menu end

      menu.isOpaque = false
      menu.__floatingBattleParty = battle
      battle._floatingBattlePartyMenu = menu
      battle._floatingBattlePartyPending = nil
      battle._floatingBattleItemTargetPending = nil
      battle._floatingBattleChoicePartyPending = nil

      -- screen.render_visible can ask about the same state every frame. Never
      -- stack another update/draw wrapper onto an already-claimed PartyMenu.
      if menu.__floatingBattlePartyClaimed == battle then
        return menu
      end
      menu.__floatingBattlePartyClaimed = battle

      -- Instance-level ownership wins over later class-level skins without
      -- replacing update/input. This is important for menu overhauls that draw
      -- Party from a final HUD pass rather than directly in PartyMenu.draw.
      local nativeUpdate = menu.update
      if type(nativeUpdate) == "function" then
        menu.update = function(self, ...)
          self.isOpaque = false
          local a, b, c = nativeUpdate(self, ...)
          self.isOpaque = false
          return a, b, c
        end
      end

      menu.drawsWidescreen = function() return false end
      menu.wantsFillScale = function() return false end

      menu.draw = function(self, ...)
        self.isOpaque = false
        battle._floatingBattlePartyMenu = self
        local shot = battle.dramaticShapeShot
                  or (OverworldBattle.shot and OverworldBattle.shot())
        if shot and drawPartyPanel(self, battle, shot) then return end
        if type(baseDraw) == "function" then return baseDraw(self, ...) end
      end

      menu.drawWidescreen = function(self, ...)
        self.isOpaque = false
        battle._floatingBattlePartyMenu = self
        local shot = battle.dramaticShapeShot
                  or (OverworldBattle.shot and OverworldBattle.shot())
        if shot and drawPartyPanel(self, battle, shot) then return end
        if type(baseWide) == "function" then return baseWide(self, ...) end
      end

      return menu
    end

    if type(baseNew) == "function" then
      PartyMenu.new = function(game, opts, ...)
        opts = opts or {}
        local battle = battleStateInStack(game)
        local menu = baseNew(game, opts, ...)
        if not floatingCommandsEnabled() then return menu end

        -- The PKMN confirmation latch is the authoritative discriminator. Some
        -- UI/renderer mods rebuild PartyMenu options and drop `opts.battle`, so
        -- requiring that field lets their fullscreen Party skin escape. Keep
        -- opts.battle as a secondary hint, but never require it.
        local pending = battle and battle._floatingBattlePartyPending
        local itemTargetPending = battle and battle._floatingBattleItemTargetPending
        local choicePartyPending = battle and battle._floatingBattleChoicePartyPending
        -- Claim the mandatory faint replacement at construction time too. The old
        -- screen.render_visible fallback was late enough that mobile had already
        -- composed the underlying battle frame, leaving only an invisible PartyMenu.
        local activeMon = battle and battle.player and battle.player.mon or nil
        local forcedFaintPicker = battle and battle.player
          and (battle.player.fainted == true
               or (activeMon and tonumber(activeMon.hp) and activeMon.hp <= 0))
        -- Any PartyMenu explicitly created with opts.battle belongs to the battle
        -- flow, not only the manual PKMN command. The forced replacement picker after
        -- our active Pokémon faints uses this same constructor seam while battle.phase
        -- is no longer "menu", which is why v0.6.7 let that one native Party screen
        -- escape. Keep this narrow to the engine's own opts.battle marker.
        local nativeBattlePicker = battle and opts.battle
        -- Item-use target pickers are also ordinary PartyMenu states. Reuse the
        -- exact same floating PKMN presentation instead of allowing the native
        -- fullscreen party to reappear for Potion/Revive/etc. `pickOnly` is the
        -- engine's target-picker hint; the pending latches cover UI mods that
        -- rebuild/drop constructor opts.
        local itemTargetPicker = battle and opts.pickOnly
            and (itemTargetPending or itemOverlayActiveForBattle(battle))
        if menu and battle and (pending or nativeBattlePicker
            or itemTargetPending or itemTargetPicker or choicePartyPending
            or forcedFaintPicker) then
          return claimBattleParty(menu, battle)
        end
        return menu
      end
    end

    -- Compatibility fallback: if a host/mod constructed the battle PartyMenu via
    -- an unusual path but preserved our marker, keep the class methods capable of
    -- drawing it. Normal PKMN menus use the stronger instance-level methods above.
    if type(baseDraw) == "function" then
      PartyMenu.draw = function(self, ...)
        if not floatingCommandsEnabled() then return baseDraw(self, ...) end
        local battle = self.__floatingBattleParty
        if battle and stateInStack(self.game, self)
            and assetImage(PKMN_PLATE_ASSET) then
          self.isOpaque = false
          battle._floatingBattlePartyMenu = self
          local shot = battle.dramaticShapeShot
                    or (OverworldBattle.shot and OverworldBattle.shot())
          if shot and drawPartyPanel(self, battle, shot) then return end
        end
        return baseDraw(self, ...)
      end
    end

    if type(baseWide) == "function" then
      PartyMenu.drawWidescreen = function(self, ...)
        if not floatingCommandsEnabled() then return baseWide(self, ...) end
        local battle = self.__floatingBattleParty
        if battle and stateInStack(self.game, self)
            and assetImage(PKMN_PLATE_ASSET) then
          self.isOpaque = false
          battle._floatingBattlePartyMenu = self
          local shot = battle.dramaticShapeShot
                    or (OverworldBattle.shot and OverworldBattle.shot())
          if shot and drawPartyPanel(self, battle, shot) then return end
        end
        return baseWide(self, ...)
      end
    end

    -- Hard ownership seam copied from the working full-UI replacement strategy:
    -- screen.render_visible sits OUTSIDE PartyMenu.draw, so a later class-level
    -- skin cannot resurrect its fullscreen pixels. When the pending PKMN picker
    -- first reaches the state stack, claim that concrete state and make the
    -- native screen itself invisible while keeping update/input alive.
    if mod.hooks and type(mod.hooks.wrap) == "function" then
      mod.hooks:wrap("screen.render_visible", function(next, state)
        local visible = next(state)
        if visible == false then return false end
        if not floatingCommandsEnabled() then return visible end

        local game = state and state.game
        local battle = game and battleStateInStack(game) or nil
        -- Narrow compatibility fallback for UI mods that rebuild PartyMenu.new opts:
        -- when the active battler is actually fainted, the next concrete PartyMenu in
        -- that same battle can only be the mandatory replacement picker. This avoids
        -- the overly broad "claim every PartyMenu above a battle" experiment from the
        -- bad v0.6.8 branch.
        local activeMon = battle and battle.player and battle.player.mon or nil
        local forcedFaintParty = battle and state and getmetatable(state) == PartyMenu
          and battle.player
          and (battle.player.fainted == true
               or (activeMon and tonumber(activeMon.hp) and activeMon.hp <= 0))

        local isParty = state and (
          state.__floatingBattleParty ~= nil
          or getmetatable(state) == PartyMenu
          or (battle and (battle._floatingBattlePartyPending
                            or battle._floatingBattleItemTargetPending
                            or battle._floatingBattleChoicePartyPending)
              and type(state.party) == "table"
              and state.index ~= nil
              and type(state.bottomMessage) == "function")
        )

        if isParty and battle
            and (state.__floatingBattleParty == battle
                 or battle._floatingBattlePartyPending
                 or battle._floatingBattleItemTargetPending
                 or battle._floatingBattleChoicePartyPending
                 or forcedFaintParty
                 or battle._floatingBattlePartyMenu == state) then
          claimBattleParty(state, battle)
          state.isOpaque = false
          return false
        end
        return visible
      end, 20000)

      -- Render our PKMN plate in the final HUD pass, AFTER the state renderer.
      -- This mirrors the reference mod's architecture: PartyMenu owns all native
      -- input/state, screen.render_visible removes only its pixels, and the custom
      -- presentation is painted once on top of the still-live voxel battle.
      mod.hooks:wrap("render.hud", function(next, game, viewport)
        local out = next(game, viewport)
        if not floatingCommandsEnabled() then return out end
        local battle = battleStateInStack(game)
        local menu = battle and battle._floatingBattlePartyMenu or nil
        if menu and stateInStack(game, menu) then
          local top = game and game.stack and (
            (game.stack.top and game.stack:top())
            or (game.stack.states and game.stack.states[#game.stack.states])
          )
          if top == menu then
            menu.isOpaque = false
            local shot = battle.dramaticShapeShot
                      or (OverworldBattle.shot and OverworldBattle.shot())
            if shot and battle._floatingBattlePartySceneFrame ~= battle.frame then
              local ok, err = pcall(drawPartyPanel, menu, battle, shot)
              if not ok then
                mod.log:warn("floating PKMN HUD draw failed: %s", tostring(err))
              end
            end
          end
        end
        return out
      end, 15000)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Battle Bag / ITEM presentation
-- ---------------------------------------------------------------------------
-- BagMenu.new returns the engine's real ListMenu. Keep that state/callback path
-- authoritative, but mirror only battle-usable rows into our seven-line view.
-- A syncs the selected filtered row back to its native flat index immediately
-- before native update executes, so medicine targets, capture logic, item
-- consumption and mod hooks all remain engine-owned.
do
  local okBag, BagMenu = pcall(require, "src.ui.BagMenu")
  if okBag and type(BagMenu) == "table"
      and not BagMenu.__floatingBattleHudItemPatched then
    BagMenu.__floatingBattleHudItemPatched = true
    local baseNew = BagMenu.new

    local function claimBattleItem(menu, battle)
      if not floatingCommandsEnabled() then return menu end
      if not (menu and battle and assetImage(ITEM_PLATE_ASSET)) then return menu end
      menu.isOpaque = false
      menu.__floatingBattleItem = battle
      battle._floatingBattleItemMenu = menu
      battle._floatingBattleItemPending = nil

      if menu.__floatingBattleItemClaimed == battle then return menu end
      menu.__floatingBattleItemClaimed = battle

      local initial = menu.items and menu.items[menu.index or 1]
      refreshBattleItemView(menu, battle, initial and initial.value or nil)

      local nativeUpdate = menu.update
      if type(nativeUpdate) == "function" then
        menu.update = function(self, dt, ...)
          self.isOpaque = false
          battle._floatingBattleItemMenu = self

          -- If a third-party Bag adds a native child subflow inside the same state,
          -- let it run untouched rather than pretending our simple list owns it.
          if self.submenu or self.qtyState or self.confirm then
            return nativeUpdate(self, dt, ...)
          end

          local selectedBefore = selectedBattleItemRow(self)
          refreshBattleItemView(self, battle,
                                selectedBefore and selectedBefore.value or nil)
          local input = self.game and self.game.input
          if not (input and type(input.wasPressed) == "function") then return end

          local up = input:wasPressed("up")
          local down = input:wasPressed("down")
          if up or down then
            local delta = up and -1 or 1
            if moveBattleItemView(self, delta) then
              pcall(function()
                require("src.core.Sound").play(self.game.data, "Press_AB")
              end)
            end
            return
          end

          -- This battle surface is intentionally a single vertical list.
          if input:wasPressed("left") or input:wasPressed("right")
              or input:wasPressed("select") then
            return
          end

          if input:wasPressed("a") then
            local row = selectedBattleItemRow(self)
            local nativeIndex = row and nativeBattleItemIndex(self, row.value) or nil
            if nativeIndex then
              self.index = nativeIndex
              local nativeRows = tonumber(self.rows) or 7
              self.scroll = tonumber(self.scroll) or 0
              if self.index - self.scroll > nativeRows then
                self.scroll = self.index - nativeRows
              elseif self.index - self.scroll < 1 then
                self.scroll = self.index - 1
              end

              -- Medicine/status items can push PartyMenu synchronously from the
              -- native onChoose callback. Arm a one-action latch BEFORE native
              -- update so PartyMenu.new can claim that target picker immediately.
              battle._floatingBattleItemTargetPending = true
              local a, b, c = nativeUpdate(self, dt, ...)

              -- If no PartyMenu consumed the latch during the native action, this
              -- item did not open a target picker (Ball/X-item/etc.). Do not let a
              -- stale latch capture some unrelated Party screen later.
              if battle._floatingBattleItemTargetPending then
                battle._floatingBattleItemTargetPending = nil
              end

              if stateInStack(self.game, self) then
                refreshBattleItemView(self, battle, row.value)
              end
              return a, b, c
            end
            return
          end

          if input:wasPressed("b") then
            return nativeUpdate(self, dt, ...)
          end
          -- No input: keep the native flat cursor dormant. All gameplay work is
          -- invoked above on the exact native action paths.
        end
      end

      local nativeDraw = menu.draw
      local nativeWide = menu.drawWidescreen
      menu.drawsWidescreen = function() return false end
      menu.wantsFillScale = function() return false end
      menu.draw = function(self, ...)
        self.isOpaque = false
        battle._floatingBattleItemMenu = self
        local shot = battle.dramaticShapeShot
                  or (OverworldBattle.shot and OverworldBattle.shot())
        if shot and drawItemPanel(self, battle, shot) then return end
        if type(nativeDraw) == "function" then return nativeDraw(self, ...) end
      end
      menu.drawWidescreen = function(self, ...)
        self.isOpaque = false
        battle._floatingBattleItemMenu = self
        local shot = battle.dramaticShapeShot
                  or (OverworldBattle.shot and OverworldBattle.shot())
        if shot and drawItemPanel(self, battle, shot) then return end
        if type(nativeWide) == "function" then return nativeWide(self, ...) end
      end
      return menu
    end

    -- Useful Bag compatibility -------------------------------------------------
    -- Useful Bag replaces the public "BagMenu" screen through Data.screens.
    -- Keep that replacement everywhere except inside a staged battle owned by
    -- FLOATING COMMANDS. BattleState builds queued battle screens through
    -- buildScreen(), so this bypasses only Useful Bag's battle factory and uses
    -- the builtin BagMenu constructor captured above. Useful Bag's capacity,
    -- overworld pockets, PC behavior and sorting remain untouched.
    local function usefulBagLoaded()
      if type(mod.find) ~= "function" then return false end
      local ok, hit = pcall(mod.find, "useful_bag")
      return ok and hit ~= nil
    end

    if type(BattleState.buildScreen) == "function"
        and not BattleState.__floatingBattleHudUsefulBagCompat then
      BattleState.__floatingBattleHudUsefulBagCompat = true
      local nativeBuildScreen = BattleState.buildScreen

      BattleState.buildScreen = function(self, id, ...)
        if id == "BagMenu" and floatingCommandsEnabled() and usefulBagLoaded() then
          local opts = select(1, ...)
          if type(opts) == "table" and opts.battle then
            local menu = baseNew(self.game, opts)
            if menu then
              menu.screenId = menu.screenId or "BagMenu"
              menu.__floatingUsefulBagBypassed = true
              return claimBattleItem(menu, opts.battle or self)
            end
          end
        end
        return nativeBuildScreen(self, id, ...)
      end
    end

    if type(baseNew) == "function" then
      BagMenu.new = function(game, opts, ...)
        local battle = battleStateInStack(game)
        local menu = baseNew(game, opts, ...)
        if not floatingCommandsEnabled() then return menu end
        if menu and battle and battle._floatingBattleItemPending then
          return claimBattleItem(menu, battle)
        end
        return menu
      end
    end

    if mod.hooks and type(mod.hooks.wrap) == "function" then
      -- As with PKMN, hide the concrete pushed state at the stack-visibility seam.
      -- This wins even if another UI mod replaced ListMenu.draw after we loaded.
      mod.hooks:wrap("screen.render_visible", function(next, state)
        local visible = next(state)
        if visible == false then return false end
        if not floatingCommandsEnabled() then return visible end
        local game = state and state.game
        local battle = game and battleStateInStack(game) or nil
        local isItem = state and (
          state.__floatingBattleItem ~= nil
          or (battle and battle._floatingBattleItemPending
              and type(state.items) == "table"
              and state.index ~= nil
              and type(state.onChoose) == "function")
        )
        if isItem and battle
            and (state.__floatingBattleItem == battle
                 or battle._floatingBattleItemPending
                 or battle._floatingBattleItemMenu == state) then
          claimBattleItem(state, battle)
          state.isOpaque = false
          return false
        end
        return visible
      end, 20010)

      -- Draw after the hidden Bag state has had its normal update/input turn.
      mod.hooks:wrap("render.hud", function(next, game, viewport)
        local out = next(game, viewport)
        if not floatingCommandsEnabled() then return out end
        local battle = battleStateInStack(game)
        local menu = battle and battle._floatingBattleItemMenu or nil
        if menu and stateInStack(game, menu) then
          local top = game and game.stack and (
            (game.stack.top and game.stack:top())
            or (game.stack.states and game.stack.states[#game.stack.states])
          )
          if top == menu then
            menu.isOpaque = false
            local shot = battle.dramaticShapeShot
                      or (OverworldBattle.shot and OverworldBattle.shot())
            if shot and battle._floatingBattleItemSceneFrame ~= battle.frame then
              local ok, err = pcall(drawItemPanel, menu, battle, shot)
              if not ok then
                mod.log:warn("floating ITEM HUD draw failed: %s", tostring(err))
              end
            end
          end
        end
        return out
      end, 15100)
    end
  end
end


-- ---------------------------------------------------------------------------
-- In-battle MoveLearnMenu presentation
-- ---------------------------------------------------------------------------
-- Gen1Recomp deliberately implements move learning as a pushed MoveLearnMenu:
--   MoveLearnMenu -> TextBox(+ChoiceBox) -> SELECT old move -> result TextBox.
-- Keep every native state/callback/timing rule intact, but replace each visual
-- layer while a voxel BattleState remains underneath. The ordinary battle text
-- is suppressed for the whole foreground so transparent panels never overlap.
do
  local okLearn, MoveLearnMenu = pcall(require, "src.ui.MoveLearnMenu")
  if okLearn and type(MoveLearnMenu) == "table"
      and not MoveLearnMenu.__floatingBattleHudLearnPatched then
    MoveLearnMenu.__floatingBattleHudLearnPatched = true
    local baseNew = MoveLearnMenu.new

    local function claimLearnTextBox(box, menu, battle)
      if not (box and battle and isTextBoxState(box)) then return box end
      box.isOpaque = false
      box.__floatingBattleMoveLearnText = battle
      box.__floatingBattleMoveLearnOwner = menu
      battle._floatingBattleMoveLearnText = box
      return box
    end

    local function claimTopLearnText(menu, battle)
      local top = topState(menu and menu.game or battle and battle.game)
      if top and top ~= menu and isTextBoxState(top) then
        claimLearnTextBox(top, menu, battle)
      end
    end

    local function claimMoveLearn(menu, battle)
      if not floatingCommandsEnabled() then return menu end
      if not (menu and battle) then return menu end
      menu.isOpaque = false
      menu.__floatingBattleMoveLearn = battle
      battle._floatingBattleMoveLearnMenu = menu
      if menu.__floatingBattleMoveLearnClaimed == battle then return menu end
      menu.__floatingBattleMoveLearnClaimed = battle

      -- enter() pushes the long "trying to learn" TextBox immediately after the
      -- menu reaches the stack. Tag that concrete box rather than reproducing its
      -- paging/typewriter/YES-NO state machine ourselves.
      local nativeEnter = menu.enter
      if type(nativeEnter) == "function" then
        menu.enter = function(self, ...)
          local a, b, c = nativeEnter(self, ...)
          claimTopLearnText(self, battle)
          return a, b, c
        end
      end

      local nativeConfirm = menu.confirmAbandon
      if type(nativeConfirm) == "function" then
        menu.confirmAbandon = function(self, ...)
          local a, b, c = nativeConfirm(self, ...)
          claimTopLearnText(self, battle)
          return a, b, c
        end
      end

      local nativeFinish = menu.finish
      if type(nativeFinish) == "function" then
        menu.finish = function(self, ...)
          local a, b, c = nativeFinish(self, ...)
          -- finish() pops MoveLearnMenu and pushes the learned/did-not-learn
          -- TextBox. The menu object is still valid here, so tag that result box.
          claimTopLearnText(self, battle)
          return a, b, c
        end
      end

      local nativeUpdate = menu.update
      if type(nativeUpdate) == "function" then
        menu.update = function(self, dt, ...)
          self.isOpaque = false
          local input = self.game and self.game.input

          if self.selecting and input and type(input.wasPressed) == "function" then
            local up = input:wasPressed("up") or input:wasPressed("left")
            local down = input:wasPressed("down") or input:wasPressed("right")
            if up or down then
              -- Our SELECT presentation intentionally contains only the four real
              -- moves. B still invokes native confirmAbandon(), so the invisible
              -- fifth CANCEL row is unnecessary and cannot trap the cursor.
              local n = math.max(1, math.min(4, #(self.mon and self.mon.moves or {})))
              local index = clamp(math.floor(tonumber(self.index) or 1), 1, n)
              self.index = ((index - 1 + (up and -1 or 1)) % n) + 1
              return
            end
          end

          local a, b, c = nativeUpdate(self, dt, ...)
          self.isOpaque = false
          -- HM rejection and several native branches push TextBox directly from
          -- update(), bypassing enter/confirmAbandon/finish wrappers.
          claimTopLearnText(self, battle)
          return a, b, c
        end
      end

      -- Never let the native full-screen forget-list pixels appear. The state is
      -- still alive and authoritative; render.hud paints our SELECT clone later.
      local nativeDraw = menu.draw
      menu.draw = function(self, ...)
        self.isOpaque = false
        battle._floatingBattleMoveLearnMenu = self
        if self.selecting then return end
        if type(nativeDraw) == "function" then return nativeDraw(self, ...) end
      end

      return menu
    end

    if type(baseNew) == "function" then
      MoveLearnMenu.new = function(game, mon, newMoveId, onDone, learnedSound, ...)
        local battle = battleStateInStack(game)
        local menu = baseNew(game, mon, newMoveId, onDone, learnedSound, ...)
        if not floatingCommandsEnabled() then return menu end
        if menu and battle and not battle.safari and not battle.demo then
          return claimMoveLearn(menu, battle)
        end
        return menu
      end
    end

    if mod.hooks and type(mod.hooks.wrap) == "function" then
      -- Hide only states that we explicitly tagged as part of this move-learning
      -- foreground. This is deliberately narrower than claiming arbitrary TextBox
      -- or MoveLearnMenu instances over a battle.
      mod.hooks:wrap("screen.render_visible", function(next, state)
        local visible = next(state)
        if not floatingCommandsEnabled() then return visible end
        local game = state and state.game
        local battle = game and battleStateInStack(game) or nil
        if battle and state then
          if state.__floatingBattleMoveLearn == battle then
            state.isOpaque = false
            battle._floatingBattleMoveLearnMenu = state
            return false
          end
          if state.__floatingBattleMoveLearnText == battle then
            state.isOpaque = false
            battle._floatingBattleMoveLearnText = state
            return false
          end
        end
        return visible
      end, 20015)

      mod.hooks:wrap("render.hud", function(next, game, viewport)
        local out = next(game, viewport)
        if not floatingCommandsEnabled() then return out end
        local battle = battleStateInStack(game)
        if not battle then return out end
        local top = topState(game)
        local shot = battle.dramaticShapeShot
                  or (OverworldBattle.shot and OverworldBattle.shot())
        if not shot then return out end

        local text = battle._floatingBattleMoveLearnText
        if text and top == text and stateInStack(game, text) then
          if battle._floatingBattleMoveLearnSceneFrame ~= battle.frame then
            local ok, err = pcall(drawMoveLearnMessagePanel, text, battle, shot)
            if not ok then
              mod.log:warn("floating move-learn message failed: %s", tostring(err))
            end
          end
          return out
        elseif text and not stateInStack(game, text) then
          battle._floatingBattleMoveLearnText = nil
        end

        local menu = battle._floatingBattleMoveLearnMenu
        if menu and top == menu and menu.selecting and stateInStack(game, menu) then
          menu.isOpaque = false
          if battle._floatingBattleMoveLearnSceneFrame ~= battle.frame then
            local ok, err = pcall(drawLearnPanel, menu, battle, shot)
            if not ok then
              mod.log:warn("floating move-learn SELECT failed: %s", tostring(err))
            end
          end
        elseif menu and not stateInStack(game, menu) then
          battle._floatingBattleMoveLearnMenu = nil
        end
        return out
      end, 15150)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Battle YES / NO presentation
-- ---------------------------------------------------------------------------
-- Battle sayChoice pushes a real ChoiceBox above BattleState. Keep that box as
-- the sole input/callback authority, hide only its pixels, and paint horizontal
-- YES / NO above our existing message plate. If YES opens a PartyMenu (trainer
-- switch prompt), a short latch lets the PKMN backend claim that picker too.
do
  local okChoice, ChoiceBox = pcall(require, "src.ui.ChoiceBox")
  if okChoice and type(ChoiceBox) == "table"
      and not ChoiceBox.__floatingBattleHudChoicePatched then
    ChoiceBox.__floatingBattleHudChoicePatched = true
    local baseNew = ChoiceBox.new

    local function claimBattleChoice(choice, battle, sourceText)
      if not floatingCommandsEnabled() then return choice end
      if not (choice and battle) then return choice end
      choice.isOpaque = false
      choice.__floatingBattleChoice = battle
      choice.__floatingBattleChoiceText = sourceText
      battle._floatingBattleChoice = choice

      if choice.__floatingBattleChoiceClaimed == battle then return choice end
      choice.__floatingBattleChoiceClaimed = battle

      local nativeUpdate = choice.update
      if type(nativeUpdate) == "function" then
        choice.update = function(self, dt, ...)
          self.isOpaque = false
          battle._floatingBattleChoice = self
          local input = self.game and self.game.input

          -- The presented pair is horizontal, but accept both axes so keyboard,
          -- D-pad and existing muscle memory all remain comfortable.
          if self.pending == nil and input and type(input.wasPressed) == "function" then
            if input:wasPressed("left") or input:wasPressed("up") then
              self.index = 1
              return
            elseif input:wasPressed("right") or input:wasPressed("down") then
              self.index = 2
              return
            end

            -- A YES may invoke the trainer-switch callback. Arm before native
            -- ChoiceBox update; PartyMenu.new consumes it if that callback pushes
            -- a picker. It intentionally survives ChoiceBox's short pending/hold.
            if input:wasPressed("a") and (tonumber(self.index) or 1) == 1
                and not self.__floatingBattleChoiceText then
              battle._floatingBattleChoicePartyPending = true
            end
          end

          local a, b, c = nativeUpdate(self, dt, ...)
          self.isOpaque = false

          -- Once the ChoiceBox has actually left the stack, a synchronous YES
          -- callback has already had its chance to construct PartyMenu. If no
          -- picker consumed the latch, discard it.
          if not stateInStack(self.game, self)
              and battle._floatingBattleChoicePartyPending then
            battle._floatingBattleChoicePartyPending = nil
          end
          return a, b, c
        end
      end

      return choice
    end

    if type(baseNew) == "function" then
      ChoiceBox.new = function(game, onChoose, opts, ...)
        local battle = battleStateInStack(game)
        local sourceText = moveLearnTextBoxInStack(game)
        local choice = baseNew(game, onChoose, opts, ...)
        if not floatingCommandsEnabled() then return choice end
        -- A move-learning TextBox owns its own prompt and must replace the stale
        -- battle message below it. Ordinary battle choices keep the old path.
        if choice and battle and sourceText
            and sourceText.__floatingBattleMoveLearnText == battle then
          return claimBattleChoice(choice, battle, sourceText)
        end
        if choice and battle and battle.phase == "messages" then
          return claimBattleChoice(choice, battle, nil)
        end
        return choice
      end
    end

    if mod.hooks and type(mod.hooks.wrap) == "function" then
      mod.hooks:wrap("screen.render_visible", function(next, state)
        local visible = next(state)
        if visible == false then return false end
        if not floatingCommandsEnabled() then return visible end
        local game = state and state.game
        local stackedBattle = game and battleStateInStack(game) or nil
        local battle = state and state.__floatingBattleChoice or stackedBattle
        local sourceText = state and state.__floatingBattleChoiceText
          or (game and moveLearnTextBoxInStack(game) or nil)
        local isLearnChoice = state and battle and sourceText
          and sourceText.__floatingBattleMoveLearnText == battle
          and getmetatable(state) == ChoiceBox
        local isBattleChoice = state and battle and battle.phase == "messages"
          and (state.__floatingBattleChoice == battle
               or getmetatable(state) == ChoiceBox)
        if isLearnChoice or isBattleChoice then
          claimBattleChoice(state, battle, isLearnChoice and sourceText or nil)
          state.isOpaque = false
          return false
        end
        return visible
      end, 20020)

      mod.hooks:wrap("render.hud", function(next, game, viewport)
        local out = next(game, viewport)
        if not floatingCommandsEnabled() then return out end
        local battle = battleStateInStack(game)
        local choice = battle and battle._floatingBattleChoice or nil
        if choice and stateInStack(game, choice) then
          local top = game and game.stack and (
            (game.stack.top and game.stack:top())
            or (game.stack.states and game.stack.states[#game.stack.states])
          )
          if top == choice then
            choice.isOpaque = false
            local shot = battle.dramaticShapeShot
                      or (OverworldBattle.shot and OverworldBattle.shot())
            if shot and battle._floatingBattleChoiceSceneFrame ~= battle.frame then
              -- Fallback only. The preferred path now paints ChoiceBox into the
              -- staged battle canvas before mobile composites the viewport.
              local sourceText = choice.__floatingBattleChoiceText
              local okMsg, errMsg
              if sourceText and stateInStack(game, sourceText) then
                okMsg, errMsg = pcall(drawMoveLearnMessagePanel, sourceText, battle, shot)
              else
                okMsg, errMsg = pcall(drawMessagePanel, battle, shot)
              end
              if not okMsg then
                mod.log:warn("floating battle choice message failed: %s", tostring(errMsg))
              end
              local okPick, errPick = pcall(drawChoicePanel, choice, battle, shot)
              if not okPick then
                mod.log:warn("floating YES/NO HUD draw failed: %s", tostring(errPick))
              end
            end
          end
        elseif battle then
          battle._floatingBattleChoice = nil
        end
        return out
      end, 15200)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Native bottom-UI suppression for the phases we already replace
-- ---------------------------------------------------------------------------
--
-- Keep BattleState:drawTextArea alive under an empty scissor rather than
-- skipping it. Gen1Recomp stores some presentation lifecycle work there, while
-- our replacement only wants ownership of its pixels. Messages, the main
-- command menu and move selection are claimed here; pushed PKMN and ITEM states
-- are suppressed at their state-stack seams above.
local TEXT_KEY = "_floatingBattleHudBaseDrawTextArea"
if not BattleState[TEXT_KEY] then
  BattleState[TEXT_KEY] = BattleState.drawTextArea
end
local baseDrawTextArea = BattleState[TEXT_KEY]
if type(baseDrawTextArea) == "function" then
  function BattleState:drawTextArea(...)
    -- Once a normal voxel battle has a staged shot, Floating Battle HUD owns the
    -- complete lower battle surface. Suppress native pixels immediately instead
    -- of waiting for our per-frame phase marker; that marker is not established
    -- yet on frame zero and allowed Gen1's blank white text box to flash once.
    -- Safari/demo remain native because this mod intentionally does not replace
    -- their specialized bottom UI.
    local ownsBottomSurface = floatingCommandsEnabled()
      and self.dramaticShapeShot
      and not self.safari and not self.demo
    if ownsBottomSurface then
      g.push("all")
      g.setScissor(0, 0, 0, 0)
      local ok, result = pcall(baseDrawTextArea, self, ...)
      g.pop()
      if not ok then error(result, 0) end
      return result
    end
    return baseDrawTextArea(self, ...)
  end
end

local bottomHookInstalled = false
if mod.hooks and type(mod.hooks.wrap) == "function" then
  mod.hooks:wrap("battle.bottom_ui_visible", function(next, state)
    if floatingCommandsEnabled()
        and state and state.dramaticShapeShot
        and not state.safari and not state.demo then
      return false
    end
    return next(state)
  end, 12000)
  bottomHookInstalled = true
end

-- Compatibility fallback when the launcher visibility hook is unavailable.
if not bottomHookInstalled then
  local BOTTOM_KEY = "_floatingBattleHudBaseBottomUIVisible"
  if not BattleState[BOTTOM_KEY] then
    BattleState[BOTTOM_KEY] = BattleState.bottomUIVisible
  end
  local baseBottomUIVisible = BattleState[BOTTOM_KEY]
  if type(baseBottomUIVisible) == "function" then
    function BattleState:bottomUIVisible(...)
      if floatingCommandsEnabled()
          and self.dramaticShapeShot and not self.safari and not self.demo then
        return false
      end
      return baseBottomUIVisible(self, ...)
    end
  end
end

mod.exports.version = "0.7.2"
mod.exports.floatingHud = FloatingHud
mod.exports.hostMode = hostMode
mod.log:info("Floating Battle HUD 0.7.2 installed over %s %s (%s)",
             tostring(hostId or "voxel host"), tostring(ds.version), tostring(hostMode))
