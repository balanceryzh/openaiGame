# Full first-level terrain rendering

`terrain_world.gd` presents the existing 10,000 × 5,500 pixel battlefield as a 200 × 110 unit X/Z world. Exactly 50 original pixels equal one unit. This is not a tiled copy of the smaller HD-2D demo.

## Contract

- `build(logic_terrain)` accepts the authoritative 2D terrain object, including its blockers, bridge gaps, routes and landmarks
- `update_view(hero_px, elapsed, view_rect_px)` accepts original-pixel hero coordinates and the actual orthographic camera's projected ground rectangle. It streams 24-unit chunks intersecting that view plus a 1.25-unit guard band, up to 4 × 3 chunks. An empty rectangle falls back to a hero-centered 3 × 3 set
- `floor_height(world_xz)` uses world units. Source trenches are at -1.25, bridge decks and ordinary ground are at 0
- `is_free(world_xz, radiusworld)` converts back to pixels and delegates to the original collision query
- `get_stats()` reports live chunks, peak chunks, mesh batches, instances, plants, builds, evictions, original geometry counts and newly added physical bodies (always zero)

The scene root owns lighting, camera and environment. Terrain creates no lights, actor/corpse models, weapon scatter, physics bodies, or alternate navigation. Far chunks are freed before replacement chunks are created; the complete original logical map remains available.

## Rendering

Ground meshes are clipped around the original ditch and bridge rectangles. Ditches have lower floors, sidewalls and below-ground wooden shoring. The eleven wooden bridges are ground-flush, have no new upper rails and leave all original broad free gaps traversable. Routes remain 104 original pixels wide; actual road polygons and wheel ruts are clipped at excavations and decks. Sparse irregular shoulders soften their edges. A few wet patches beside walls and ditch lips reuse the sample’s inexpensive, elapsed-driven highlight approach; they add no lights or live reflections.

Walls use bounded, staggered masonry and damaged crowns; barricades are wooden teeth and braces; wagons have planked beds, frames and open broken-wheel silhouettes. Geometry is batched by shared material in each chunk. Existing exact stone, mud and ash crops are reused. The quiet original ground image is mapped once over the entire world, with mild continuous regional tint.

The six original districts retain their names, layouts and distinguishing landmark silhouettes: broken flags, supply carts, charred orchard forks, the hanging bell at the chapel gate, the wooden lookout and stepped northern fort remnants. All landmark ground-contact feet are inside original blocker footprints. Elevated bell beams and platforms can overhang free ground.

Vegetation uses the unchanged original atlas and measured roots. There are 304 deterministic, locally composed plant specifications beside walls and wet ditch edges; only plants in live chunks are instantiated. Road centers plus a safety margin and camp clearings stay open. Top-only shader wind uses the supplied elapsed time, so a frozen game clock freezes it.

## Verification

Run with Godot 4.6.3:

- `godot --headless --path . --script res://large/qa/test_terrain_ready.gd`
- `godot --headless --path . --script res://large/qa/test_terrain_mesh_audit.gd`

The mesh audit checks 45 unique chunks, 784 ground-contact geometry feet, all fourteen trench and eleven bridge center heights, the corresponding twenty-five ground/road holes, vegetation placement and the shader clock. Its result file is `large/qa/terrain_mesh_audit_results.json`.

Godot's dummy headless renderer does not return usable GPU MultiMesh transforms. The audit sets `audit_geometry = true` before building to inspect the exact CPU transforms submitted for rendering. Normal play leaves this opt-in data retention disabled. These checks establish geometry/logic agreement; they are not GPU frame-rate or visual-quality certification.
