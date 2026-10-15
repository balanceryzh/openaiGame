extends RefCounted
## Continuous battlefield ecology. This module returns requests only; the game
## remains authoritative for enemy creation, combat, terrain and camp ownership.

const MAX_ACTIVE_ENEMIES := 140
const BOSS_RESERVED_SLOTS := 1
const MAX_ROAMING_ELITES := 5
const UNDEAD_WEIGHT := 0.85
const DEMON_WEIGHT := 0.10
const CASTER_WEIGHT := 0.05
const INITIAL_DELAY := 1.0
const INITIAL_INTERVAL := 1.25
const MIN_INTERVAL := 0.45
const RAMP_SECONDS := 105.0
const BATCH_RAMP_SECONDS := 45.0
const MAX_BATCH := 5
const RETRY_INTERVAL := 0.25
const RISE_DURATION := 1.5
const PRONE_DURATION := 0.50
const SUPPORT_DURATION := 0.55
const HERO_SAFE_DISTANCE := 220.0
const ALLY_SAFE_DISTANCE := 110.0
const ENEMY_SAFE_DISTANCE := 45.0
const SPAWN_FOOT_AXES := Vector2(76.0,132.0)
const SPAWN_MIN_DISTANCE := 260.0
const SPAWN_MAX_DISTANCE := 540.0
const CORNER_RESERVE_RADIUS := 1360.0
const CORNER_EDGE_BAND := 200.0
const TERRAIN_CLEARANCE := 26.0
const EDGE_MARGIN := Vector2(42.0, 105.0)
const POSITION_ATTEMPTS := 64
const CORPSE_REST_SECONDS := 20.0

var rng := RandomNumberGenerator.new()
var cooldown := INITIAL_DELAY
var corpse_last_used: Dictionary = {}
var total_requested := 0
# Binding activates strict production mode. Legacy vector fixtures remain available
# only to standalone tests that never bind a real battlefield corpse field.
var corpse_field: RefCounted = null
# HD instance policy. Standalone v0.5 fixtures keep their original defaults.
var entrance_only_elites := true
var allow_offscreen_spawns := false
var corpse_spawn_fraction := 1.0
var spawn_view_rect := Rect2()
var offscreen_sprite_margin := 140.0
var offscreen_max_distance := 1500.0
var offscreen_reachable := Callable()
var total_corpse_requested := 0
var total_offscreen_requested := 0
var total_corpse_choices := 0
var total_corpse_fallbacks := 0
var total_entry_awake_requested := 0
var entrance_cooldown := 3.0
var total_entrance_requested := 0
const ENTRANCE_INTERVAL := 9.0

func _init(seed_value: int = 73127):
	reset(seed_value)

func reset(seed_value: int = 73127) -> void:
	rng.seed = seed_value
	cooldown = INITIAL_DELAY
	corpse_last_used.clear()
	total_requested = 0
	total_corpse_requested = 0
	total_offscreen_requested = 0
	total_corpse_choices = 0
	total_corpse_fallbacks = 0
	total_entry_awake_requested = 0
	entrance_cooldown = 3.0
	total_entrance_requested = 0

func bind_corpse_field(field: RefCounted) -> void:
	corpse_field = field

func interval_at(elapsed: float) -> float:
	return maxf(MIN_INTERVAL, INITIAL_INTERVAL - maxf(0.0, elapsed) / RAMP_SECONDS)

func batch_at(elapsed: float) -> int:
	return mini(MAX_BATCH, 2 + int(maxf(0.0, elapsed) / BATCH_RAMP_SECONDS))

func is_elite(kind: String) -> bool:
	return kind == "demon" or kind == "caster"

func choose_kind(roll: float, roaming_elites: int = 0) -> String:
	if roaming_elites >= MAX_ROAMING_ELITES:
		return "undead"
	var weighted_roll := clampf(roll, 0.0, 1.0) * (UNDEAD_WEIGHT + DEMON_WEIGHT + CASTER_WEIGHT)
	if weighted_roll < UNDEAD_WEIGHT:
		return "undead"
	if weighted_roll < UNDEAD_WEIGHT + DEMON_WEIGHT:
		return "demon"
	return "caster"

func live_count(enemies: Array) -> int:
	var result := 0
	for enemy in enemies:
		if float(enemy.get("hp", 1.0)) > 0.0:
			result += 1
	return result

func roaming_elite_count(enemies: Array) -> int:
	var result := 0
	for enemy in enemies:
		if float(enemy.get("hp", 1.0)) > 0.0 and int(enemy.get("camp", -1)) < 0 and is_elite(String(enemy.get("kind", "undead"))):
			result += 1
	return result

func has_living_boss(enemies: Array) -> bool:
	for enemy in enemies:
		if enemy.get("kind", "") == "boss" and float(enemy.get("hp", 1.0)) > 0.0:
			return true
	return false

## Keep calling throughout normal and boss combat. Pause, upgrade, title, win and
## lose leave the countdown frozen. There is no post-pause catch-up wave.
## walkable must accept (position: Vector2, radius: float) -> bool.
func step(dt: float, state: String, elapsed: float, hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, walkable: Callable = Callable(), corpse_positions: Array = []) -> Array:
	var requests: Array = []
	if state != "play" or dt <= 0.0:
		return requests
	cooldown -= dt
	if cooldown > 0.0:
		return requests
	var limit := MAX_ACTIVE_ENEMIES if has_living_boss(enemies) else MAX_ACTIVE_ENEMIES - BOSS_RESERVED_SLOTS
	var available := maxi(0, limit - live_count(enemies))
	if available == 0:
		cooldown = RETRY_INTERVAL
		return requests
	var elites := roaming_elite_count(enemies)
	var reserved: Array = []
	for _i in range(mini(batch_at(elapsed), available)):
		var kind := "undead" if entrance_only_elites else choose_kind(rng.randf(), elites)
		var body: Dictionary = {}
		var position := Vector2.INF
		var origin := "corpse"
		if corpse_field != null:
			var prefer_corpse := not allow_offscreen_spawns or rng.randf() < corpse_spawn_fraction
			if prefer_corpse:
				total_corpse_choices += 1
				body = find_safe_body(kind, hero, allies, enemies, world_size, walkable, reserved, elapsed)
			if not body.is_empty():
				position = body.p
				if not corpse_field.consume(String(body.corpse_id), String(body.body_kind), elapsed, state):
					continue
			elif allow_offscreen_spawns:
				if prefer_corpse: total_corpse_fallbacks += 1
				origin = "offscreen"
				position = find_safe_offscreen_position(hero, allies, enemies, world_size, walkable, reserved)
				if position == Vector2.INF: continue
			else:
				continue
		else:
			# Compatibility path for the old isolated director tests only.
			position = find_safe_position(hero, allies, enemies, world_size, walkable, corpse_positions, reserved, elapsed)
			if position == Vector2.INF:
				break
		var request := {"p": position, "kind": kind, "camp": -1, "origin": origin,
			"spawn_style": "offscreen" if origin == "offscreen" else ("corpse" if corpse_field != null or kind == "undead" else "rift")}
		if origin != "offscreen":
			request["rise_elapsed"] = 0.0
			request["rise_duration"] = RISE_DURATION
			request["rise_phase"] = 0
		if not body.is_empty():
			request["corpse_id"] = body.corpse_id
			request["source_view_id"] = body.view_id
			request["body_kind"] = body.body_kind
			request["body_face"] = body.face
			request["body_variant"] = body.variant
			request["body_actor_kind"] = body.actor_kind
			for key in ["visual_kind", "skin_kind", "spawn_kind", "headgear_variant", "rise_path", "source_type"]:
				if body.has(key): request[key] = body[key]
		if origin == "offscreen":
			total_offscreen_requested += 1
			if position.distance_squared_to(hero) > 1550.0 * 1550.0:
				request["entry_awake"] = true
				request["entry_anchor"] = hero
				request["entry_expires_at"] = elapsed + 60.0
				total_entry_awake_requested += 1
		else: total_corpse_requested += 1
		requests.append(request)
		reserved.append(position)
		if corpse_field == null:
			corpse_last_used[position] = elapsed
		if is_elite(kind):
			elites += 1
		total_requested += 1
	cooldown = interval_at(elapsed) if not requests.is_empty() else RETRY_INTERVAL
	# Avoid an unbounded record during a long run with generated corpse positions.
	for position in corpse_last_used.keys():
		if elapsed - float(corpse_last_used[position]) >= CORPSE_REST_SECONDS:
			corpse_last_used.erase(position)
	return requests


## Ordinary reinforcements enter from beyond the actual camera plus sprite
## overhang. No source ID or rise state is invented for an offscreen entrant.
func find_safe_offscreen_position(hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, walkable: Callable = Callable(), reserved: Array = []) -> Vector2:
	if not spawn_view_rect.has_area() or not offscreen_reachable.is_valid(): return Vector2.INF
	var hidden := spawn_view_rect.grow(offscreen_sprite_margin)
	for _attempt in range(POSITION_ATTEMPTS):
		var side := rng.randi_range(0, 3)
		var padding := rng.randf_range(12.0, 80.0)
		var point: Vector2
		if side == 0: point = Vector2(hidden.position.x - padding, rng.randf_range(hidden.position.y, hidden.end.y))
		elif side == 1: point = Vector2(hidden.end.x + padding, rng.randf_range(hidden.position.y, hidden.end.y))
		elif side == 2: point = Vector2(rng.randf_range(hidden.position.x, hidden.end.x), hidden.position.y - padding)
		else: point = Vector2(rng.randf_range(hidden.position.x, hidden.end.x), hidden.end.y + padding)
		if hidden.has_point(point) or hero.distance_squared_to(point) > offscreen_max_distance * offscreen_max_distance:
			continue
		if hero.distance_squared_to(point) < SPAWN_MIN_DISTANCE * SPAWN_MIN_DISTANCE:
			continue
		if not position_is_safe(point, hero, allies, enemies, world_size, walkable, reserved):
			continue
		if offscreen_reachable.is_valid() and not bool(offscreen_reachable.call(point, hero)):
			continue
		return point
	return Vector2.INF

## The corpse branch always requires a matching physical body. Its near and
## farther existing-body rings never invent a source. In mixed mode, an empty
## result can instead enter the separately validated offscreen branch.
func find_safe_body(kind: String, hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, walkable: Callable = Callable(), reserved: Array = [], elapsed: float = 0.0) -> Dictionary:
	if corpse_field == null or kind == "boss":
		return {}
	var body_kind := "human" if kind == "undead" else "demon"
	var radii := [SPAWN_MAX_DISTANCE, corpse_field.reserve_spawn_radius]
	# A camera clamped to a world edge exposes almost all of the normal reserve.
	# Only exhausted edge areas may use this farther pre-existing-body pool, still
	# below the 1550px enemy sleep threshold and inside the 1450px field preload.
	if minf(minf(hero.x, hero.y), minf(world_size.x - hero.x, world_size.y - hero.y)) <= CORNER_EDGE_BAND:
		radii.append(CORNER_RESERVE_RADIUS)
	for radius in radii:
		var available_bodies: Array = corpse_field.candidates(hero, body_kind, elapsed, radius, kind if body_kind == "demon" else "")
		if available_bodies.is_empty():
			continue
		var start := rng.randi_range(0, available_bodies.size() - 1)
		for offset in range(available_bodies.size()):
			var body: Dictionary = available_bodies[(start + offset) % available_bodies.size()]
			if hero.distance_squared_to(body.p) < SPAWN_MIN_DISTANCE * SPAWN_MIN_DISTANCE:
				continue
			if position_is_safe(body.p, hero, allies, enemies, world_size, walkable, reserved):
				return body
	return {}

## Never clamps a point into validity: border clamping could silently move a body
## onto the hero, an ally, or blocked terrain. Unsafe candidates are rejected.
func find_safe_position(hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, walkable: Callable = Callable(), corpse_positions: Array = [], reserved: Array = [], elapsed: float = 0.0) -> Vector2:
	# This vector-only API is retained for legacy isolated tests. Production may
	# never use its empty-ground fallback, even if a caller invokes it directly.
	if corpse_field != null:
		return Vector2.INF
	# Visible pre-existing bodies are preferred when the caller provides them.
	if not corpse_positions.is_empty():
		var start := rng.randi_range(0, corpse_positions.size() - 1)
		for offset in range(corpse_positions.size()):
			var position: Vector2 = corpse_positions[(start + offset) % corpse_positions.size()]
			if hero.distance_to(position) > SPAWN_MAX_DISTANCE:
				continue
			if corpse_last_used.has(position) and elapsed - float(corpse_last_used[position]) < CORPSE_REST_SECONDS:
				continue
			if position_is_safe(position, hero, allies, enemies, world_size, walkable, reserved):
				return position
	for _attempt in range(POSITION_ATTEMPTS):
		var position := hero + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(SPAWN_MIN_DISTANCE, SPAWN_MAX_DISTANCE)
		if position_is_safe(position, hero, allies, enemies, world_size, walkable, reserved):
			return position
	return Vector2.INF

func position_is_safe(position: Vector2, hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, walkable: Callable = Callable(), reserved: Array = []) -> bool:
	if not position.is_finite():
		return false
	if position.x < EDGE_MARGIN.x or position.y < EDGE_MARGIN.y or position.x > world_size.x - EDGE_MARGIN.x or position.y > world_size.y - EDGE_MARGIN.x:
		return false
	if position.distance_squared_to(hero) < HERO_SAFE_DISTANCE * HERO_SAFE_DISTANCE:
		return false
	for ally in allies:
		if float(ally.get("hp", 1.0)) > 0.0 and position.distance_squared_to(ally.p) < ALLY_SAFE_DISTANCE * ALLY_SAFE_DISTANCE:
			return false
	for enemy in enemies:
		if float(enemy.get("hp", 1.0)) > 0.0 and ((position - enemy.p) / SPAWN_FOOT_AXES).length_squared() < 1.0:
			return false
	for other in reserved:
		if ((position - other) / SPAWN_FOOT_AXES).length_squared() < 1.0:
			return false
	return not walkable.is_valid() or bool(walkable.call(position, TERRAIN_CLEARANCE))

## Add only the rise fields to make_enemy()'s returned dictionary. Guards and the
## boss remain active immediately unless the game explicitly calls this function.
func apply_rise(enemy: Dictionary, request: Dictionary) -> void:
	enemy["origin"] = request.get("origin", "corpse")
	enemy["spawn_style"] = request.get("spawn_style", "corpse")
	if enemy.origin in ["offscreen", "demon_entrance"]:
		# Only truly farther-than-sleep-range corner entrants get a bounded
		# admission lease. It ends when they arrive or the player leaves the area.
		for key in ["entry_awake", "entry_anchor", "entry_expires_at"]:
			if request.has(key): enemy[key] = request[key]
		return
	if request.has("source_view_id"): enemy["view_id"] = request.source_view_id
	enemy["rise_elapsed"] = float(request.get("rise_elapsed", 0.0))
	enemy["rise_duration"] = float(request.get("rise_duration", RISE_DURATION))
	enemy["rise_phase"] = rise_phase(enemy)
	enemy["spawn_style"] = request.get("spawn_style", "corpse")
	for key in ["corpse_id", "body_kind", "body_face", "body_variant", "body_actor_kind", "visual_kind", "skin_kind", "spawn_kind", "headgear_variant", "rise_path", "source_type"]:
		if request.has(key):
			enemy[key] = request[key]

func is_rising(enemy: Dictionary) -> bool:
	return enemy.has("rise_elapsed") and float(enemy.rise_elapsed) < float(enemy.get("rise_duration", RISE_DURATION))

## Visual indices: 0 = prone body; 1 = arms supporting / knees under torso;
## 2 = standing up. The standing-up frame is STILL harmless until 1.5 seconds.
## A fully active entity is -1, allowing its ordinary movement sprite animation.
func rise_phase(enemy: Dictionary) -> int:
	if not is_rising(enemy):
		return -1
	var progress := float(enemy.rise_elapsed) / maxf(0.001, float(enemy.get("rise_duration", RISE_DURATION)))
	if progress < PRONE_DURATION / RISE_DURATION:
		return 0
	if progress < (PRONE_DURATION + SUPPORT_DURATION) / RISE_DURATION:
		return 1
	return 2

func can_act(enemy: Dictionary) -> bool:
	return float(enemy.get("hp", 1.0)) > 0.0 and not is_rising(enemy)

## Return whether this frame may run movement, caster shots, separation and
## contact damage. Existing active enemies do not need any special fields.
func advance_rise(enemy: Dictionary, dt: float, state: String = "play") -> bool:
	if state != "play":
		return false
	if is_rising(enemy):
		enemy.rise_elapsed = minf(float(enemy.get("rise_duration", RISE_DURATION)), float(enemy.rise_elapsed) + maxf(0.0, dt))
		enemy["rise_phase"] = rise_phase(enemy)
	return can_act(enemy)


## The final camp has a real, fixed gate-side reinforcement entrance. This is
## independent of the 80% offscreen ordinary wave branch and never a body rise.
func step_entrance(dt: float, state: String, hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, entrance: Vector2, walkable: Callable) -> Array:
	if state != "play" or dt <= 0.0: return []
	entrance_cooldown -= dt
	if entrance_cooldown > 0.0: return []
	entrance_cooldown = RETRY_INTERVAL
	var limit := MAX_ACTIVE_ENEMIES if has_living_boss(enemies) else MAX_ACTIVE_ENEMIES - BOSS_RESERVED_SLOTS
	if live_count(enemies) >= limit or roaming_elite_count(enemies) >= MAX_ROAMING_ELITES: return []
	var point := find_entrance_position(hero, allies, enemies, world_size, entrance, walkable)
	if point == Vector2.INF: return []
	var kind := "caster" if rng.randf() < 0.25 else "demon"
	entrance_cooldown = ENTRANCE_INTERVAL
	total_entrance_requested += 1
	total_requested += 1
	return [{"p": point, "kind": kind, "camp": -1, "origin": "demon_entrance", "spawn_style": "entrance"}]

func find_entrance_position(hero: Vector2, allies: Array, enemies: Array, world_size: Vector2, entrance: Vector2, walkable: Callable) -> Vector2:
	for _attempt in range(32):
		var point := entrance + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-125.0, 125.0))
		if position_is_safe(point, hero, allies, enemies, world_size, walkable): return point
	return Vector2.INF
