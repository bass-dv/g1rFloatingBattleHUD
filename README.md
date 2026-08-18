Floating Battle HUD v0.5.2

Camera perspective and Z roll are now driven only by Dramatic Shape camera yaw/orbit. Zoom affects HUD size only.

# Floating Battle HUD v0.5.1

Fixes the v0.5 perspective seam by subdividing the projected HUD into a 12x6 mesh grid.
This prevents LOVE's two-triangle affine interpolation from making the two halves of a strongly skewed card look like they have different perspective.

The existing Z roll is kept. Set `FloatingHud.MAX_ROTATION_DEG = 0` if you want to isolate the Y-perspective effect while testing.

Useful controls:
- `PERSPECTIVE_DEPTH`: strength of near/far edge height difference.
- `PERSPECTIVE_WIDTH_SQUEEZE`: horizontal compression at maximum yaw.
- `PERSPECTIVE_GRID_X/Y`: mesh subdivision quality; 12x6 is the default.
- `MAX_ROTATION_DEG`: existing small Z-roll.


## v0.5.5 — PotatoVoxel compatibility

- Supports the legacy Dramatic Shape `snapHUDs` path.
- Supports PotatoVoxel 1.6.1, which removed `snapHUDs`/`BattleHud` and instead calls `OverworldBattle.drawHudPanels` before the native battle UI.
- On PotatoVoxel the mod paints the floating cards into the live world canvas at that seam, then suppresses only the native Pokemon HUD blocks for that frame.
- Native text/menu paper remains PotatoVoxel's own presentation.
- Runtime host probing accepts DRAMATIC_SHAPE, POTATO_VOXEL, POTATO_VOXEL_MOD, and potato_voxel ids.
