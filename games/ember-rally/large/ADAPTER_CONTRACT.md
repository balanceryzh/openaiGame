# Full-map HD-2D adapter contract

This is a separate scene: `res://large/main.tscn`. The earlier `res://main.tscn` and its scene logic remain independently runnable. Only a caller or the project owner chooses the default scene.

## Authoritative simulation

- `main.logic` is the `large/battle_logic.gd` Node2D adapter over the copied full-map core
- The only simulation loop is `logic._process`; `main._process` runs at priority 20 and updates camera and render adapters
- Core positions are pixels; every rendered X/Z position divides them by 50 exactly once
- The map remains 10,000 × 5,500 pixels, or 200 × 110 world units
- No render adapter writes actor positions, health, damage, cooldowns, rescue state, spawning or victory state
- Camera is orthographic, size 29, with fixed no-yaw `(0, 34, 18)` follow offset
- `render_view_rect2d` intersects all four real camera rays with the ground and sends that pixel-space AABB to the corpse field. Visible source replenishment therefore uses the actual 3D camera footprint
- `project_point` / `unproject_point` connect the concise inherited HUD and actual Camera3D projection

## Visual identity and memory limits

- Living actors and death poses are keyed by the core's stable `view_id`, never their array index
- Only actors in the view plus 150-pixel margin have active Sprite3D views. The reusable spare pool is capped at 24
- The HD instance configures 6–10 corpse sources per region, versus 18–30 in the original flat game, so the larger 3D artwork does not conceal paths. Spawn frequency, active-enemy caps, pre-existence and consumption rules are unchanged.
- Static corpses are queried through the core region index and grouped into atlas-exact MultiMeshes. No Sprite3D node is allocated for each static source
- Human-origin corpse path, skeleton/zombie identity and helmet variant are selected in the core before the source appears
- Resting corpses and rise frame zero share a 0.8 neutral tint; rising actors smoothly return to ordinary lighting as they stand. A single soft contact-shadow MultiMesh grounds the resting sources
- The static source and first human rise frame are identical in texture rectangle, scale and authored root
- The large-specific renderer extends the same guarantee to demon/caster corpses by using their own first rising-atlas frame
- Fallen helmets are separate authored props placed at the original source coordinates, indexed by region. They are never attached to a walking actor
- Sword/axe debris is sparse pre-existing decoration selected by source position. It has no collision or pickup logic and includes consumed original source coordinates on region reload

## Combat presentation

- Existing source atlases and per-pose root anchors are reused. Boss's source-pixel scale makes its standing height approximately 1.5 times the hero; collision remains the unchanged original core radius
- Hero and shield infantry sword effects sample the authored eight-frame atlas using the same attack age as the original 0.12-second hit event
- Friendly arrows and hostile fireballs use actual core bullet X/Z positions; the arrow mesh's front tip is the authoritative hit point
- Shield block/guard sprite poses use the renderer's existing parameters. Only actual block events create impact feedback; no blue shield arc is added
- Hero health appears as the original short foot-level bar. Camp/injured allies and the nearest four injured enemies use projected small bars. Boss health remains the inherited top-level HUD
- Transient enemy deaths are retained for 0.8 seconds by the large core and visually fade by that time

## Test entry points

- Normal input-only demonstration: `godot --path <project> res://large/main.tscn -- --demo --demo-seconds=60 --metrics=<absolute.json>`
- Explicit isolated region setup: add `--large-review=1` through `6`, or `--large-review=boss`. The numbered areas only move the starting point. The explicitly labelled `boss` review also calls the normal `spawn_boss()` for a full-health 1,700 HP encounter and BGM transition. No review mode weakens enemies or grants upgrades; all display a permanent region-test label
- `get_stats()` provides source counts/batches, actor active/spare counts and terrain chunks
- `get_metrics()` adds original gameplay stats, input-demo/test-placement mode and measured frame timings
- Headless checks prove loading, simulation and numerical contracts. Pixel alignment, readability and final performance still require actual native rendering
