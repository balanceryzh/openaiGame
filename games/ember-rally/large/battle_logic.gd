extends "res://large/core/main.gd"
## Four-stage campaign combat, terrain and HUD, driven in pixel coordinates.
## The parent owns a real 3D scene. This node never creates or paints a 2D world.
const PIXELS_PER_UNIT := 50.0
const HolyFlashEffect = preload("res://large/holy_flash_effect.gd")
# The battlefield has no separate yard scale: 1 yard = 1 X/Z world unit = 50px.
# The 10-yard circle is measured center-to-center and includes its boundary.
const HOLY_FLASH_RADIUS_YARDS := 10.0
const HOLY_FLASH_RADIUS_PX := HOLY_FLASH_RADIUS_YARDS * PIXELS_PER_UNIT
const HOLY_FLASH_DAMAGE := 50.0
@export_range(0.1, 120.0, 0.1) var holy_flash_cooldown_seconds := 10.0
var holy_flash_cooldown := 0.0
var holy_flash_cast_count := 0
var holy_flash_last_hits := 0
var holy_flash_effect: Node3D
var view_adapter: Node = null
var render_view_rect2d := Rect2()
var _spawn_component_grid: AStarGrid2D
var _spawn_component_labels := PackedInt32Array()
var _spawn_component_width := 0
var _spawn_navigation_revision := -1

func _ready() -> void:
	font = load("res://assets/interface.ttf")
	rng.seed = 73127
	# Match the original setup's deterministic gameplay RNG state, without
	# allocating or drawing its obsolete 2D decorative geometry.
	for _i in range(1400):
		rng.randf_range(40, WORLD.x - 40)
		rng.randf_range(100, WORLD.y - 40)
		rng.randf()
		rng.randf_range(5, 20)
	audio_controller = AudioController.new()
	add_child(audio_controller)
	music = audio_controller.music
	volume = audio_controller.volume
	tiles = null
	world_canvas = null
	world_layer = null
	# Latest HD rule: a sparse finite narrative corpse field, with most ordinary
	# reinforcements entering safely beyond the actual camera already standing.
	corpse_field.use_stage_density = true
	corpse_field.min_slots_per_region = 1
	corpse_field.slots_per_region = 2
	corpse_field.replenish_enabled = false
	corpse_field.reserve_spawn_radius = corpse_field.RESERVE_SPAWN_RADIUS
	director.allow_offscreen_spawns = true
	director.corpse_spawn_fraction = 0.20
	director.offscreen_reachable = _offscreen_reachable
	director.spawn_view_rect = world_view_rect()
	reset_game()
	_ensure_spawn_components()
	state = "title"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprites.enabled = true
	demo_mode = "late" if "--camp-late-demo" in OS.get_cmdline_user_args() else "normal"
	demo = "--demo" in OS.get_cmdline_user_args() or demo_mode == "late"
	if demo: state = "play"

func _process(dt: float) -> void:
	# Parent process queues only the inherited HUD; no WorldCanvas exists.
	super._process(dt)

func simulate(dt: float) -> void:
	# No wall-clock timers/tweens: pause, map, upgrades and end states freeze it.
	if state == "play" and hp > 0.0 and dt > 0.0:
		holy_flash_cooldown = maxf(0.0, holy_flash_cooldown - dt)
		if is_instance_valid(holy_flash_effect): holy_flash_effect.advance(dt)
	_sync_offscreen_spawn_view()
	super.simulate(dt)

func reset_game() -> void:
	super.reset_game()
	holy_flash_cooldown = 0.0
	holy_flash_cast_count = 0
	holy_flash_last_hits = 0
	if is_instance_valid(holy_flash_effect): holy_flash_effect.clear()

func is_holy_flash_target(enemy: Dictionary) -> bool:
	# Skeletons and zombies share the authoritative "undead" combat class.
	# Mud constructs reuse that class for AI but are not resurrected soldiers.
	return String(enemy.get("kind", "")) == "undead" \
		and float(enemy.get("hp", 0.0)) > 0.0 \
		and not bool(enemy.get("necromancer", false)) \
		and String(enemy.get("visual_kind", "")) != "earth" \
		and String(enemy.get("skin_kind", "")) != "earth" \
		and String(enemy.get("origin", "")) != "earth_summon" \
		and String(enemy.get("spawn_style", "")) != "earth"

func cast_holy_flash() -> bool:
	if state != "play" or hp <= 0.0 or holy_flash_cooldown > 0.0: return false
	var center: Vector2 = hero
	holy_flash_cooldown = holy_flash_cooldown_seconds
	holy_flash_cast_count += 1
	holy_flash_last_hits = 0
	# Copy before hit_enemy removes killed actors. Include dormant actors so
	# presentation/capacity bookkeeping cannot make a nearby undead immune.
	var seen: Dictionary = {}
	for enemy: Dictionary in enemies.duplicate() + sleeping_enemies.duplicate():
		if not is_holy_flash_target(enemy): continue
		var point: Vector2 = enemy.p
		if center.distance_squared_to(point) > HOLY_FLASH_RADIUS_PX * HOLY_FLASH_RADIUS_PX: continue
		var identity: String = String(enemy.get("view_id", ""))
		if not identity.is_empty():
			if seen.has(identity): continue
			seen[identity] = true
		hit_enemy(enemy, HOLY_FLASH_DAMAGE)
		if float(enemy.hp) <= 0.0: sleeping_enemies.erase(enemy)
		holy_flash_last_hits += 1
	_show_holy_flash(center)
	queue_redraw()
	return true

func _show_holy_flash(center: Vector2) -> void:
	if not is_instance_valid(view_adapter) or not view_adapter is Node3D: return
	if not is_instance_valid(holy_flash_effect):
		holy_flash_effect = HolyFlashEffect.new()
		holy_flash_effect.name = "HolyFlashWorldEffect"
		view_adapter.add_child(holy_flash_effect)
		holy_flash_effect.setup(view_adapter)
	holy_flash_effect.play_at(center, HOLY_FLASH_RADIUS_PX)

func draw_hud() -> void:
	super.draw_hud()
	var ready := holy_flash_cooldown <= 0.0
	var gold := Color("fff0b3") if ready else Color("c5b787")
	draw_rect(Rect2(979, 634, 281, 68), Color(0.035, 0.045, 0.045, 0.87))
	draw_rect(Rect2(979, 634, 3, 68), gold)
	txt(Vector2(992, 656), "圣光闪  Q / X / RB", 17, gold)
	txt(Vector2(992, 679), "10码内亡灵 · 50伤害", 14, Color("c4cfbd"))
	var status := "就绪" if ready else "%.1f秒" % holy_flash_cooldown
	txt(Vector2(1200, 679), status, 14, gold)
	var progress := 1.0 - clampf(holy_flash_cooldown / maxf(0.1, holy_flash_cooldown_seconds), 0.0, 1.0)
	draw_rect(Rect2(992, 690, 254, 3), Color("38413a"))
	draw_rect(Rect2(992, 690, 254 * progress, 3), gold)

func _sync_offscreen_spawn_view() -> void:
	director.spawn_view_rect = world_view_rect()
	var hidden: Rect2 = director.spawn_view_rect.grow(director.offscreen_sprite_margin)
	var playable: Rect2 = terrain.PLAY_RECT.grow(-27.0)
	var nearest_edge := INF
	# The camera stays inside the map at its edges; a corner hero can therefore
	# be more than 1500px from every legal offscreen edge. Raise only that case.
	var candidates: Array[Vector2] = [
		Vector2(hidden.position.x - 12.0, clampf(hero.y, playable.position.y, playable.end.y - 1.0)),
		Vector2(hidden.end.x + 12.0, clampf(hero.y, playable.position.y, playable.end.y - 1.0)),
		Vector2(clampf(hero.x, playable.position.x, playable.end.x - 1.0), hidden.position.y - 12.0),
		Vector2(clampf(hero.x, playable.position.x, playable.end.x - 1.0), hidden.end.y + 12.0)]
	for candidate in candidates:
		if playable.has_point(candidate) and not hidden.has_point(candidate):
			nearest_edge = minf(nearest_edge, hero.distance_to(candidate))
	director.offscreen_max_distance = clampf(nearest_edge + 180.0, 1500.0, 2400.0)


func _ensure_spawn_components() -> void:
	var grid: AStarGrid2D = terrain.grids[18] if terrain.grids.has(18) else terrain._build_grid(18)
	var revision: int = int(terrain.get("navigation_revision")) if terrain.get("navigation_revision") != null else 0
	if grid == _spawn_component_grid and revision == _spawn_navigation_revision and not _spawn_component_labels.is_empty(): return
	_spawn_navigation_revision = revision
	_spawn_component_grid = grid
	_spawn_component_width = grid.region.size.x
	_spawn_component_labels.resize(grid.region.size.x * grid.region.size.y)
	_spawn_component_labels.fill(-1)
	var component := 0
	var cardinal: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
	for y in range(grid.region.size.y):
		for x in range(grid.region.size.x):
			var cell := Vector2i(x, y)
			var index := y * _spawn_component_width + x
			if grid.is_point_solid(cell) or _spawn_component_labels[index] >= 0: continue
			var queue: Array[Vector2i] = [cell]
			var cursor := 0
			_spawn_component_labels[index] = component
			while cursor < queue.size():
				var current: Vector2i = queue[cursor]
				cursor += 1
				for offset in cardinal:
					var next := current + offset
					if not grid.region.has_point(next) or grid.is_point_solid(next): continue
					var next_index := next.y * _spawn_component_width + next.x
					if _spawn_component_labels[next_index] >= 0: continue
					_spawn_component_labels[next_index] = component
					queue.append(next)
			component += 1

func _offscreen_reachable(from: Vector2, to: Vector2) -> bool:
	# Cached 4-neighbour connectivity uses the original authoritative 18px grid.
	# It does not add per-birth A* searches or consume the eight-path AI budget.
	_ensure_spawn_components()
	var a: Vector2i = terrain._nearest_cell(from, _spawn_component_grid, 18.0, true)
	var b: Vector2i = terrain._nearest_cell(to, _spawn_component_grid, 18.0, true)
	if a.x < 0 or b.x < 0: return false
	var first := _spawn_component_labels[a.y * _spawn_component_width + a.x]
	if first < 0 or first != _spawn_component_labels[b.y * _spawn_component_width + b.x]: return false
	if from.distance_squared_to(to) <= 1500.0 * 1500.0 or terrain.has_line_of_sight(from, to, 18.0): return true
	# The rare clamped-corner entry lease lasts 60s. A point across a long camp
	# wall can share a connected component yet require a >7,000px gate detour.
	# Reject that candidate instead of letting it sleep before reaching combat.
	# Raw cached-grid A* here does not consume the per-frame actor steering budget.
	var path: PackedVector2Array = _spawn_component_grid.get_point_path(a, b)
	if path.is_empty(): return false
	var distance := from.distance_to(path[0])
	for index in range(1, path.size()):
		distance += path[index - 1].distance_to(path[index])
		if distance > 3000.0: return false
	return distance + path[-1].distance_to(to) <= 3000.0

func world_view_rect(margin: float = 0.0) -> Rect2:
	if render_view_rect2d.has_area():
		return render_view_rect2d.grow(margin)
	return Rect2(camera_for_hero(hero), WORLD_VIEW_SIZE).grow(margin)

func screen(p: Vector2) -> Vector2:
	if is_instance_valid(view_adapter) and view_adapter.has_method("project_point"):
		return view_adapter.project_point(p)
	return super.screen(p)

func screen_to_world(p: Vector2) -> Vector2:
	if is_instance_valid(view_adapter) and view_adapter.has_method("unproject_point"):
		return view_adapter.unproject_point(p)
	return super.screen_to_world(p)

func _draw_world() -> void:
	# Deliberately empty: the inherited combat and HUD do not own world visuals.
	pass

func _exit_tree() -> void:
	if is_instance_valid(holy_flash_effect): holy_flash_effect.queue_free()
	# Release live playback on scene removal; the parent should also allow the
	# audio server one short tick before quitting a headless recording.
	if is_instance_valid(audio_controller):
		audio_controller.stop_effects()
		if is_instance_valid(music):
			music.stop()
			music.stream = null
		for voice in audio_controller.voices:
			voice.stream = null
