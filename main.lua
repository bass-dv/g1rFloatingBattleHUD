-- Floating Battle HUD v0.7.18
-- Companion mod for Dramatic Shape / PotatoVoxel / Voxel Ascendant staged battles.
--
-- v0.3 is the visual reset: the frosted cards are gone. The HUD is built
-- around x8 transparent battleplate art inspired by Gen I's original battle
-- furniture, while the live information remains code-driven and follows
-- Dramatic Shape's projected Pokemon positions every frame.

local mod = ...

-- Dramatic Shape, PotatoVoxel and Voxel Ascendant expose the same public
-- companion-module seam. Probe the known manifest ids and adapt to the HUD
-- integration owned by whichever host is installed.
local HOST_IDS = {
  "DRAMATIC_SHAPE",
  "POTATO_VOXEL",
  "POTATO_VOXEL_MOD",
  "potato_voxel",
  "VOXEL_ASCENDANT",
  "voxel_ascendant",
}
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
  return
end

local V = ds.exports.lib
local OverworldBattle = V.require("OverworldBattle")
local BattleCam = V.require("BattleCam")

-- Ascendant advertises its renderer identity through exports.renderer even when a
-- packaging fork uses a different manifest id. Prefer that stable public identity.
local rendererId = ds.exports and ds.exports.renderer and ds.exports.renderer.id or nil
local isAscendantHost = hostId == "VOXEL_ASCENDANT"
                     or hostId == "voxel_ascendant"
                     or rendererId == "VOXEL_ASCENDANT"

-- Voxel Ascendant intentionally withholds its legacy cross-canvas HUD compositor
-- on iOS: Gen1Recomp presents the world canvas inverted there. Floating Battle HUD
-- follows the same fail-closed rule and leaves the complete native battle UI alone
-- on iOS (and on an Ascendant platform the engine cannot identify).
local function detectedOS()
  local ok, Platform = pcall(require, "src.core.Platform")
  if not ok or type(Platform) ~= "table" or type(Platform.detect) ~= "function" then
    return nil
  end
  local detected, info = pcall(Platform.detect)
  if not detected or type(info) ~= "table" or type(info.os) ~= "string" then
    return nil
  end
  return info.os
end

local PLATFORM_OS = detectedOS()
local hostFloatingAvailable = not isAscendantHost
  or (PLATFORM_OS ~= nil and PLATFORM_OS ~= "iOS")

-- Legacy Dramatic Shape alone exposes the donor BattleHud/textRects composite we
-- reuse for unreplaced phases. Ascendant may also advertise snapHUDs off iOS, but
-- its public facade deliberately does not expose BattleHud and its active path is
-- drawHudPanels, so never classify it as Dramatic Shape from snapHUDs alone.
local BattleHud = nil
if not isAscendantHost and type(OverworldBattle.snapHUDs) == "function" then
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

-- Gen I's SE_WAVY_SCREEN (used by Psychic, Night Shade and Psywave) scrolls
-- the complete BG tilemap one scanline at a time. In a staged voxel battle the
-- world and this mod's floating plates live in shot.canvas instead, so the
-- engine's original pass has almost nothing left to bend. Reapply the same
-- eight-step offset pattern to the staged canvas while that semantic effect is
-- active. The move's OAM sprites are still drawn later by BattleState and stay
-- unwarped, matching the original BG-vs-OBJ split.
local SCENE_WAVE_SHADER_SOURCE = [[
  uniform float wavePhase;
  uniform float rowScale;
  uniform float rowOrigin;
  uniform vec2 canvasSize;

  float waveOffset(float index) {
    float i = mod(index + 1024.0, 32.0);
    if (i < 5.0) return 0.0;
    if (i < 8.0) return 1.0;
    if (i < 13.0) return 2.0;
    if (i < 16.0) return 1.0;
    if (i < 21.0) return 0.0;
    if (i < 24.0) return -1.0;
    if (i < 29.0) return -2.0;
    return -1.0;
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float logicalRow = floor((tc.y * canvasSize.y - rowOrigin)
                             / max(1.0, rowScale));
    float dx = waveOffset(logicalRow + wavePhase) * rowScale;
    float sourceX = tc.x * canvasSize.x - dx;
    if (sourceX < 0.0 || sourceX >= canvasSize.x) discard;
    return Texel(tex, vec2(sourceX / canvasSize.x, tc.y)) * color;
  }
]]

local sceneWaveShader = nil
local sceneWaveShaderUnavailable = false
local sceneWaveCanvas = nil
local sceneWaveW, sceneWaveH = nil, nil
local sceneWaveWarned = false

local function getSceneWaveShader()
  if sceneWaveShaderUnavailable then return nil end
  if sceneWaveShader then return sceneWaveShader end
  local ok, shader = pcall(g.newShader, SCENE_WAVE_SHADER_SOURCE)
  if not (ok and shader) then
    sceneWaveShaderUnavailable = true
    if not sceneWaveWarned then
      sceneWaveWarned = true
      mod.log:warn("floating battle scene wave unavailable: %s",
                   tostring(shader))
    end
    return nil
  end
  sceneWaveShader = shader
  return shader
end

local function getSceneWaveCanvas(w, h)
  if sceneWaveCanvas and sceneWaveW == w and sceneWaveH == h then
    return sceneWaveCanvas
  end
  local ok, canvas = pcall(g.newCanvas, w, h, { dpiscale = 1 })
  if not (ok and canvas) then return nil end
  pcall(canvas.setFilter, canvas, "nearest", "nearest")
  sceneWaveCanvas, sceneWaveW, sceneWaveH = canvas, w, h
  return canvas
end

local function applySceneWave(battle, shot)
  local wavy = battle and battle.fx and battle.fx.wavy
  local target = shot and shot.canvas
  if not (wavy and target and PLATFORM_OS ~= "iOS") then return false end
  if battle._floatingBattleSceneWaveFrame == battle.frame
      and battle._floatingBattleSceneWaveTarget == target then
    return true
  end

  local shader = getSceneWaveShader()
  local width, height = target:getWidth(), target:getHeight()
  local copy = shader and getSceneWaveCanvas(width, height) or nil
  if not copy then return false end

  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local prevShader = g.getShader()
  local prevR, prevG, prevB, prevA = g.getColor()
  g.push("all")
  local ok, err = pcall(function()
    g.origin()
    g.setScissor()
    -- First take a stable snapshot. Sampling from the canvas currently being
    -- written is undefined on several LOVE backends, especially Android.
    g.setCanvas(copy)
    g.setShader()
    g.setBlendMode("replace", "premultiplied")
    g.clear(0, 0, 0, 0)
    g.setColor(1, 1, 1, 1)
    g.draw(target, 0, 0)

    -- Draw the shifted snapshot over the original. Discarded edge pixels leave
    -- the unshifted world visible instead of creating black side slivers.
    g.setCanvas(target)
    g.setBlendMode("alpha")
    g.setShader(shader)
    shader:send("wavePhase", tonumber(wavy.phase) or 0)
    shader:send("rowScale", math.max(1, tonumber(shot.scale) or 1))
    shader:send("rowOrigin", tonumber(shot.ly) or 0)
    shader:send("canvasSize", { width, height })
    g.setColor(1, 1, 1, 1)
    g.draw(copy, 0, 0)
  end)
  g.pop()

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(prevR, prevG, prevB, prevA)
  if not ok then error(err, 0) end

  battle._floatingBattleSceneWaveFrame = battle.frame
  battle._floatingBattleSceneWaveTarget = target
  return true
end

-- One accessor for the three host families. Dramatic Shape / PotatoVoxel attach
-- their current staged shot directly to BattleState; Ascendant uses its own field
-- and also exposes OverworldBattle.shot(). Keeping this translation here prevents
-- host-specific names from leaking through every pushed menu/foreground path.
local function battleShot(battle)
  if not hostFloatingAvailable then return nil end
  if battle then
    local direct = battle.voxelAscendantShot or battle.dramaticShapeShot
    if direct and direct.canvas then return direct end
  end
  if OverworldBattle and type(OverworldBattle.shot) == "function" then
    local ok, shot = pcall(OverworldBattle.shot)
    if ok and shot and shot.canvas then return shot end
  end
  return nil
end

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
      { "x3",    3.0 },
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
  return hostFloatingAvailable and optionToggle("floating_status_hud", true)
end

local function floatingCommandsEnabled()
  return hostFloatingAvailable and optionToggle("floating_commands", true)
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
FloatingHud.SHADOW_GROW_PX = 3
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
local FIGHT_DIVIDER_ASSET = "assets/hud/fight_command_divider.png"
local FIGHT_CATEGORY_ASSETS = {
  -- The authored PHYSICAL/STATUS glyph files are intentionally crossed here:
  -- the visual symbols in the supplied assets were opposite to their filenames.
  PHYSICAL = "assets/hud/fight_kind_status.png",
  SPECIAL  = "assets/hud/fight_kind_special.png",
  STATUS   = "assets/hud/fight_kind_physical.png",
}
local TRAINER_BALL_ASSETS = {
  alive    = "assets/hud/battleplate_ball.png",
  active   = "assets/hud/battleplate_ball_active.png",
  defeated = "assets/hud/battleplate_ball_defeated.png",
  empty    = "assets/hud/battleplate_ball_empty.png",
}
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

-- Trainer-only enemy party strip, projected as a small companion plane directly
-- below the enemy battleplate. Six slots are always shown: active, healthy,
-- defeated, and unused slots each have dedicated authored art.
FloatingHud.TRAINER_TEAM = {
  slots = 6,
  gap = 1.75,
  rowGap = 1.5,
  scale = 1.0,
  yOffset = -15.0,
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

-- Voluntary PKMN selection opens PartyMenu's native SWITCH / STATS / CANCEL
-- submenu. The native PartyMenu remains the input/callback authority; this block
-- only gives that hidden submenu the same floating, scale-to-select language as
-- YES / NO. It is kept separate so tuning it never changes the battle prompt.
FloatingHud.PARTY_CHOICE = {
  logicalW = 96.0,
  logicalH = 78.0,
  rightOffset = -2.0,
  aboveGap = 2.0,

  centerX = 48.0,
  firstCenterY = 14.0,
  rowStep = 25.0,

  selectedScale = 1.65,
  idleScale = 1.05,
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
  -- Moves every dynamic FIGHT element together without moving the authored plate.
  -- Negative = up, positive = down.
  contentYOffset = -10.0,

  -- Extra transparent render room above the authored FIGHT plate. This expands
  -- only the offscreen canvas, so descriptions can grow upward without clipping
  -- while the plate keeps its exact projected position and scale.
  canvasTopPad = 12.0,

  -- The updated authored plate is wider/taller so the list can show PP totals
  -- and a compact move-detail header without shrinking the main battle scene.
  scale = 1.0,
  listScale = 1.07,
  listAnchorX = 0.0,
  listAnchorY = 0.0,

  selectorX = 43.0,
  selectorYOffset = 0.0,
  typeX = 55.0,
  typeYOffset = 0.0,
  typeW = 4.0,
  typeH = 7.0,
  textX = 65.0,
  ppRight = 216.0,
  ppScale = 1.0,
  ppYOffset = -1.0,
  firstY = 49.0,
  rowStep = 17.0,

  -- Short divider from the revised mockup. It deliberately stops before the
  -- numeric stat cluster instead of spanning the complete detail header.
  dividerX = 55.0,
  dividerY = 30.0,
  dividerScale = 1.0,

  -- Descriptions are left-anchored and bottom-anchored: one-line descriptions
  -- sit close to the divider while longer text grows upward, as in the mockup.
  descX = 54.0,
  descBottomY = 13.0,
  descWidth = 170.0,
  descScale = 0.78,
  descLineStep = 9.0,
  descMaxLines = 3,

  -- Accuracy is right-aligned immediately before the % glyph. The category icon
  -- owns the middle slot and power grows rightward from a fixed left margin.
  statsY = 25.0,
  statsScale = 1.0,
  statsAccPercentX = 225.0, -- NUMERO DE % >
  statsAccGap = 1.0, -- ESPACIO DE % >
  statsCategoryX = 158.0, -- CATEGORÍA
  statsCategoryY = 24.0,
  statsCategoryScale = 1.0,
  statsPowerX = 170.0, -- NUMERO DE PODER
}

-- Move-learning replacement picker. It deliberately mirrors FIGHT so the same
-- widened text/PP/details treatment also applies while choosing a move to forget.
-- Drop assets/hud/select_command_plate.png into the mod later and it will be used
-- automatically without changing code or the normal FIGHT plate.
FloatingHud.LEARN = {
  xGap = 27.0,
  yOffset = 30.0,
  -- Moves every dynamic FIGHT element together without moving the authored plate.
  -- Negative = up, positive = down.
  contentYOffset = -5.0,

  -- The updated authored plate is wider/taller so the list can show PP totals
  -- and a compact move-detail header without shrinking the main battle scene.
  scale = 1.0,
  listScale = 1.0,
  listAnchorX = 0.0,
  listAnchorY = 0.0,

  selectorX = 43.0,
  selectorYOffset = 0.0,
  typeX = 55.0,
  typeYOffset = 0.0,
  typeW = 4.0,
  typeH = 7.0,
  textX = 65.0,
  ppRight = 216.0,
  ppScale = 1.0,
  ppYOffset = -1.0,
  firstY = 49.0,
  rowStep = 17.0,

  -- Short divider from the revised mockup. It deliberately stops before the
  -- numeric stat cluster instead of spanning the complete detail header.
  dividerX = 55.0,
  dividerY = 30.0,
  dividerScale = 1.0,

  -- Descriptions are left-anchored and bottom-anchored: one-line descriptions
  -- sit close to the divider while longer text grows upward, as in the mockup.
  descX = 54.0,
  descBottomY = 13.0,
  descWidth = 165.0,
  descScale = 0.78,
  descLineStep = 9.0,
  descMaxLines = 3,

  -- Accuracy is right-aligned immediately before the % glyph. The category icon
  -- owns the middle slot and power grows rightward from a fixed left margin.
  statsY = 25.0,
  statsScale = 1.0,
  statsAccPercentX = 207.0, -- NUMERO DE % >
  statsAccGap = 1.0, -- ESPACIO DE % >
  statsCategoryX = 136.0, -- CATEGORÍA
  statsCategoryY = 24.0,
  statsCategoryScale = 1.0,
  statsPowerX = 148.0, -- NUMERO DE PODER
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
  quantityRight = 216.0,
  quantityScale = 1.0,
  quantityYOffset = -2.0,
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
  local potatoHost = not isAscendantHost
                  and type(OverworldBattle.snapHUDs) ~= "function"
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

-- AskName is another pushed TextBox + ChoiceBox flow, but unlike move learning
-- the stock battle intentionally blanks the whole field while it is active.
-- Keep a semantic marker on the concrete TextBox so we can leave the staged
-- battlefield visible and render that exact native text through our message plate.
local function nicknameTextBoxInStack(game)
  local states = game and game.stack and game.stack.states
  if not states then return nil end
  for i = #states, 1, -1 do
    local state = states[i]
    if state and state.__floatingBattleNicknameText then return state end
  end
  return nil
end

local function nicknameOverlayActiveForBattle(battle)
  if not battle then return false end
  local text = battle._floatingBattleNicknameText
  if text and stateInStack(battle.game, text) then return true end
  if text then battle._floatingBattleNicknameText = nil end
  return false
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

local function panelCanvas(key, logicalW, logicalH, topExtra)
  local pad = FloatingHud.CANVAS_PAD or 0
  topExtra = math.max(0, tonumber(topExtra) or 0)
  local raster = math.max(1, tonumber(FloatingHud.CANVAS_RENDER_SCALE) or 1)
  local logicalCW = logicalW + pad * 2
  local logicalCH = logicalH + pad * 2 + topExtra
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

-- PartyMenu does not push a ChoiceBox for voluntary battle switching. Instead it
-- flips `menu.submenu` and keeps SWITCH / STATS / CANCEL in `menu.subItems`, with
-- `menu.subIndex` as the live native cursor. Because we hide PartyMenu's own pixels,
-- that submenu used to exist logically but had no replacement drawing at all.
local function renderPartyChoiceCanvas(menu, k)
  if not (menu and menu.submenu and type(menu.subItems) == "table"
      and #menu.subItems > 0) then return nil end

  local layout = FloatingHud.PARTY_CHOICE or FloatingHud.CHOICE
  local count = #menu.subItems
  local selectedScale = layout.selectedScale or 1.65
  local idleScale = layout.idleScale or 1.05
  local firstY = layout.firstCenterY or 14
  local rowStep = layout.rowStep or 25

  -- Native battle currently supplies exactly three rows, but size from the live
  -- list so a ui.party.submenu hook cannot create an invisible extra option.
  local maxTextW = 0
  for i = 1, count do
    local entry = menu.subItems[i]
    local label = tostring((entry and entry.label) or "")
    maxTextW = math.max(maxTextW, textWidth(label) * selectedScale)
  end
  local logicalW = math.max(layout.logicalW or 96, maxTextW + 12)
  local lastY = firstY + (count - 1) * rowStep
  local logicalH = math.max(layout.logicalH or 78, lastY + 14)

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("party_choice", logicalW, logicalH)
  if not canvas then return nil end

  local selected = clamp(math.floor(tonumber(menu.subIndex) or 1), 1, count)
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

    local centerX = layout.centerX or (logicalW * 0.5)
    -- If logicalW had to grow for a hook-added long label, keep the list centered
    -- in the actual plane rather than at the original authored width's midpoint.
    if logicalW ~= (layout.logicalW or 96) then centerX = logicalW * 0.5 end

    for i = 1, count do
      local entry = menu.subItems[i]
      local label = tostring((entry and entry.label) or "")
      local scale = i == selected and selectedScale or idleScale
      local cy = firstY + (i - 1) * rowStep
      local w = textWidth(label) * scale
      local h = 8 * scale
      drawShadowText(label, centerX - w * 0.5, cy - h * 0.5, k, scale)
    end

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

local SPECIAL_MOVE_TYPES = {
  FIRE = true,
  WATER = true,
  GRASS = true,
  ELECTRIC = true,
  ICE = true,
  PSYCHIC = true,
  DRAGON = true,
}

local function moveMaxPPValues(battle, move)
  local def = moveDefinition(battle, move)
  local cur = type(move) == "table"
    and (tonumber(move.pp) or tonumber(move.currentPP) or tonumber(move.currentPp))
    or nil
  local maxpp = type(move) == "table"
    and (tonumber(move.maxPP) or tonumber(move.maxPp))
    or nil
  if maxpp == nil then maxpp = def and tonumber(def.pp) or cur or 0 end
  if cur == nil then cur = maxpp or 0 end
  return math.max(0, math.floor((cur or 0) + 0.5)),
         math.max(0, math.floor((maxpp or 0) + 0.5))
end

-- Gen1Recomp builds its vanilla move records directly from the ROM, so those
-- records intentionally contain mechanics (effect/power/type/accuracy/PP) but
-- no prose description. Keep authored/custom descriptions first, then provide a
-- compact RBY fallback using Smogon's RB move wording/semantics.
local SMOGON_RB_MOVE_DESCRIPTIONS = {
  BIDE = "Waits 2-3 turns; deals double the damage taken.",
  CONVERSION = "User becomes the same type as the target.",
  FOCUS_ENERGY = "Quarters the user's chance for a critical hit.",
  HAZE = "Resets all stat changes. Removes foe's status.",
  LIGHT_SCREEN = "While active, user's Special is 2x when damaged.",
  MIRROR_MOVE = "User uses the target's last used move against it.",
  MIST = "While active, user is protected from stat drops.",
  REFLECT = "While active, the user's Defense is doubled.",
  REST = "User sleeps 2 turns and restores HP and status.",
  SPLASH = "No competitive use.",
  SUBSTITUTE = "User takes 1/4 its max HP to put in a Substitute.",
  TOXIC = "Badly poisons the target.",
  SWIFT = "Never misses, even against Dig and Fly.",
  TRANSFORM = "Copies target's stats, moves, types, and species.",

  COUNTER = "If hit by Normal/Fighting move, deals 2x damage.",
  DRAGON_RAGE = "Deals 40 HP of damage to the target.",
  NIGHT_SHADE = "Damage = user's level. Can hit Normal types.",
  PSYWAVE = "Random damage from 1 to (user's level*1.5 - 1).",
  SEISMIC_TOSS = "Damage = user's level. Can hit Ghost types.",
  SONICBOOM = "Deals 20 HP of damage to the target.",
  SUPER_FANG = "Deals damage equal to half the target's current HP.",

  DOUBLE_KICK = "Hits 2 times.",
  TWINEEDLE = "Hits 2 times. Last hit has 20% chance to poison.",
  FLY = "Flies up on first turn, attacks on second.",
  DIG = "Digs underground turn 1, strikes turn 2.",
  RAZOR_WIND = "Charges turn 1. Hits turn 2.",
  SKULL_BASH = "Charges turn 1. Hits turn 2.",
  SOLARBEAM = "Charges turn 1. Hits turn 2.",

  HYPER_BEAM = "Can't move next turn if target or sub is not KOed.",
  RAGE = "Lasts forever. Raises user's Attack by 1 when hit.",
  MIMIC = "Random move known by the target replaces this.",
  METRONOME = "Picks a random move.",
  LEECH_SEED = "1/16 of target's HP is restored to user every turn.",
  DISABLE = "For 0-7 turns, disables one of the target's moves.",
  DREAM_EATER = "User gains 1/2 HP inflicted. Sleeping target only.",
  PAY_DAY = "Scatters coins.",
  ROAR = "In battles, the opponent switches. In the wild, the Pokémon runs.",
  TELEPORT = "No competitive use.",
  WHIRLWIND = "No competitive use.",
}

local SMOGON_RB_EFFECT_DESCRIPTIONS = {
  DRAIN_HP_EFFECT = "User recovers 50% of the damage dealt.",
  BURN_SIDE_EFFECT1 = "10% chance to burn the target.",
  FREEZE_SIDE_EFFECT1 = "10% chance to freeze the target.",
  PARALYZE_SIDE_EFFECT1 = "10% chance to paralyze the target.",
  POISON_SIDE_EFFECT1 = "20% chance to poison the target.",
  EXPLODE_EFFECT = "Target's Def halved during damage. User faints.",
  DREAM_EATER_EFFECT = "User gains 1/2 HP inflicted. Sleeping target only.",
  MIRROR_MOVE_EFFECT = "User uses the target's last used move against it.",

  ATTACK_UP1_EFFECT = "Raises the user's Attack by 1.",
  DEFENSE_UP1_EFFECT = "Raises the user's Defense by 1.",
  SPEED_UP1_EFFECT = "Raises the user's Speed by 1.",
  SPECIAL_UP1_EFFECT = "Raises the user's Special by 1.",
  ACCURACY_UP1_EFFECT = "Raises the user's accuracy by 1.",
  EVASION_UP1_EFFECT = "Raises the user's evasiveness by 1.",
  ATTACK_DOWN1_EFFECT = "Lowers the target's Attack by 1.",
  DEFENSE_DOWN1_EFFECT = "Lowers the target's Defense by 1.",
  SPEED_DOWN1_EFFECT = "Lowers the target's Speed by 1.",
  SPECIAL_DOWN1_EFFECT = "Lowers the target's Special by 1.",
  ACCURACY_DOWN1_EFFECT = "Lowers the target's accuracy by 1.",
  EVASION_DOWN1_EFFECT = "Lowers the target's evasiveness by 1.",

  ATTACK_UP2_EFFECT = "Raises the user's Attack by 2.",
  DEFENSE_UP2_EFFECT = "Raises the user's Defense by 2.",
  SPEED_UP2_EFFECT = "Raises the user's Speed by 2.",
  SPECIAL_UP2_EFFECT = "Raises the user's Special by 2.",
  ACCURACY_UP2_EFFECT = "Raises the user's accuracy by 2.",
  EVASION_UP2_EFFECT = "Raises the user's evasiveness by 2.",
  ATTACK_DOWN2_EFFECT = "Lowers the target's Attack by 2.",
  DEFENSE_DOWN2_EFFECT = "Lowers the target's Defense by 2.",
  SPEED_DOWN2_EFFECT = "Lowers the target's Speed by 2.",
  SPECIAL_DOWN2_EFFECT = "Lowers the target's Special by 2.",
  ACCURACY_DOWN2_EFFECT = "Lowers the target's accuracy by 2.",
  EVASION_DOWN2_EFFECT = "Lowers the target's evasiveness by 2.",

  BIDE_EFFECT = "Waits 2-3 turns; deals double the damage taken.",
  THRASH_PETAL_DANCE_EFFECT = "Lasts 3-4 turns. Confuses the user afterwards.",
  SWITCH_AND_TELEPORT_EFFECT = "No competitive use.",
  TWO_TO_FIVE_ATTACKS_EFFECT = "Hits 2-5 times in one turn.",
  FLINCH_SIDE_EFFECT1 = "10% chance to make the target flinch.",
  SLEEP_EFFECT = "Causes the target to fall asleep.",
  POISON_SIDE_EFFECT2 = "40% chance to poison the target.",
  BURN_SIDE_EFFECT2 = "30% chance to burn the target.",
  PARALYZE_SIDE_EFFECT2 = "30% chance to paralyze the target.",
  FLINCH_SIDE_EFFECT2 = "30% chance to make the target flinch.",
  OHKO_EFFECT = "Deals 65535 damage. Fails if target is faster.",
  CHARGE_EFFECT = "Charges turn 1. Hits turn 2.",
  TRAPPING_EFFECT = "Prevents the target from moving for 2-5 turns.",
  ATTACK_TWICE_EFFECT = "Hits 2 times.",
  JUMP_KICK_EFFECT = "User takes 1 HP of damage if it misses.",
  MIST_EFFECT = "While active, user is protected from stat drops.",
  FOCUS_ENERGY_EFFECT = "Quarters the user's chance for a critical hit.",
  RECOIL_EFFECT = "Has 1/4 recoil.",
  CONFUSION_EFFECT = "Confuses the target.",
  HEAL_EFFECT = "Heals the user by 50% of its max HP.",
  TRANSFORM_EFFECT = "Copies target's stats, moves, types, and species.",
  LIGHT_SCREEN_EFFECT = "While active, user's Special is 2x when damaged.",
  REFLECT_EFFECT = "While active, the user's Defense is doubled.",
  POISON_EFFECT = "Poisons the target.",
  PARALYZE_EFFECT = "Paralyzes the target.",
  ATTACK_DOWN_SIDE_EFFECT = "33% chance to lower the target's Attack by 1.",
  DEFENSE_DOWN_SIDE_EFFECT = "33% chance to lower the target's Defense by 1.",
  SPEED_DOWN_SIDE_EFFECT = "33% chance to lower the target's Speed by 1.",
  SPECIAL_DOWN_SIDE_EFFECT = "33% chance to lower the target's Special by 1.",
  CONFUSION_SIDE_EFFECT = "10% chance to confuse the target.",
  TWINEEDLE_EFFECT = "Hits 2 times. Last hit has 20% chance to poison.",
  SUBSTITUTE_EFFECT = "User takes 1/4 its max HP to put in a Substitute.",
  HYPER_BEAM_EFFECT = "Can't move next turn if target or sub is not KOed.",
  RAGE_EFFECT = "Lasts forever. Raises user's Attack by 1 when hit.",
  MIMIC_EFFECT = "Random move known by the target replaces this.",
  METRONOME_EFFECT = "Picks a random move.",
  LEECH_SEED_EFFECT = "1/16 of target's HP is restored to user every turn.",
  SPLASH_EFFECT = "No competitive use.",
  DISABLE_EFFECT = "For 0-7 turns, disables one of the target's moves.",
}

local function moveIdKey(move)
  local id = type(move) == "table" and (move.id or move.moveId or move.move) or move
  return tostring(id or ""):upper()
end

local function moveDescriptionText(battle, move)
  local def = moveDefinition(battle, move)
  local desc = def and (def.description or def.desc or def.shortDesc or def.effectDesc) or ""
  desc = tostring(desc or "")
  desc = desc:gsub("\r\n", "\n"):gsub("\r", "\n")
  desc = desc:gsub("%s*\n+%s*", " ")
  desc = desc:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  if desc == "" then
    local id = moveIdKey(move)
    desc = SMOGON_RB_MOVE_DESCRIPTIONS[id] or ""
    if desc == "" and def then
      local effect = tostring(def.effect or ""):upper()
      desc = SMOGON_RB_EFFECT_DESCRIPTIONS[effect] or ""
    end
    if desc == "" and def and def.highCrit then
      desc = "High critical hit ratio."
    end
  end

  local lowered = desc:lower()
  if lowered == "no additional effect." or lowered == "no additional effect" then
    return ""
  end
  return desc
end

local function movePowerValue(battle, move)
  local def = moveDefinition(battle, move)
  local value = def and tonumber(def.power) or nil
  if not value or value <= 0 then return nil end
  return math.floor(value + 0.5)
end

local function moveAccuracyValue(battle, move)
  local def = moveDefinition(battle, move)
  local value = def and tonumber(def.accuracy) or nil
  if not value or value <= 0 then return nil end
  if value > 100 and value <= 255 then
    value = (value / 255) * 100
  end
  return clamp(math.floor(value + 0.5), 1, 100)
end

local function moveCategoryKey(battle, move)
  local def = moveDefinition(battle, move)
  local raw = def and (def.category or def.damageClass or def.damageCategory
      or def.class or def.kind) or nil
  if type(raw) == "table" then raw = raw.name or raw.id end
  raw = tostring(raw or ""):upper():gsub("[%s_%-]+", "")
  if raw == "STATUS" or raw == "NONDAMAGING" or raw == "EFFECT"
      or raw == "UTILITY" or raw == "SUPPORT" then
    return "STATUS"
  end
  if raw == "PHYSICAL" or raw == "PHYS" then return "PHYSICAL" end
  if raw == "SPECIAL" or raw == "SPEC" or raw == "SP" then return "SPECIAL" end

  if not movePowerValue(battle, move) then return "STATUS" end
  return SPECIAL_MOVE_TYPES[moveTypeKey(battle, move)] and "SPECIAL" or "PHYSICAL"
end

-- The Gen-I ROM font intentionally lacks a percent glyph. Keep using that font
-- for the visual language of the HUD, but reserve one 8px cell for every `%` so
-- descriptions containing probabilities wrap exactly as they will be rendered.
local function inlineHudTextWidth(text)
  text = tostring(text or "")
  local total = 0
  local pos = 1
  while true do
    local at = text:find("%", pos, true)
    if not at then
      total = total + textWidth(text:sub(pos))
      break
    end
    total = total + textWidth(text:sub(pos, at - 1)) + 8
    pos = at + 1
  end
  return total
end

local function wrapHudText(text, maxWidth, extraScale, maxLines)
  text = tostring(text or "")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out = {}
  local scale = math.max(0.1, tonumber(extraScale) or 1)

  local function appendLine(line)
    if line ~= "" then
      out[#out + 1] = line
    end
    return maxLines and #out >= maxLines
  end

  for paragraph in text:gmatch("[^\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = (line == "") and word or (line .. " " .. word)
      if line == "" or inlineHudTextWidth(candidate) * scale <= maxWidth then
        if inlineHudTextWidth(candidate) * scale <= maxWidth then
          line = candidate
        else
          local piece = ""
          for ch in word:gmatch(".") do
            local joined = piece .. ch
            if piece ~= "" and inlineHudTextWidth(joined) * scale > maxWidth then
              if appendLine(piece) then return out end
              piece = ch
            else
              piece = joined
            end
          end
          line = piece
        end
      else
        if appendLine(line) then return out end
        line = word
      end
    end
    if appendLine(line) then return out end
  end

  return out
end

local function drawPercentGlyph(x, y, k, scale)
  scale = math.max(0.5, tonumber(scale) or 1)
  local px = math.max(0.75, scale)
  local dots = {
    {0, 0}, {1, 0}, {0, 1}, {1, 1},
    {5, 5}, {6, 5}, {5, 6}, {6, 6},
    {5, 0}, {4, 1}, {3, 2}, {3, 3}, {2, 4}, {1, 5}, {0, 6},
  }

  local function drawAt(ox, oy, r, gg, b)
    g.setColor(r, gg, b, 1)
    for _, pt in ipairs(dots) do
      g.rectangle("fill",
                  x + ox + pt[1] * px,
                  y + oy + pt[2] * px,
                  px, px)
    end
  end

  eachShadowOffset(k, scale, function(sx, sy)
    drawAt(sx, sy, 0, 0, 0)
  end)
  drawAt(0, 0, 1, 1, 1)
end


-- Draw normal Gen-I glyphs and splice the custom percent sign inline. This makes
-- `%` reusable in every Smogon description instead of special-casing accuracy.
local function drawShadowInlineText(text, x, y, k, extraScale)
  text = tostring(text or "")
  extraScale = math.max(0.25, tonumber(extraScale) or 1)
  local cursor = x
  local pos = 1

  while true do
    local at = text:find("%", pos, true)
    local chunk = at and text:sub(pos, at - 1) or text:sub(pos)
    if chunk ~= "" then
      drawShadowText(chunk, cursor, y, k, extraScale)
      cursor = cursor + textWidth(chunk) * extraScale
    end
    if not at then break end

    drawPercentGlyph(cursor + 0.5 * extraScale,
                     y + 0.5 * extraScale,
                     k,
                     0.72 * extraScale)
    cursor = cursor + 8 * extraScale
    pos = at + 1
  end
end

local function drawFightMoveHeader(layout, battle, move, k)
  local contentY = tonumber(layout.contentYOffset) or 0
  local divider = assetImage(FIGHT_DIVIDER_ASSET)
  if divider then
    drawShadowAsset(divider,
                    layout.dividerX or 55,
                    (layout.dividerY or 40) + contentY,
                    k,
                    FloatingHud.ASSET_SCALE * math.max(0.25, layout.dividerScale or 1))
  end

  local desc = moveDescriptionText(battle, move)
  local descScale = math.max(0.25, tonumber(layout.descScale) or 1)
  local descLines = wrapHudText(desc,
                                tonumber(layout.descWidth) or 184,
                                descScale,
                                tonumber(layout.descMaxLines) or 3)
  local lineStep = tonumber(layout.descLineStep) or (8 * descScale + 1)
  local bottomY = (tonumber(layout.descBottomY) or 23) + contentY
  local descX = tonumber(layout.descX) or 57
  local startY = bottomY - math.max(0, #descLines - 1) * lineStep
  for i = 1, #descLines do
    drawShadowInlineText(descLines[i], descX, startY + (i - 1) * lineStep,
                         k, descScale)
  end

  local statsScale = math.max(0.25, tonumber(layout.statsScale) or 1)
  local statsY = (tonumber(layout.statsY) or 35) + contentY
  local accuracy = moveAccuracyValue(battle, move)
  if accuracy then
    local accText = tostring(accuracy)
    local percentX = tonumber(layout.statsAccPercentX) or 184
    local gap = tonumber(layout.statsAccGap) or 1
    local accW = textWidth(accText) * statsScale
    -- Number grows LEFT toward the divider; the percent sign remains pinned.
    drawShadowText(accText,
                   percentX - gap * statsScale - accW,
                   statsY,
                   k,
                   statsScale)
    drawPercentGlyph(percentX,
                     statsY + 1 * statsScale,
                     k,
                     0.72 * statsScale)
  end

  local category = moveCategoryKey(battle, move)
  local categoryImage = assetImage(FIGHT_CATEGORY_ASSETS[category] or "")
  if categoryImage then
    drawShadowAsset(categoryImage,
                    tonumber(layout.statsCategoryX) or 194,
                    (tonumber(layout.statsCategoryY) or 31) + contentY,
                    k,
                    FloatingHud.ASSET_SCALE * math.max(0.25, layout.statsCategoryScale or 1))
  else
    local label = (category == "PHYSICAL" and "PHY")
               or (category == "SPECIAL" and "SPC")
               or "STS"
    drawShadowTextCentered(label,
                           (tonumber(layout.statsCategoryX) or 194) + 5,
                           statsY,
                           k,
                           0.8)
  end

  local power = movePowerValue(battle, move)
  if power then
    local powerText = tostring(power)
    -- Power grows RIGHT from a fixed left edge just after the category icon.
    drawShadowText(powerText,
                   tonumber(layout.statsPowerX) or 207,
                   statsY,
                   k,
                   statsScale)
  end
end

local function drawFightMoveRows(layout, battle, moves, count, selected, selector, k)
  local contentY = tonumber(layout.contentYOffset) or 0
  local listScale = math.max(0.5, tonumber(layout.listScale) or 1)
  local anchorX = tonumber(layout.listAnchorX) or 0
  local anchorY = tonumber(layout.listAnchorY) or 0
  local function sx(value)
    return anchorX + ((tonumber(value) or anchorX) - anchorX) * listScale
  end

  for i = 1, count do
    local move = moves[i]
    local y = (tonumber(layout.firstY) or 49) + contentY
            + (i - 1) * (tonumber(layout.rowStep) or 17) * listScale
    if move then
      if i == selected then
        drawShadowAsset(selector,
                        sx(layout.selectorX or 43),
                        y + (layout.selectorYOffset or 0) * listScale,
                        k,
                        FloatingHud.ASSET_SCALE * listScale)
      end

      local color = moveTypeColor(battle, move)
      g.setColor(color[1], color[2], color[3], color[4] or 1)
      g.rectangle("fill",
                  sx(layout.typeX or 55),
                  y + (layout.typeYOffset or 1) * listScale,
                  (layout.typeW or 4) * listScale,
                  (layout.typeH or 14) * listScale)

      drawShadowText(moveDisplayName(battle, move),
                     sx(layout.textX or 65), y, k, listScale)

      local curPP, maxPP = moveMaxPPValues(battle, move)
      local ppText = string.format("%d/%d", curPP, maxPP)
      local ppScale = math.max(0.5, tonumber(layout.ppScale) or listScale)
      local ppRight = sx(layout.ppRight or 211)
      drawShadowText(ppText,
                     ppRight - textWidth(ppText) * ppScale,
                     y + (layout.ppYOffset or 0) * listScale,
                     k,
                     ppScale)
    end
  end
end

local function renderFightCanvas(battle, k, logicalW, logicalH)
  local plate = assetImage(FIGHT_PLATE_ASSET)
  local selector = assetImage(COMMAND_SELECTOR_ASSET)
  if not (plate and selector and battle and battle.player) then return nil end

  local topPad = math.max(0, tonumber(FloatingHud.FIGHT.canvasTopPad) or 0)
  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("fight", logicalW, logicalH, topPad)
  if not canvas then return nil end

  local layout = FloatingHud.FIGHT
  local moves = battle.player.curMoves or {}
  local count = math.min(4, #moves)
  local selected = clamp(math.floor(tonumber(battle.moveIndex) or 1), 1,
                         math.max(1, count))
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
    g.translate(pad, pad + topPad)

    drawShadowAsset(plate, 0, 0, k, FloatingHud.ASSET_SCALE)
    if count > 0 then
      drawFightMoveHeader(layout, battle, moves[selected], k)
      drawFightMoveRows(layout, battle, moves, count, selected, selector, k)
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
    if count > 0 then
      drawFightMoveHeader(layout, battle, moves[selected], k)
      drawFightMoveRows(layout, battle, moves, count, selected, selector, k)
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
          local count = math.max(0, math.floor((tonumber(row.count) or 0) + 0.5))
          if count >= 2 then
            local quantityText = "x" .. tostring(count)
            local quantityScale = math.max(0.5,
              tonumber(layout.quantityScale) or 1)
            local quantityRight = tonumber(layout.quantityRight) or 216
            drawShadowText(quantityText,
                           quantityRight - textWidth(quantityText) * quantityScale,
                           y + (tonumber(layout.quantityYOffset) or 0),
                           k,
                           quantityScale)
          end
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

local function trainerTeamAssetState(battle, slot)
  local party = battle and battle.enemyParty
  local mon = party and party[slot] or nil
  if not mon then return "empty" end
  if slot == tonumber(battle.enemyIndex) and (tonumber(mon.hp) or 0) > 0 then
    return "active"
  end
  if (tonumber(mon.hp) or 0) > 0 then return "alive" end
  return "defeated"
end

local function renderTrainerTeamCanvas(battle, k)
  if not (battle and battle.kind == "trainer" and type(battle.enemyParty) == "table") then
    return nil
  end
  local cfg = FloatingHud.TRAINER_TEAM or {}
  local slots = math.max(1, math.min(6, math.floor(tonumber(cfg.slots) or 6)))
  local img = assetImage(TRAINER_BALL_ASSETS.alive)
  if not img then return nil end
  local iw, ih = img:getDimensions()
  local iconScale = FloatingHud.ASSET_SCALE * math.max(0.25, tonumber(cfg.scale) or 1)
  local iconW = iw * iconScale
  local iconH = ih * iconScale
  local gap = tonumber(cfg.gap) or 1.75
  local logicalW = slots * iconW + math.max(0, slots - 1) * gap
  local logicalH = iconH

  local canvas, cw, ch, pad, raster, logicalCW, logicalCH =
    panelCanvas("trainer_team", logicalW, logicalH)
  if not canvas then return nil end

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

    for i = 1, slots do
      local state = trainerTeamAssetState(battle, i)
      local ball = assetImage(TRAINER_BALL_ASSETS[state])
      if ball then
        local x = (i - 1) * (iconW + gap)
        drawShadowAsset(ball, x, 0, k, iconScale, true)
      end
    end

    g.pop()
  end)

  g.setShader(prevShader)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return canvas, logicalCW, logicalCH, logicalW, logicalH
end

local function drawTrainerTeamRow(battle, shot, enemyRect, k)
  if not (battle and battle.kind == "trainer" and enemyRect) then return false end
  local canvas, cw, ch, rowW, rowH = renderTrainerTeamCanvas(battle, k)
  if not canvas then return false end

  local cfg = FloatingHud.TRAINER_TEAM or {}
  local rowGap = tonumber(cfg.rowGap) or 1.5
  local yOffset = tonumber(cfg.yOffset) or 0
  local cx = enemyRect[1] + enemyRect[3] * 0.5
  local visualTop = enemyRect[2] + enemyRect[4] + (rowGap + yOffset) * k
  local cy = visualTop + rowH * k * 0.5

  drawPerspectiveCanvas(canvas, cx, cy, cw * k, ch * k,
                        cameraYawSignal(), hudRotation(), "enemy")
  return true
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
  if side == "enemy" then
    drawTrainerTeamRow(battle, shot, rect, k)
  end
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

  -- Voluntary battle switching is a submenu INSIDE PartyMenu, not a pushed
  -- ChoiceBox. PartyMenu's native renderer is hidden by this mod, so paint the
  -- live native submenu here while leaving its update/actions completely intact.
  if menu.submenu and menu.battle and menu.onSwitch then
    local subCanvas, subCW, subCH, subLogicalW, subLogicalH =
      renderPartyChoiceCanvas(menu, k)
    if subCanvas then
      local layout = FloatingHud.PARTY_CHOICE or FloatingHud.CHOICE
      local planeW = subLogicalW * k
      local planeH = subLogicalH * k

      -- Match the YES/NO language: a transparent floating list right-aligned to
      -- its parent panel. Prefer just above PKMN; clamp the whole plane on-screen
      -- so mobile/tall HUD scales cannot hide SWITCH again.
      local subCX = rect[1] + rect[3] - planeW * 0.5
                    + (layout.rightOffset or -2) * k
      local subCY = rect[2] - planeH * 0.5 - (layout.aboveGap or 2) * k
      local margin = FloatingHud.MARGIN or 4
      subCX = clamp(subCX, margin + planeW * 0.5,
                    math.max(margin + planeW * 0.5,
                             shot.pw - margin - planeW * 0.5))
      subCY = clamp(subCY, margin + planeH * 0.5,
                    math.max(margin + planeH * 0.5,
                             shot.ph - margin - planeH * 0.5))

      drawPerspectiveCanvas(subCanvas, subCX, subCY, subCW * k, subCH * k,
                            cameraYawSignal(), hudRotation(), "pkmn_choice")
    end
  end

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
  local topPad = math.max(0, tonumber(FloatingHud.FIGHT.canvasTopPad) or 0)
  local cy = rect[2] + rect[4] * 0.5 - topPad * k * 0.5
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

  -- Caught-Pokemon AskName uses a native TextBox with opts.choice. The stock
  -- renderer blanks the entire battle behind it; when we claim this semantic
  -- flow we keep the staged scene visible and project both the native text and
  -- its native ChoiceBox with the same message / YES-NO surfaces used elsewhere.
  if nicknameOverlayActiveForBattle(battle) then
    local text = battle._floatingBattleNicknameText
    local choice = battle._floatingBattleChoice
    if choice and top == choice and stateInStack(game, choice)
        and choice.__floatingBattleChoiceText == text then
      local drewMessage = drawMoveLearnMessagePanel(text, battle, shot)
      local drewChoice = drawChoicePanel(choice, battle, shot)
      if drewMessage or drewChoice then
        battle._floatingBattleNicknameSceneFrame = battle.frame
        battle._floatingBattleChoiceSceneFrame = battle.frame
      end
      return "nickname"
    end
    if text and top == text and stateInStack(game, text) then
      if drawMoveLearnMessagePanel(text, battle, shot) then
        battle._floatingBattleNicknameSceneFrame = battle.frame
      end
      return "nickname"
    end
    return "nickname"
  end

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
      or (owned == "nickname" and nicknameOverlayActiveForBattle(battle))
end

local function drawTextGlass(battle, shot)
  -- Legacy Dramatic Shape only. PotatoVoxel and Voxel Ascendant use their
  -- own panel/native-paper paths instead of this donor composite.
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
  if battle.safari or battle.demo then return false end
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
    -- have not replaced yet. During the opening party-ball window it is only a
    -- translucent copy of Gen1's empty text box: the authoritative introText is
    -- queued immediately afterwards and drawMessagePanel projects that text
    -- through our own plate. Do not leave the donor rectangle underneath it.
    if includeTextGlass and not bottomKind and not battle.introBalls then
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

  -- The engine's SE_WAVY_SCREEN only bends its now-mostly-empty 160x144 BG
  -- canvas. Once our floating surfaces are safely on the staged scene, bend
  -- that scene too so Psychic's second half remains visible in voxel battles.
  local waveOk, waveErr = pcall(applySceneWave, battle, shot)
  if not waveOk and not sceneWaveWarned then
    sceneWaveWarned = true
    mod.log:warn("floating battle scene wave failed: %s", tostring(waveErr))
  end

  battle._floatingBattleBottomDrawn = bottomKind
  return statusDrawn, bottomKind ~= nil
end

-- The temporary party-ball rows are fields inside BattleState:drawHUDs, not a
-- separate visibility surface. Older builds hid them by running the whole
-- method under an empty scissor. That was too broad: host or engine additions
-- to drawHUDs (including animation-time presentation) disappeared with them.
-- Mask only the two ball-row inputs and let the status visibility hook below
-- continue to suppress the ordinary native HP/name blocks.
local function drawHUDsWithoutNativeBallRows(draw, battle, ...)
  local introBalls = rawget(battle, "introBalls")
  local showEnemyBalls = rawget(battle, "showEnemyBalls")
  battle.introBalls = nil
  battle.showEnemyBalls = nil
  local ok, a, b, c = pcall(draw, battle, ...)
  battle.introBalls = introBalls
  battle.showEnemyBalls = showEnemyBalls
  if not ok then error(a, 0) end
  return a, b, c
end

if isAscendantHost and not hostFloatingAvailable then
  -- Native fallback by design. Do not install any pixel suppression or menu
  -- ownership on iOS/unknown Ascendant platforms; all helpers above also report
  -- their floating layers disabled, so the rest of the file stays transparent.
  hostMode = "voxel_ascendant_ios_fallback"

elseif isAscendantHost and type(OverworldBattle.drawHudPanels) == "function" then
  -- Voxel Ascendant's live path mirrors the modern panel-host seam: BattleState
  -- stores voxelAscendantShot, binds the world override, then calls drawHudPanels
  -- before the engine's own battle UI. Paint into that shot.canvas here.
  hostMode = "voxel_ascendant"

  local PANEL_KEY = "_floatingBattleHudBaseDrawHudPanels"
  if not OverworldBattle[PANEL_KEY] then
    OverworldBattle[PANEL_KEY] = OverworldBattle.drawHudPanels
  end
  local baseDrawHudPanels = OverworldBattle[PANEL_KEY]

  function FloatingHud.drawPanelHostHudPanels(battle)
    if not battle then return baseDrawHudPanels(battle) end
    battle._floatingBattleHudPanelDrawn = false
    local shot = battleShot(battle)
    local statusDrawn, bottomDrawn = drawFloatingSceneUI(battle, shot, false)
    if statusDrawn then
      battle._floatingBattleHudPanelDrawn = true
    end
    -- Before introText becomes the current queue item there is intentionally no
    -- custom message to paint. Still claim the panel host for that short
    -- introBalls window so its empty translucent native rectangle cannot leak.
    if statusDrawn or bottomDrawn
        or (floatingCommandsEnabled() and battle.introBalls
            and supportedFloatingLayout(battle)) then
      return
    end
    return baseDrawHudPanels(battle)
  end

  OverworldBattle.drawHudPanels = FloatingHud.drawPanelHostHudPanels

  local DRAW_KEY = "_floatingBattleHudBaseDrawHUDs"
  if not BattleState[DRAW_KEY] then BattleState[DRAW_KEY] = BattleState.drawHUDs end
  local baseDrawHUDs = BattleState[DRAW_KEY]
  if type(baseDrawHUDs) == "function" then
    function BattleState:drawHUDs(...)
      local owns = floatingStatusHudEnabled()
                   and battleShot(self)
                   and plateImage("enemy") and plateImage("player")
      if owns then
        return drawHUDsWithoutNativeBallRows(baseDrawHUDs, self, ...)
      end
      return baseDrawHUDs(self, ...)
    end
  end

  local statusHookInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("battle.status_hud_visible", function(next, state)
      if floatingStatusHudEnabled() and state and battleShot(state)
          and state._floatingBattleHudPanelDrawn then
        return false
      end
      return next(state)
    end, 12000)
    statusHookInstalled = true
  end

  if not statusHookInstalled then
    local STATUS_KEY = "_floatingBattleHudBaseStatusHUDVisible"
    if not BattleState[STATUS_KEY] then
      BattleState[STATUS_KEY] = BattleState.statusHUDVisible
    end
    local baseStatusHUDVisible = BattleState[STATUS_KEY]
    if type(baseStatusHUDVisible) == "function" then
      function BattleState:statusHUDVisible(...)
        if floatingStatusHudEnabled() and battleShot(self)
            and self._floatingBattleHudPanelDrawn then
          return false
        end
        return baseStatusHUDVisible(self, ...)
      end
    end
  end

elseif type(OverworldBattle.snapHUDs) == "function" then
  -- Dramatic Shape 1.6.x path: it asks snapHUDs to composite HUD furniture into
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
    battle._floatingBattleHudPanelDrawn = false

    if not wantStatus and not wantCommands then
      return baseSnapHUDs(battle, shot)
    end

    local statusDrawn, bottomDrawn = drawFloatingSceneUI(battle, shot, true)
    if statusDrawn then
      battle._floatingBattleHudPanelDrawn = true
    end

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

    -- introBalls begins before the trainer-challenge message becomes current.
    -- Claim that silent lead-in too; otherwise baseSnapHUDs reconstructs the
    -- empty frosted text rectangle we deliberately withheld above.
    if statusDrawn or bottomDrawn
        or (wantCommands and battle.introBalls
            and supportedFloatingLayout(battle)) then
      return true
    end
    return baseSnapHUDs(battle, shot)
  end

  OverworldBattle.snapHUDs = FloatingHud.snapHUDs

  -- Gen1Recomp draws the temporary trainer/player Poké Ball rows inside
  -- BattleState:drawHUDs, independently of the lower-UI visibility predicate.
  -- Keep the method alive for renderer lifecycle compatibility, mask only those
  -- row inputs, and suppress its ordinary status blocks through the semantic
  -- visibility seam below. This is deliberately BattleState-scoped: overworld
  -- TextBox rendering never passes through it.
  local DRAW_KEY = "_floatingBattleHudBaseDrawHUDs"
  if not BattleState[DRAW_KEY] then BattleState[DRAW_KEY] = BattleState.drawHUDs end
  local baseDrawHUDs = BattleState[DRAW_KEY]
  if type(baseDrawHUDs) == "function" then
    function BattleState:drawHUDs(...)
      local owns = floatingStatusHudEnabled()
                   and battleShot(self)
                   and plateImage("enemy") and plateImage("player")
                   and not self.safari and not self.demo
      if owns then
        return drawHUDsWithoutNativeBallRows(baseDrawHUDs, self, ...)
      end
      return baseDrawHUDs(self, ...)
    end
  end

  local statusHookInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("battle.status_hud_visible", function(next, state)
      if floatingStatusHudEnabled() and state and battleShot(state)
          and state._floatingBattleHudPanelDrawn then
        return false
      end
      return next(state)
    end, 12000)
    statusHookInstalled = true
  end

  if not statusHookInstalled then
    local STATUS_KEY = "_floatingBattleHudBaseStatusHUDVisible"
    if not BattleState[STATUS_KEY] then
      BattleState[STATUS_KEY] = BattleState.statusHUDVisible
    end
    local baseStatusHUDVisible = BattleState[STATUS_KEY]
    if type(baseStatusHUDVisible) == "function" then
      function BattleState:statusHUDVisible(...)
        if floatingStatusHudEnabled() and battleShot(self)
            and self._floatingBattleHudPanelDrawn then
          return false
        end
        return baseStatusHUDVisible(self, ...)
      end
    end
  end

elseif type(OverworldBattle.drawHudPanels) == "function" then
  -- PotatoVoxel path. Like Ascendant, BattleState calls drawHudPanels before the
  -- native battle UI; the only host difference is the BattleState shot field.
  hostMode = "potato_voxel"

  local PANEL_KEY = "_floatingBattleHudBaseDrawHudPanels"
  if not OverworldBattle[PANEL_KEY] then
    OverworldBattle[PANEL_KEY] = OverworldBattle.drawHudPanels
  end
  local baseDrawHudPanels = OverworldBattle[PANEL_KEY]

  function FloatingHud.drawPanelHostHudPanels(battle)
    if not battle then return baseDrawHudPanels(battle) end
    battle._floatingBattleHudPanelDrawn = false
    local shot = battleShot(battle)
    local statusDrawn, bottomDrawn = drawFloatingSceneUI(battle, shot, false)
    if statusDrawn then
      battle._floatingBattleHudPanelDrawn = true
    end
    if statusDrawn or bottomDrawn
        or (floatingCommandsEnabled() and battle.introBalls
            and supportedFloatingLayout(battle)) then
      return
    end
    return baseDrawHudPanels(battle)
  end

  OverworldBattle.drawHudPanels = FloatingHud.drawPanelHostHudPanels

  local DRAW_KEY = "_floatingBattleHudBaseDrawHUDs"
  if not BattleState[DRAW_KEY] then BattleState[DRAW_KEY] = BattleState.drawHUDs end
  local baseDrawHUDs = BattleState[DRAW_KEY]
  if type(baseDrawHUDs) == "function" then
    function BattleState:drawHUDs(...)
      local owns = floatingStatusHudEnabled()
                   and battleShot(self)
                   and plateImage("enemy") and plateImage("player")
      if owns then
        return drawHUDsWithoutNativeBallRows(baseDrawHUDs, self, ...)
      end
      return baseDrawHUDs(self, ...)
    end
  end

  local statusHookInstalled = false
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("battle.status_hud_visible", function(next, state)
      if floatingStatusHudEnabled() and state and battleShot(state)
          and state._floatingBattleHudPanelDrawn then
        return false
      end
      return next(state)
    end, 12000)
    statusHookInstalled = true
  end

  if not statusHookInstalled then
    local STATUS_KEY = "_floatingBattleHudBaseStatusHUDVisible"
    if not BattleState[STATUS_KEY] then
      BattleState[STATUS_KEY] = BattleState.statusHUDVisible
    end
    local baseStatusHUDVisible = BattleState[STATUS_KEY]
    if type(baseStatusHUDVisible) == "function" then
      function BattleState:statusHUDVisible(...)
        if floatingStatusHudEnabled() and battleShot(self)
            and self._floatingBattleHudPanelDrawn then
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
      self._floatingBattleItemTargetSource = nil
      self._floatingBattleItemTargetId = nil
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
      battle._floatingBattleItemTargetSource = nil
      battle._floatingBattleItemTargetId = nil
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
        local shot = battleShot(battle)
        if shot and drawPartyPanel(self, battle, shot) then return end
        if type(baseDraw) == "function" then return baseDraw(self, ...) end
      end

      menu.drawWidescreen = function(self, ...)
        self.isOpaque = false
        battle._floatingBattlePartyMenu = self
        local shot = battleShot(battle)
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
          local shot = battleShot(battle)
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
          local shot = battleShot(battle)
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
            local shot = battleShot(battle)
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
            if battle._floatingBattleItemTargetSource == self then
              battle._floatingBattleItemTargetPending = nil
              battle._floatingBattleItemTargetSource = nil
              battle._floatingBattleItemTargetId = nil
            end
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
            if battle._floatingBattleItemTargetSource == self then
              battle._floatingBattleItemTargetPending = nil
              battle._floatingBattleItemTargetSource = nil
              battle._floatingBattleItemTargetId = nil
            end
            return
          end

          if input:wasPressed("a") then
            local row = selectedBattleItemRow(self)
            if not row then return end

            -- Dispatch the visible Floating HUD row through the concrete Bag
            -- state's FINAL onChoose callback instead of forcing ListMenu:update
            -- to rediscover A on a native flat index. This is important for Useful
            -- Bag: its battle screen projects only one pocket into self.items, while
            -- our floating battle list intentionally aggregates every battle-usable
            -- pocket. A POTION can therefore be visible here while absent from the
            -- currently projected Useful Bag rows. Useful Bag's wrapper accepts the
            -- row object and then delegates to vanilla BagMenu, whose use flow keys
            -- off item.value; no pocket mutation or bypass is required.
            local nativeIndex = nativeBattleItemIndex(self, row.value)
            local actionRow = nativeIndex and self.items[nativeIndex] or {
              value = row.value,
              label = row.label,
              right = "x" .. tostring(row.count or 0),
            }

            -- Keep the native cursor coherent when the selected item does happen to
            -- exist in the active native/pocket projection. When it does not, leave
            -- Useful Bag's pocket cursor untouched: onChoose only needs actionRow.
            if nativeIndex then
              self.index = nativeIndex
              local nativeRows = tonumber(self.rows) or 7
              self.scroll = tonumber(self.scroll) or 0
              if self.index - self.scroll > nativeRows then
                self.scroll = self.index - nativeRows
              elseif self.index - self.scroll < 1 then
                self.scroll = self.index - 1
              end
            end

            local def = self.game and self.game.data and self.game.data.items
                        and self.game.data.items[row.value] or nil
            local expectsPartyTarget = false
            if ItemEffects and type(ItemEffects.needsTarget) == "function" then
              local okTarget, value = pcall(ItemEffects.needsTarget,
                                            row.value, def,
                                            self.game and self.game.data or nil)
              expectsPartyTarget = okTarget and value and true or false
            else
              expectsPartyTarget = row.category == "HEALING"
            end
            if ItemEffects and type(ItemEffects.isBall) == "function" then
              local okBall, isBall = pcall(ItemEffects.isBall, row.value)
              if okBall and isBall then expectsPartyTarget = false end
            end

            if expectsPartyTarget then
              battle._floatingBattleItemTargetPending = true
              battle._floatingBattleItemTargetSource = self
              battle._floatingBattleItemTargetId = row.value
            else
              battle._floatingBattleItemTargetPending = nil
              battle._floatingBattleItemTargetSource = nil
              battle._floatingBattleItemTargetId = nil
            end

            local onChoose = self.onChoose
            if type(onChoose) == "function" then
              pcall(function()
                require("src.core.Sound").play(self.game.data, "Press_AB")
              end)
              onChoose(actionRow, self)
            end

            -- A target picker is normally pushed synchronously, but keep the latch
            -- alive for target items until PartyMenu actually claims it. This also
            -- covers screen-registry wrappers that defer the push by a frame.
            if not expectsPartyTarget then
              battle._floatingBattleItemTargetPending = nil
              battle._floatingBattleItemTargetSource = nil
              battle._floatingBattleItemTargetId = nil
            end

            if stateInStack(self.game, self) then
              refreshBattleItemView(self, battle, row.value)
            end
            return
          end

          if input:wasPressed("b") then
            if battle._floatingBattleItemTargetSource == self then
              battle._floatingBattleItemTargetPending = nil
              battle._floatingBattleItemTargetSource = nil
              battle._floatingBattleItemTargetId = nil
            end
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
        local shot = battleShot(battle)
        if shot and drawItemPanel(self, battle, shot) then return end
        if type(nativeDraw) == "function" then return nativeDraw(self, ...) end
      end
      menu.drawWidescreen = function(self, ...)
        self.isOpaque = false
        battle._floatingBattleItemMenu = self
        local shot = battleShot(battle)
        if shot and drawItemPanel(self, battle, shot) then return end
        if type(nativeWide) == "function" then return nativeWide(self, ...) end
      end
      return menu
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
            local shot = battleShot(battle)
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
        local shot = battleShot(battle)
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
-- Caught-Pokemon nickname prompt presentation
-- ---------------------------------------------------------------------------
-- Gen1Recomp's AskName path intentionally sets blankForAskName=true before
-- returning a TextBox, which makes BattleState:drawClassic paint a full white
-- 160x144 field. For staged voxel battles that destroys the very scene our
-- floating prompt is anchored to. Keep every native TextBox/ChoiceBox callback
-- and NamingScreen handoff intact, but cancel only that presentation blank and
-- tag the concrete TextBox for our existing message renderer.
do
  local ASK_NICK_KEY = "_floatingBattleHudBaseAskNicknameUI"
  if type(BattleState.askNicknameUI) == "function" then
    if not BattleState[ASK_NICK_KEY] then
      BattleState[ASK_NICK_KEY] = BattleState.askNicknameUI
    end
    local baseAskNicknameUI = BattleState[ASK_NICK_KEY]

    function BattleState:askNicknameUI(...)
      local box = baseAskNicknameUI(self, ...)
      if not floatingCommandsEnabled() then return box end
      if not (box and isTextBoxState(box) and battleShot(self)) then return box end
      if self.safari or self.demo then return box end

      -- Presentation only: the original choice callback still clears this flag
      -- and still pushes NamingScreen on YES. Clearing it now merely prevents
      -- drawClassic / compatible hosts from replacing the staged scene with white.
      self.blankForAskName = false
      box.isOpaque = false
      box.__floatingBattleNicknameText = self
      self._floatingBattleNicknameText = box
      return box
    end
  end

  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("screen.render_visible", function(next, state)
      local visible = next(state)
      if not floatingCommandsEnabled() then return visible end
      local game = state and state.game
      local battle = game and battleStateInStack(game) or nil
      if state and battle and state.__floatingBattleNicknameText == battle then
        state.isOpaque = false
        battle._floatingBattleNicknameText = state
        return false
      end
      return visible
    end, 20018)

    mod.hooks:wrap("render.hud", function(next, game, viewport)
      local out = next(game, viewport)
      if not floatingCommandsEnabled() then return out end
      local battle = battleStateInStack(game)
      if not battle then return out end
      local text = battle._floatingBattleNicknameText
      if not text then return out end
      if not stateInStack(game, text) then
        battle._floatingBattleNicknameText = nil
        return out
      end
      local top = topState(game)
      if top ~= text then return out end
      local shot = battleShot(battle)
      if shot and battle._floatingBattleNicknameSceneFrame ~= battle.frame then
        local ok, err = pcall(drawMoveLearnMessagePanel, text, battle, shot)
        if not ok then
          mod.log:warn("floating nickname message failed: %s", tostring(err))
        end
      end
      return out
    end, 15175)
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
      -- sourceText is also used by the caught-Pokemon nickname prompt;
      -- any tagged source keeps the native callback/input while replacing pixels.
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
        local nicknameText = nicknameTextBoxInStack(game)
        local choice = baseNew(game, onChoose, opts, ...)
        if not floatingCommandsEnabled() then return choice end
        -- Move-learning and caught-nickname TextBoxes each own the message that
        -- must remain visible under their native ChoiceBox.
        if choice and battle and sourceText
            and sourceText.__floatingBattleMoveLearnText == battle then
          return claimBattleChoice(choice, battle, sourceText)
        end
        if choice and battle and nicknameText
            and nicknameText.__floatingBattleNicknameText == battle then
          return claimBattleChoice(choice, battle, nicknameText)
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
          or (game and nicknameTextBoxInStack(game) or nil)
        local isLearnChoice = state and battle and sourceText
          and sourceText.__floatingBattleMoveLearnText == battle
          and getmetatable(state) == ChoiceBox
        local isNicknameChoice = state and battle and sourceText
          and sourceText.__floatingBattleNicknameText == battle
          and getmetatable(state) == ChoiceBox
        local isBattleChoice = state and battle and battle.phase == "messages"
          and (state.__floatingBattleChoice == battle
               or getmetatable(state) == ChoiceBox)
        if isLearnChoice or isNicknameChoice or isBattleChoice then
          claimBattleChoice(state, battle,
                            (isLearnChoice or isNicknameChoice) and sourceText or nil)
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
            local shot = battleShot(battle)
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
      and battleShot(self)
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
        and state and battleShot(state)
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
          and battleShot(self) and not self.safari and not self.demo then
        return false
      end
      return baseBottomUIVisible(self, ...)
    end
  end
end

mod.exports.version = "0.7.18"
mod.exports.floatingHud = FloatingHud
mod.exports.hostMode = hostMode
mod.log:info("Floating Battle HUD 0.7.18 installed over %s %s (%s)",
             tostring(hostId or "voxel host"), tostring(ds.version), tostring(hostMode))
