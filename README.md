## v0.7.10 — floating caught-Pokémon nickname prompt

- Replaces the previous v0.7.9 native AskName handoff: staged battles no longer reveal Gen1Recomp's intentional full-white `blankForAskName` field after a catch.
- The native caught-Pokémon TextBox remains the source of truth for text, paging, typewriter timing and translated strings, but its pixels are hidden and projected through Floating Battle HUD's existing battle-message plate.
- When that TextBox pushes its native ChoiceBox, the same floating YES / NO presentation is used; the engine's original callbacks still decide whether to open NamingScreen.
- Only the visual blank is cancelled. Catch storage, Pokédex flow, nickname callbacks and NamingScreen remain engine-owned.
- Useful Bag compatibility and Voxel Ascendant support from v0.7.8/v0.7.7 are unchanged.

## v0.7.9 — native caught-Pokémon nickname handoff

- Floating Battle HUD now fully releases the battle bottom UI when Gen1Recomp enters its native `blankForAskName` state after a successful catch.
- The white AskName screen, its TextBox, YES/NO prompt, and subsequent NamingScreen are left completely native instead of mixing Floating HUD message/choice pixels with the intentionally blank Gen I field.
- The handoff is keyed to the engine's semantic `blankForAskName` flag rather than catch text, so the normal caught message and Pokédex flow can still use the floating presentation until AskName actually begins.
- The v0.7.8 Useful Bag compatibility and v0.7.7 Voxel Ascendant support remain unchanged.

## v0.7.8 — Useful Bag battle-item compatibility

- Restored Useful Bag compatibility on top of the v0.7.7 Voxel Ascendant baseline.
- Unlike the older v0.7.5 workaround, Useful Bag is no longer bypassed for battle screens.
- Floating ITEM now sends the selected visible item directly through the concrete Bag state's final `onChoose` callback. This allows a POTION/medicine item to work even when Useful Bag currently projects another pocket into its native `items` list.
- Party-target items keep the target-selection latch alive until the native `PartyMenu` is actually created, preserving the floating PKMN target picker on delayed/mobile screen pushes.
- Poké Balls and non-target battle items clear the latch immediately and continue through their native Bag callbacks.
- Dramatic Shape, PotatoVoxel and Voxel Ascendant remain on the v0.7.7 host integration paths.

## v0.7.7 — experimental Voxel Ascendant support

- Added Voxel Ascendant as a third supported voxel host alongside Dramatic Shape and PotatoVoxel.
- Added a shared battle-shot adapter so every floating surface can consume either `dramaticShapeShot`, `voxelAscendantShot`, or the host's public `OverworldBattle.shot()` result.
- Voxel Ascendant is detected explicitly before `snapHUDs`, preventing its compatibility `snapHUDs` export from being mistaken for the Dramatic Shape rendering path.
- On Ascendant, the HUD uses the live `drawHudPanels` / `shot.canvas` seam, preserving the existing camera-relative scale, yaw/pitch perspective, PKMN/ITEM/YES-NO/move-learning flows, and the v0.7.6 SWITCH / STATS / CANCEL fix.
- MAP and DISCS battle stages are supported through the same projected player/enemy anchors.
- Voxel Ascendant on iOS intentionally falls back to the complete native battle UI for now, matching Ascendant's own cross-canvas safety policy.

## v0.7.6

- Fixed the invisible voluntary PKMN action submenu. Selecting a Pokémon during battle now renders the native **SWITCH / STATS / CANCEL** choices as a floating three-row selector.
- The submenu keeps Gen1Recomp PartyMenu as the sole input/action authority; Floating Battle HUD only replaces its hidden pixels.
- The selected action grows and the unselected actions shrink, matching the existing floating YES / NO visual language.
- The submenu is drawn into the staged battle canvas with the PKMN panel, so it follows the same mobile-safe render path and HUD scale.

## v0.7.3

- Added a platform-independent **HUD SCALE** option: `x0.8`, `x1` (default), `x1.2`, `x1.4`, `x1.6`, `x1.8`, `x2`.
- Replaced the old hard-coded mobile scale multiplier with the new global HUD scale setting.
- Move-learning TextBox, YES/NO, and SELECT/FIGHT-replacement surfaces now render into the staged battle canvas, matching the mobile-safe PKMN/ITEM/FIGHT path.
- Mandatory Pokémon replacement after a faint is claimed at PartyMenu construction time, so mobile no longer depends on the late `render.hud` fallback.
- Desktop `render.hud` paths remain as compatibility fallbacks and skip duplicate drawing when the scene-canvas pass already rendered the foreground.

## v0.7.2

- Added automatic Android/iOS detection with `FloatingHud.MOBILE_SCALE = 1.20` for the complete floating HUD.
- PKMN and ITEM now render into the same staged battle canvas path as FIGHT whenever possible, addressing their mobile-only invisible state.
- The previous `render.hud` PKMN/ITEM path remains as a fallback and skips duplicate drawing when the battle-canvas pass already rendered the panel.

## v0.6.7



## v0.6.9

- Rebuilt directly from the user's stable, hand-tuned v0.6.7 main.lua.
- Forced replacement after the active Pokémon faints now reuses the floating PKMN picker.
- Battle PartyMenu detection is intentionally narrow: the engine's `opts.battle` marker, plus a fainted-active-Pokémon fallback for UI mods that drop constructor options.
- Added `FloatingHud.SHADOW_GROW_PX` (default 1) to thicken the existing hard shadow without moving it farther from the white HUD. Set 0 for the old single-copy shadow or 2 for a chunkier outline.

- Battle item target selection now reuses the floating **PKMN** panel instead of reopening the native fullscreen Party screen. Native PartyMenu input/callbacks remain authoritative.
- Adds a floating horizontal **YES / NO** battle-choice presentation above the battle message plate. The selected answer grows while the unselected answer shrinks; both Left/Right and Up/Down are accepted.
- YES responses that open the trainer-switch Party picker are handed directly to the same floating PKMN presentation.
- Adds the missing **PSYCHIC** move accent colour `#FF7BCA`.

### YES / NO tuning

```lua
FloatingHud.CHOICE = {
  logicalW = 48.0,
  logicalH = 18.0,
  rightOffset = -2.0,
  aboveGap = 2.0,
  yesX = 1.0,
  noX = 28.0,
  y = 3.0,
  selectedScale = 1.28,
  idleScale = 0.82,
}
```

The choice plane uses the exact battle-message camera transform, so existing message perspective tuning also affects YES / NO.

# Floating Battle HUD v0.6.5

Companion battle UI for Dramatic Shape / Dramatic Voxel and PotatoVoxel staged Gen1Recomp battles.

## v0.6.5

- Adds the first floating **ITEM** battle menu using `assets/hud/item_command_plate.png`.
- Shows up to **7 battle-usable items** in a single vertical list.
- Uses the same command selector as the main battle menu.
- Reuses the battle-message continuation arrow as scroll furniture: an inverted arrow at the upper-right when items exist above, and a normal arrow at the lower-right when items exist below.
- The presentation list is filtered to battle-useful categories: Poké Balls (wild battles), healing/status/PP recovery, and battle boosts / escape battle items.
- Presentation order is `BALLS -> HEALING -> BATTLE`, while preserving the player's actual Bag order inside each category.
- The native Bag/ListMenu remains authoritative. The filtered list never replaces the engine's flat item array; confirming an item maps the visible selection back to the native item index and then delegates item use, target selection, consumption, capture logic, and callbacks to Gen1Recomp.
- Native ITEM fullscreen pixels are suppressed through `screen.render_visible`; the floating plate is rendered later in `render.hud`, matching the proven PKMN ownership strategy.

### ITEM tuning

```lua
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
```

## Moving the battle-message plate

The message plate already has independent screen-position offsets:

```lua
FloatingHud.MESSAGE.xOffset = 10.0  -- positive = RIGHT, negative = LEFT
FloatingHud.MESSAGE.yOffset = 35.0  -- positive = DOWN,  negative = UP
```

For example, to move it a little right and down:

```lua
FloatingHud.MESSAGE.xOffset = 6.0
FloatingHud.MESSAGE.yOffset = 31.0
```

These offsets are applied after the midpoint between the projected player/enemy Pokémon is calculated, so they do not change the camera/perspective response.

## Existing battle surfaces

- Floating player/enemy status nameplates.
- Perspective battle-message plate with two visible lines and continuation cursor.
- Vertical FIGHT / PKMN / ITEM / RUN command menu.
- Floating move-selection panel with type-colour glyphs.
- Floating PKMN party list with native PartyMenu input and callbacks preserved.

All authored HUD furniture follows the x8 convention: one logical HUD pixel equals eight source pixels. Optional PKMN icon sheets remain native 16x32 two-frame pixel art.


## v0.7.0 — in-battle move learning

Level-up move learning now owns its own floating foreground instead of layering the
native MoveLearnMenu/TextBox over the battle message:

- The normal battle message is withheld while the move-learning flow is active.
- The engine's MoveLearnMenu, TextBox and ChoiceBox remain authoritative for input,
  paging, callbacks, HM rejection and the final learned/did-not-learn result.
- Move-learning prompts reuse the battle-message plate and the floating YES/NO.
- Choosing YES opens a dedicated SELECT-style move replacement panel. For now it
  falls back to `fight_command_plate.png`. If `assets/hud/select_command_plate.png`
  is added later, it is picked up automatically.
- The replacement picker displays only the four real moves; B keeps the native
  abandon-learning path, so the invisible native CANCEL row is not needed.

SELECT geometry can be tuned independently through `FloatingHud.LEARN`; it starts as
an exact clone of the current FIGHT geometry.


## Compatibility toggles

- **FLOATING HP HUD** — disables/enables the floating Pokémon status/nameplate layer independently.
- **FLOATING COMMANDS** — disables/enables the complete floating battle-flow UI (messages, commands, FIGHT/PKMN/ITEM, YES/NO and move-learning SELECT) so another command UI mod can own that surface.
