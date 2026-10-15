extends Node3D
## Sparse, authored environmental flipbooks. This node never owns a time source.
## Immutable AtlasTexture frames are swapped by the authoritative elapsed clock;
## world roots, physical terrain, and actor/projectile navigation stay unchanged.
const MANIFEST_PATH := "res://assets/environment_animation/environment_animation_manifest.json"
const ROOT_Y := 0.047
const ROAD_CLEARANCE := 1.82
const CAMP_CLEARANCE := 3.85
const FLAG_HEIGHT := 2.15
const GRASS_HEIGHT := 0.82

var variants: Dictionary = {}
var placements: Array[Dictionary] = []
var live_by_chunk: Dictionary = {}
var assets_ready := false
var last_clock := -1.0
var frame_changes := 0
var reset_count := 0
var rejected_placements := 0
var load_errors: Array[String] = []
var _alpha_scissor_threshold := 0.18
var _terrain: Node3D
var _placements_by_chunk: Dictionary = {}
var _textures: Dictionary = {}

func setup(terrain: Node3D) -> void:
	_terrain = terrain
	name = "AuthoredEnvironmentFlipbooks"
	set_process(false)
	set_physics_process(false)
	set_meta("clock_source", "terrain.update_view elapsed / logic.time only")
	set_meta("collision_source", "none: decoration only")
	set_meta("animation_method", "immutable drawn atlas frames; no vertex sway")
	if not FileAccess.file_exists(MANIFEST_PATH):
		load_errors.append("Environment animation manifest is not present")
		return
	var document = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not document is Dictionary:
		load_errors.append("Environment animation manifest is not an object")
		return
	_alpha_scissor_threshold = clampf(float(document.get("alpha_scissor_threshold", 0.18)), 0.01, 0.99)
	var atlas_path := str(document.get("atlas", ""))
	for definition in document.get("variants", []):
		if not definition is Dictionary: continue
		_load_variant(definition, atlas_path)
	if variants.is_empty(): return
	_author_placements()
	assets_ready = not placements.is_empty()

func _load_variant(definition: Dictionary, default_atlas: String) -> void:
	var variant_name := str(definition.get("name", ""))
	var path := str(definition.get("atlas", default_atlas))
	if not path.begins_with("res://"):
		path = MANIFEST_PATH.get_base_dir().path_join(path)
	# Delivery may use a byte-identical lossless WebP container. Keep the PNG
	# manifest as the source-art audit and prefer its imported runtime twin.
	var lossless_path := path.get_basename() + ".webp"
	if ResourceLoader.exists(lossless_path): path = lossless_path
	if variant_name.is_empty() or not ResourceLoader.exists(path):
		load_errors.append("Missing atlas for variant " + variant_name + ": " + path)
		return
	if not _textures.has(path): _textures[path] = load(path)
	var texture: Texture2D = _textures[path]
	var frames: Array[Dictionary] = []
	var static_layers: Array[Dictionary] = []
	var total_ms := 0.0
	var fps := maxf(1.0, float(definition.get("fps", 5.0)))
	for source_frame in definition.get("frames", []):
		var frame := _frame_resource(source_frame, texture, variant_name)
		if frame.is_empty(): return
		total_ms += maxf(1.0, float(source_frame.get("duration_ms", 1000.0 / fps)))
		frame["end_ms"] = total_ms
		frames.append(frame)
	for source_layer in definition.get("static_layers", []):
		var layer := _frame_resource(source_layer, texture, variant_name)
		if layer.is_empty(): return
		static_layers.append(layer)
	if frames.is_empty() or total_ms <= 0.0:
		load_errors.append("Empty flipbook " + variant_name)
		return
	var kind := str(definition.get("kind", "grass" if variant_name.contains("grass") else "flag"))
	var reference_height := float(definition.get("recommended_visible_height_px", definition.get("visible_height_px", frames[0].rect.size.y)))
	variants[variant_name] = {"name": variant_name, "kind": kind, "frames": frames, "static_layers": static_layers, "total_ms": total_ms, "reference_height": maxf(1.0, reference_height), "plane": str(definition.get("plane", "upright")), "atlas": path, "ground_height": float(definition.get("recommended_world_size", [2.2, 1.5])[1])}

func _frame_resource(source: Dictionary, texture: Texture2D, label: String) -> Dictionary:
	var rect_array: Array = source.get("rect", source.get("source_rect", []))
	var anchor_array: Array = source.get("anchor", source.get("ground_anchor", []))
	if rect_array.size() != 4 or anchor_array.size() != 2:
		load_errors.append("Invalid crop or root for " + label)
		return {}
	var rect := Rect2(float(rect_array[0]), float(rect_array[1]), float(rect_array[2]), float(rect_array[3]))
	if not rect.has_area() or not Rect2(Vector2.ZERO, texture.get_size()).encloses(rect):
		load_errors.append("Out-of-bounds crop for " + label)
		return {}
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = rect
	atlas.filter_clip = true
	var anchor := Vector2(float(anchor_array[0]), float(anchor_array[1]))
	return {"texture": atlas, "rect": rect, "anchor": anchor, "offset": Vector2(rect.size.x * 0.5 - anchor.x, anchor.y - rect.size.y * 0.5)}

func _author_placements() -> void:
	# Three quiet authored vignettes in each of the four continuous stages.
	# Sparse sides of the actual new routes, never the troop-travel centerline.
	var district_sites := [
		[Vector2(10.2,35.8),Vector2(39.1,43.4),Vector2(36.2,80.6)],
		[Vector2(58.5,42.0),Vector2(77.5,64.8),Vector2(86.2,85.3)],
		[Vector2(105.2,41.5),Vector2(130.0,70.0),Vector2(143.0,90.0)],
		[Vector2(167.0,36.3),Vector2(189.1,68.6),Vector2(180.0,82.0)]
	]
	var flags: Array[String] = []
	var grasses: Array[String] = []
	var patches: Array[String] = []
	for variant_name in variants:
		var variant: Dictionary = variants[variant_name]
		if variant.plane == "ground" or variant.kind == "ground": patches.append(variant_name)
		elif variant.kind == "grass": grasses.append(variant_name)
		else: flags.append(variant_name)
	for district in range(district_sites.size()):
		for site in range(district_sites[district].size()):
			var target: Vector2 = district_sites[district][site]
			var location := _safe_site(target, 0.48)
			if location.x < 0.0: continue
			if not flags.is_empty():
				_add_placement(flags[(district + site) % flags.size()], location, FLAG_HEIGHT * (0.94 if site == 1 else 1.0), district, site)
			if not grasses.is_empty():
				for tuft in range(3):
					var offset: Vector2 = [Vector2(-1.28, 0.22), Vector2(0.94, 0.58), Vector2(1.84, -0.66)][tuft]
					var grass_at := _safe_site(location + offset, 0.28)
					if grass_at.x >= 0.0 and grass_at.distance_to(location) > 0.60:
						_add_placement(grasses[(district + tuft) % grasses.size()], grass_at, GRASS_HEIGHT * [0.84, 1.0, 0.92][tuft], district, site * 3 + tuft)
			if not patches.is_empty():
				var patch_name := patches[(district + site) % patches.size()]
				_add_placement(patch_name, location, variants[patch_name].ground_height, district, site)

func _safe_site(wanted: Vector2, radius: float) -> Vector2:
	# Bounded local adjustments only; never fill the world procedurally.
	for offset in [Vector2.ZERO, Vector2(-0.7, 0.0), Vector2(0.7, 0.0), Vector2(0.0, 0.75), Vector2(0.0, -0.75), Vector2(-0.8, 0.7), Vector2(0.8, 0.7)]:
		var point: Vector2 = wanted + offset
		if not Rect2(Vector2(2.0, 2.0), _terrain.WORLD_SIZE - Vector2(4.0, 4.0)).has_point(point): continue
		if not _terrain.is_free(point, radius): continue
		if _terrain.floor_height(point) != 0.0: continue
		if _terrain._distance_to_road(point) < ROAD_CLEARANCE: continue
		var clear := true
		for landmark in _terrain.world_landmarks:
			if point.distance_to(landmark.p) < CAMP_CLEARANCE: clear = false; break
		if clear: return point
	rejected_placements += 1
	return Vector2(-1.0, -1.0)

func _add_placement(variant_name: String, at: Vector2, height: float, district: int, site: int) -> void:
	var spec := {"variant": variant_name, "position": at, "height": height, "district": district, "phase": fmod(float(district * 7 + site) * 0.173, 1.0), "id": placements.size()}
	placements.append(spec)
	var key: Vector2i = _terrain._chunk_of(at)
	if not _placements_by_chunk.has(key): _placements_by_chunk[key] = []
	_placements_by_chunk[key].append(spec)

func attach_chunk(key: Vector2i, chunk_parent: Node3D) -> void:
	if not assets_ready or live_by_chunk.has(key): return
	var live: Array[Dictionary] = []
	var sprite_count := 0
	for spec in _placements_by_chunk.get(key, []):
		var variant: Dictionary = variants[spec.variant]
		var root := Node3D.new()
		root.name = "Drawn_%s_%02d" % [spec.variant, spec.id]
		root.position = Vector3(spec.position.x, 0.029 if variant.plane == "ground" else ROOT_Y, spec.position.y)
		root.set_meta("ground_anchor", spec.position)
		root.set_meta("placement_id", spec.id)
		root.set_meta("district", spec.district)
		chunk_parent.add_child(root)
		var pixel_size := float(spec.height) / float(variant.reference_height)
		for layer in variant.static_layers:
			var static_sprite := _make_sprite(root, variant, pixel_size)
			static_sprite.name = "LockedStaticBase"
			_apply_frame(static_sprite, layer)
			sprite_count += 1
		var sprite := _make_sprite(root, variant, pixel_size)
		sprite.name = "AuthoredFlipbook"
		var live_item := {"root": root, "sprite": sprite, "variant": spec.variant, "phase": spec.phase, "frame": -1, "placement_id": spec.id}
		_set_current_frame(live_item, maxf(0.0, last_clock))
		live.append(live_item)
		sprite_count += 1
	live_by_chunk[key] = live
	chunk_parent.set_meta("authored_detail_count", live.size())
	chunk_parent.set_meta("authored_sprite_count", sprite_count)

func _make_sprite(parent: Node3D, variant: Dictionary, pixel_size: float) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.pixel_size = pixel_size
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = _alpha_scissor_threshold
	sprite.no_depth_test = false
	sprite.shaded = true
	sprite.double_sided = true
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if variant.plane == "ground":
		sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		sprite.rotation.x = -PI * 0.5
	else:
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(sprite)
	return sprite

func detach_chunk(key: Vector2i) -> void:
	# The terrain owns/frees the chunk and nodes. Drop all corresponding refs first.
	live_by_chunk.erase(key)

func update_clock(elapsed: float) -> void:
	if not assets_ready or is_equal_approx(last_clock, elapsed): return
	if last_clock >= 0.0 and elapsed < last_clock: reset_count += 1
	last_clock = elapsed
	for live in live_by_chunk.values():
		for item in live: _set_current_frame(item, maxf(0.0, elapsed))

func _set_current_frame(item: Dictionary, elapsed: float) -> void:
	var variant: Dictionary = variants[item.variant]
	var at_ms := fposmod(elapsed * 1000.0 + float(item.phase) * float(variant.total_ms), float(variant.total_ms))
	var frames: Array = variant.frames
	var selected := frames.size() - 1
	for i in range(frames.size()):
		if at_ms < float(frames[i].end_ms): selected = i; break
	if selected == int(item.frame): return
	_apply_frame(item.sprite, frames[selected])
	item.frame = selected
	item.sprite.set_meta("source_frame", selected)
	item.sprite.set_meta("variant", item.variant)
	frame_changes += 1

func _apply_frame(sprite: Sprite3D, frame: Dictionary) -> void:
	# Crop/anchor compensation is in local pixels, never a change to the world root.
	sprite.texture = frame.texture
	sprite.offset = frame.offset

func get_stats() -> Dictionary:
	var live_count := 0
	var animated_count := 0
	var sprite_count := 0
	for live in live_by_chunk.values():
		live_count += live.size()
		for item in live:
			sprite_count += item.root.get_child_count()
			if variants[item.variant].frames.size() > 1: animated_count += 1
	return {"ready": assets_ready, "variants": variants.size(), "total_placements": placements.size(), "live_details": live_count, "live_animated": animated_count, "live_sprites": sprite_count, "live_chunks": live_by_chunk.size(), "last_clock": last_clock, "frame_changes": frame_changes, "reset_count": reset_count, "rejected_placements": rejected_placements, "load_errors": load_errors, "new_collision_bodies": 0}
