extends RefCounted
## Persistent battlefield bodies, indexed by region. Only this module may issue
## a body identity; the director consumes it exactly once before creating a foe.
## Rendering/querying never generates, resurrects, or consumes a body.

const REGION_SIZE := 384.0
const MIN_SLOTS_PER_REGION := 18
const SLOTS_PER_REGION := 30
const BODY_SEPARATION := 31.0
const MAX_BODY_SLOTS := 18000
const TERRAIN_CLEARANCE := 26.0
const EDGE_MARGIN := Vector2(42.0, 105.0)
const PREEXIST_SECONDS := 6.0
const REPLENISH_COOLDOWN := 24.0
const REPLENISH_VIEW_MARGIN := 64.0
const HERO_CLEARANCE := 220.0
const ALLY_CLEARANCE := 110.0
const MAINTENANCE_INTERVAL := 0.5
const PRELOAD_DISTANCE := 1450.0
const PREFERRED_SPAWN_RADIUS := 540.0
# Wider, existing-body-only reserve sustains pressure if a stationary player has
# already emptied the near field. This is not an empty-ground spawn fallback.
const RESERVE_SPAWN_RADIUS := 960.0

# Optional presentation-scale tuning. Defaults preserve v0.5 exactly; changing
# these before reset/prime is an explicit HD-only density decision, not a change
# to director frequency, safety distances, corpses hidden on screen, or actor cap.
var min_slots_per_region := MIN_SLOTS_PER_REGION
var slots_per_region := SLOTS_PER_REGION
var reserve_spawn_radius := RESERVE_SPAWN_RADIUS
var replenish_enabled := true
# Explicit campaign bands; the low-density ends preserve readable camps while
# the two middle battlefields have enough actual bodies for necromancer casts.
var use_stage_density := false
var stage_slot_ranges: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 5), Vector2i(3, 5), Vector2i(1, 2)]

var world_size := Vector2(10000, 5500)
var world_seed := 73127
var walkable := Callable()
var regions: Dictionary = {}
var bodies_by_id: Dictionary = {}
var generated_regions := 0
var total_slots := 0
var total_consumed := 0
var total_replenished := 0
var last_query_slots := 0
var last_maintenance_slots := 0
var _maintenance_cd := 0.0
var _active := false

func _init(seed_value: int = 73127, size: Vector2 = Vector2(10000, 5500), ground: Callable = Callable()) -> void:
	reset(seed_value, size, ground)

func reset(seed_value: int = 73127, size: Vector2 = Vector2(10000, 5500), ground: Callable = Callable()) -> void:
	world_seed = seed_value
	world_size = size
	walkable = ground
	regions.clear()
	bodies_by_id.clear()
	generated_regions = 0
	total_slots = 0
	total_consumed = 0
	total_replenished = 0
	last_query_slots = 0
	last_maintenance_slots = 0
	_maintenance_cd = 0.0
	_active = false

## Call once during a new-run reset, before the first frame is displayed. All
## first-generation bodies are deterministically part of the original battlefield.
func prime(hero: Vector2, view_rect: Rect2, elapsed: float = 0.0) -> void:
	_ensure_area(_preload_rect(hero, view_rect), elapsed)

## Call only with authoritative game time and the actual world-space camera rect.
## Pausing or ending freezes generation, cooldowns, identities and consumption.
func step(dt: float, state: String, elapsed: float, hero: Vector2, view_rect: Rect2, allies: Array = []) -> void:
	_active = state == "play" and dt > 0.0
	if not _active:
		return
	_maintenance_cd -= dt
	if _maintenance_cd > 0.0:
		return
	_maintenance_cd = MAINTENANCE_INTERVAL
	_ensure_area(_preload_rect(hero, view_rect), elapsed)
	last_maintenance_slots = 0
	if not replenish_enabled:
		return
	var hidden_rect := view_rect.grow(REPLENISH_VIEW_MARGIN)
	var area := Rect2(hero - Vector2.ONE * PRELOAD_DISTANCE, Vector2.ONE * PRELOAD_DISTANCE * 2.0)
	for key in _region_keys(area):
		if not regions.has(key):
			continue
		for body in regions[key]:
			last_maintenance_slots += 1
			if not body.consumed or elapsed - float(body.consumed_at) < REPLENISH_COOLDOWN:
				continue
			var p: Vector2 = body.p
			if hidden_rect.has_point(p) or p.distance_squared_to(hero) < HERO_CLEARANCE * HERO_CLEARANCE:
				continue
			var ally_clear := true
			for ally in allies:
				if float(ally.get("hp", 1.0)) > 0.0 and p.distance_squared_to(ally.p) < ALLY_CLEARANCE * ALLY_CLEARANCE:
					ally_clear = false
					break
			if not ally_clear:
				continue
			bodies_by_id.erase(body.corpse_id)
			body.generation = int(body.generation) + 1
			body.corpse_id = _body_id(key, int(body.slot), int(body.generation))
			_assign_visual_identity(body)
			body.consumed = false
			body.consumed_at = -1.0
			body.available_at = elapsed + PREEXIST_SECONDS
			bodies_by_id[body.corpse_id] = body
			total_replenished += 1

func _preload_rect(hero: Vector2, view_rect: Rect2) -> Rect2:
	var local := Rect2(hero - Vector2.ONE * PRELOAD_DISTANCE, Vector2.ONE * PRELOAD_DISTANCE * 2.0)
	return local.merge(view_rect.grow(REGION_SIZE))

func _region_keys(area: Rect2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var bounds := area.intersection(Rect2(Vector2.ZERO, world_size))
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return result
	var first := Vector2i(floori(bounds.position.x / REGION_SIZE), floori(bounds.position.y / REGION_SIZE))
	var last := Vector2i(floori((bounds.end.x - 0.001) / REGION_SIZE), floori((bounds.end.y - 0.001) / REGION_SIZE))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			result.append(Vector2i(x, y))
	return result

func _ensure_area(area: Rect2, elapsed: float) -> void:
	for key in _region_keys(area):
		if not regions.has(key):
			_generate_region(key, elapsed)

func _body_id(key: Vector2i, slot: int, generation: int) -> String:
	return "%d:%d:%d:%d:%d" % [world_seed, key.x, key.y, slot, generation]

func _generate_region(key: Vector2i, elapsed: float) -> void:
	var local_rng := RandomNumberGenerator.new()
	# Fixed integer seed avoids dependence on camera travel or Dictionary iteration.
	local_rng.seed = world_seed + key.x * 73856093 + key.y * 19349663
	var entries: Array = []
	var origin := Vector2(key) * REGION_SIZE
	var cluster_count := local_rng.randi_range(2, 4)
	var centers: Array[Vector2] = []
	var radii: Array[Vector2] = []
	var rotations: Array[float] = []
	for _cluster in range(cluster_count):
		var center := Vector2(local_rng.randf_range(55, 329), local_rng.randf_range(55, 329))
		for _attempt in range(10):
			var separate := true
			for other in centers:
				separate = separate and center.distance_to(other) >= 100.0
			if separate:
				break
			center = Vector2(local_rng.randf_range(55, 329), local_rng.randf_range(55, 329))
		centers.append(center)
		radii.append(Vector2(local_rng.randf_range(30, 65), local_rng.randf_range(22, 48)))
		rotations.append(local_rng.randf_range(-PI, PI))
	# These quiet channels are irregular and differently angled in each region;
	# they do not create repeated straight grid streets or checkerboard heaps.
	var channel_center := Vector2(192, 192) + Vector2(local_rng.randf_range(-70, 70), local_rng.randf_range(-70, 70))
	var channel_normal := Vector2.from_angle(local_rng.randf_range(-PI, PI))
	var channel_half_width := local_rng.randf_range(17, 28)
	var density := density_range_at(origin + Vector2.ONE * REGION_SIZE * 0.5)
	var target_slots := local_rng.randi_range(density.x, density.y)
	for slot in range(target_slots):
		var p := Vector2.INF
		for _attempt in range(12):
			var local: Vector2
			if local_rng.randf() < 0.70:
				var cluster := local_rng.randi_range(0, cluster_count - 1)
				var scatter := Vector2(local_rng.randfn(0, radii[cluster].x), local_rng.randfn(0, radii[cluster].y))
				local = centers[cluster] + scatter.rotated(rotations[cluster])
			else:
				local = Vector2(local_rng.randf_range(8, 376), local_rng.randf_range(8, 376))
			if local.x < 8 or local.x > 376 or local.y < 8 or local.y > 376:
				continue
			if absf((local - channel_center).dot(channel_normal)) < channel_half_width:
				continue
			var separated := true
			for other in entries:
				if (origin + local).distance_squared_to(other.p) < BODY_SEPARATION * BODY_SEPARATION:
					separated = false
					break
			if separated:
				p = origin + local
				break
		var body_kind := "demon" if local_rng.randf() < 0.20 else "human"
		var actor_kind := ("caster" if local_rng.randf() < (1.0 / 3.0) else "demon") if body_kind == "demon" else ("archer" if slot % 2 else "shield")
		var face := Vector2.LEFT if local_rng.randf() < 0.5 else Vector2.RIGHT
		var variant := local_rng.randi_range(0, 2)
		if total_slots >= MAX_BODY_SLOTS:
			break
		if not p.is_finite():
			continue
		if p.x < EDGE_MARGIN.x or p.y < EDGE_MARGIN.y or p.x > world_size.x - EDGE_MARGIN.x or p.y > world_size.y - EDGE_MARGIN.x:
			continue
		if walkable.is_valid() and not bool(walkable.call(p, TERRAIN_CLEARANCE)):
			continue
		var body := {"corpse_id": _body_id(key, slot, 0), "body_kind": body_kind,
			"p": p, "face": face, "variant": variant, "actor_kind": actor_kind, "slot": slot,
			"generation": 0, "available_at": elapsed - PREEXIST_SECONDS,
			"consumed": false, "consumed_at": -1.0}
		_assign_visual_identity(body)
		entries.append(body)
		bodies_by_id[body.corpse_id] = body
		total_slots += 1
	regions[key] = entries
	generated_regions += 1

## Returned dictionaries are read-only views. No per-frame all-world scan occurs.
## Their p/body_kind/face/variant fields are sufficient for quiet body rendering.
func bodies_in_rect(area: Rect2) -> Array:
	var result: Array = []
	last_query_slots = 0
	for key in _region_keys(area):
		if not regions.has(key):
			continue
		for body in regions[key]:
			last_query_slots += 1
			if not body.consumed and area.has_point(body.p):
				result.append(body)
	return result

func candidates(hero: Vector2, body_kind: String, elapsed: float, radius: float = PREFERRED_SPAWN_RADIUS, actor_kind: String = "") -> Array:
	var result: Array = []
	var area := Rect2(hero - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	for body in bodies_in_rect(area):
		if String(body.get("reserved_by", "")).is_empty() and body.body_kind == body_kind and (actor_kind.is_empty() or body.actor_kind == actor_kind) and elapsed >= float(body.available_at) and hero.distance_squared_to(body.p) <= radius * radius:
			result.append(body)
	return result

func peek(corpse_id: String) -> Dictionary:
	if not bodies_by_id.has(corpse_id):
		return {}
	var body: Dictionary = bodies_by_id[corpse_id]
	return {} if body.consumed else body

## The explicit state and step's active latch both gate consumption. A successful
## claim removes the static drawing immediately; the rise entity now owns it.
func consume(corpse_id: String, body_kind: String, elapsed: float, state: String = "play", owner_id: String = "") -> bool:
	if state != "play" or not _active:
		return false
	var body := peek(corpse_id)
	if body.is_empty() or body.body_kind != body_kind or elapsed < float(body.available_at) or String(body.get("reserved_by", "")) != owner_id:
		return false
	body.consumed = true
	body["reserved_by"] = ""
	body["state"] = "consumed"
	body.consumed_at = elapsed
	total_consumed += 1
	return true

func population() -> Dictionary:
	var result := {"human": 0, "demon": 0, "consumed": 0, "slots": total_slots, "regions": generated_regions}
	for key in regions:
		for body in regions[key]:
			if body.consumed:
				result.consumed += 1
			else:
				result[body.body_kind] += 1
	return result

## Source appearance is authored before it is first displayed and copied on birth.
## It can never switch from a human corpse to a demon or reroll on activation.
func _assign_visual_identity(body: Dictionary) -> void:
	var visual_roll := posmod(String(body.corpse_id).hash(), 4)
	var visual_kind := ("undead" if visual_roll < 2 else "zombie") if body.body_kind == "human" else String(body.actor_kind)
	var headgear := ("retained" if visual_roll == 2 else "fallen") if visual_kind == "zombie" else ("fallen" if visual_kind == "undead" else "none")
	body["view_id"] = "source:" + String(body.corpse_id)
	body["visual_kind"] = visual_kind
	body["skin_kind"] = visual_kind
	body["spawn_kind"] = visual_kind
	body["headgear_variant"] = headgear
	body["rise_path"] = "skeleton_transform" if visual_kind == "undead" else (("zombie_" + headgear) if visual_kind == "zombie" else "demon_rise")
	body["source_type"] = body.body_kind
	body["facing"] = body.face
	body["rotation"] = float(posmod(String(body.corpse_id).hash(), 9) - 4) * 0.045
	body["state"] = "available"


func density_range_at(p: Vector2) -> Vector2i:
	if not use_stage_density:
		return Vector2i(maxi(1, min_slots_per_region), maxi(maxi(1, min_slots_per_region), slots_per_region))
	var index := 0 if p.x < 2500.0 else (1 if p.x < 5000.0 else (2 if p.x < 7500.0 else 3))
	return stage_slot_ranges[index]

## Claiming a visible source does not consume it. Other summoners and the
## ordinary director cannot race the 2.2-second cast. Interruptions release it.
func reserve(corpse_id: String, owner_id: String, elapsed: float, state: String = "play") -> bool:
	if state != "play" or not _active or owner_id.is_empty(): return false
	var body := peek(corpse_id)
	if body.is_empty() or elapsed < float(body.available_at) or not String(body.get("reserved_by", "")).is_empty(): return false
	body["reserved_by"] = owner_id
	body["state"] = "targeted"
	return true

func release(corpse_id: String, owner_id: String) -> void:
	var body := peek(corpse_id)
	if not body.is_empty() and String(body.get("reserved_by", "")) == owner_id:
		body["reserved_by"] = ""
		body["state"] = "available"
