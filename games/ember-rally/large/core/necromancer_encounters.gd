extends RefCounted
## Real, interruptible caster-role enemies. Every summon claims one physical
## pre-existing source; its appearance/identity survives the whole lifecycle.
const MIDDLE_MIN_X := 2500.0
const MIDDLE_MAX_X := 7500.0
const MAX_NECROMANCERS := 2
const SPAWN_INTERVAL := 45.0
const INITIAL_DELAY := 1.5
const CAST_DURATION := 2.2
const CAST_COOLDOWN := 9.0
const INTERRUPT_COOLDOWN := 3.0
const SUMMON_RADIUS := 420.0
const HEALTH := 78.0
const SUMMON_BUDGET := 6
const EARTH_HEALTH := 24.0 # Weakest ordinary undead is 48 HP.
var spawn_cooldown := INITIAL_DELAY
var total_spawned := 0
var total_summoned := 0
var total_interrupted := 0
var active_stage := -1
var stage_first_spawned: Dictionary = {}

func reset() -> void:
	spawn_cooldown = INITIAL_DELAY
	total_spawned = 0
	total_summoned = 0
	total_interrupted = 0
	active_stage = -1
	stage_first_spawned.clear()

func is_middle(p: Vector2) -> bool:
	return p.x >= MIDDLE_MIN_X and p.x < MIDDLE_MAX_X

func stage_at(p: Vector2) -> int:
	return 1 if p.x < 5000.0 else 2

func configure(actor: Dictionary) -> void:
	actor["kind"] = "caster"
	actor["role"] = "necromancer"
	actor["subtype"] = "necromancer"
	actor["necromancer"] = true
	# Reuse the authored demon caster action sheet with its left/right mirroring.
	# A permanent green role ring, label and cast tether distinguish this role.
	actor["visual_kind"] = "caster"
	actor["skin_kind"] = "caster"
	actor["hp"] = HEALTH
	actor["max"] = HEALTH
	actor["phase"] = 0.0
	actor["summon_phase"] = 0.0
	actor["summon_duration"] = CAST_DURATION
	actor["summon_radius"] = SUMMON_RADIUS
	actor["summon_progress"] = 0.0
	actor["summon_target_p"] = actor.p
	actor["summon_source_id"] = ""
	actor["summon_cd"] = 1.2
	actor["stun"] = 0.0
	actor["summon_budget"] = SUMMON_BUDGET
	actor["summon_mode"] = ""
	actor["encounter_stage"] = stage_at(actor.p)

func living_count(game) -> int:
	var count := 0
	for actor in game.enemies + game.sleeping_enemies:
		if actor.get("necromancer", false) and float(actor.get("hp", 0)) > 0: count += 1
	return count

func step_spawn(game, dt: float) -> void:
	if game.state != "play" or dt <= 0: return
	spawn_cooldown -= dt
	if spawn_cooldown > 0: return
	spawn_cooldown = 1.0
	if living_count(game) >= MAX_NECROMANCERS or game.director.live_count(game.enemies) >= 139: return
	var point: Vector2 = game.director.find_entrance_position(game.hero, game.defenders(), game.enemies, game.WORLD, game.demon_entrance_position(), game.terrain.is_walkable)
	if point == Vector2.INF: return
	var actor: Dictionary = game.make_enemy(point, "caster")
	configure(actor)
	game.prepare_entrance_actor(actor, false)
	spawn_cooldown = SPAWN_INTERVAL
	total_spawned += 1

func _source_valid(game, actor: Dictionary, body: Dictionary) -> bool:
	if body.is_empty() or body.body_kind != "human": return false
	if actor.p.distance_squared_to(body.p) > SUMMON_RADIUS * SUMMON_RADIUS: return false
	if not game.terrain.has_line_of_sight(actor.p, body.p): return false
	if not game.director.position_is_safe(body.p, game.hero, game.defenders(), game.enemies, game.WORLD, game.terrain.is_walkable): return false
	return true

func begin_cast(game, actor: Dictionary) -> bool:
	if game.state != "play" or actor.hp <= 0 or float(actor.get("stun", 0)) > 0: return false
	if float(actor.get("summon_phase", 0)) > 0 or int(actor.get("summon_budget", SUMMON_BUDGET)) <= 0: return false
	if game.director.live_count(game.enemies) >= game.director.MAX_ACTIVE_ENEMIES - 1: return false
	var candidates: Array = game.corpse_field.candidates(actor.p, "human", game.time, SUMMON_RADIUS)
	candidates.sort_custom(func(a, b): return actor.p.distance_squared_to(a.p) < actor.p.distance_squared_to(b.p))
	for body in candidates:
		if not _source_valid(game, actor, body): continue
		if not game.corpse_field.reserve(body.corpse_id, actor.view_id, game.time, game.state): continue
		actor["summon_mode"] = "corpse"
		actor["summon_source_id"] = String(body.corpse_id)
		actor["summon_target_p"] = body.p
		actor["summon_phase"] = CAST_DURATION
		actor["phase"] = CAST_DURATION
		actor["summon_progress"] = 0.0
		actor["aim"] = body.p
		actor["attack_direction"] = (body.p - actor.p).normalized()
		actor["face"] = actor.attack_direction
		actor["moving"] = false
		return true
	# No usable corpse: lock one safe soil target for this cast. Never switch
	# from an invalidated corpse to earth during the same telegraph.
	for index in range(24):
		var point: Vector2 = actor.p + Vector2.from_angle(float(index) * TAU / 24.0) * (110.0 + 35.0 * (index % 4))
		if not game.director.position_is_safe(point, game.hero, game.defenders(), game.enemies, game.WORLD, game.terrain.is_walkable): continue
		if not game.terrain.has_line_of_sight(actor.p, point): continue
		actor["summon_mode"] = "earth"
		actor["summon_source_id"] = ""
		actor["summon_target_p"] = point
		actor["summon_phase"] = CAST_DURATION
		actor["phase"] = CAST_DURATION
		actor["summon_progress"] = 0.0
		actor["aim"] = point
		actor["attack_direction"] = (point - actor.p).normalized()
		actor["face"] = actor.attack_direction
		actor["moving"] = false
		return true
	actor["summon_cd"] = CAST_COOLDOWN
	return false

func interrupt(game, actor: Dictionary, stagger: bool = false) -> void:
	var source_id := String(actor.get("summon_source_id", ""))
	if float(actor.get("summon_phase", 0)) > 0: total_interrupted += 1
	if not source_id.is_empty():
		game.corpse_field.release(source_id, String(actor.view_id))
	actor["summon_source_id"] = ""
	actor["summon_phase"] = 0.0
	actor["phase"] = 0.0
	actor["summon_progress"] = 0.0
	actor["summon_cd"] = maxf(INTERRUPT_COOLDOWN, float(actor.get("summon_cd", 0)))
	if stagger: actor["stun"] = maxf(0.45, float(actor.get("stun", 0)))

## Return false while the caster is rooted in a telegraphed cast or stagger.
func step_actor(game, actor: Dictionary, dt: float) -> bool:
	if game.state != "play" or dt <= 0: return false
	if actor.hp <= 0:
		interrupt(game, actor)
		return false
	if float(actor.get("stun", 0)) > 0:
		interrupt(game, actor)
		actor.stun = maxf(0.0, float(actor.stun) - dt)
		return false
	actor["summon_cd"] = maxf(0.0, float(actor.get("summon_cd", 0)) - dt)
	if float(actor.get("summon_phase", 0)) > 0:
		var body: Dictionary = game.corpse_field.peek(String(actor.summon_source_id))
		if (actor.get("summon_mode", "corpse") == "corpse" and (not _source_valid(game, actor, body) or String(body.get("reserved_by", "")) != String(actor.view_id))) or (actor.get("summon_mode", "") == "earth" and not game.director.position_is_safe(actor.summon_target_p, game.hero, game.defenders(), game.enemies, game.WORLD, game.terrain.is_walkable)):
			interrupt(game, actor)
			return false
		actor.summon_phase = maxf(0.0, float(actor.summon_phase) - dt)
		actor.phase = actor.summon_phase
		actor.summon_progress = 1.0 - float(actor.summon_phase) / CAST_DURATION
		if actor.summon_phase <= 0:
			_complete_cast(game, actor, body)
		return false
	if actor.summon_cd <= 0 and begin_cast(game, actor): return false
	return true

func _complete_cast(game, actor: Dictionary, body: Dictionary) -> void:
	if game.state != "play" or actor.hp <= 0 or game.director.live_count(game.enemies) >= game.director.MAX_ACTIVE_ENEMIES - 1:
		interrupt(game, actor)
		return
	var awakened: Dictionary
	var target: Vector2 = actor.summon_target_p
	if actor.get("summon_mode", "corpse") == "earth":
		awakened = game.make_enemy(target, "undead")
		awakened["visual_kind"] = "earth"
		awakened["skin_kind"] = "earth"
		awakened["rise_path"] = ""
		awakened["headgear_variant"] = "none"
		awakened["body_face"] = actor.get("face", Vector2.RIGHT)
		awakened["hp"] = EARTH_HEALTH
		awakened["max"] = EARTH_HEALTH
		awakened["origin"] = "earth_summon"
		awakened["spawn_style"] = "earth"
		awakened["rise_elapsed"] = 0.0
		awakened["rise_duration"] = 1.5
		awakened["rise_phase"] = 0
	else:
		if not game.corpse_field.consume(body.corpse_id, "human", game.time, game.state, actor.view_id):
			interrupt(game, actor)
			return
		var request := {"p": body.p, "kind": "undead", "origin": "necromancer", "spawn_style": "corpse", "corpse_id": body.corpse_id, "source_view_id": body.view_id, "body_kind": body.body_kind, "body_face": body.face, "body_variant": body.variant, "body_actor_kind": body.actor_kind}
		for key in ["visual_kind", "skin_kind", "spawn_kind", "headgear_variant", "rise_path", "source_type"]:
			if body.has(key): request[key] = body[key]
		awakened = game.make_enemy(body.p, "undead")
		game.director.apply_rise(awakened, request)
		awakened["face"] = body.face
	awakened["summoned_by"] = actor.view_id
	if actor.has("wave_id"): awakened["wave_id"] = actor.wave_id
	actor["summon_budget"] = int(actor.get("summon_budget", SUMMON_BUDGET)) - 1
	actor.summon_source_id = ""
	actor.summon_phase = 0.0
	actor.phase = 0.0
	actor.summon_progress = 0.0
	actor.summon_cd = CAST_COOLDOWN
	actor.attack_age = 0.18
	total_summoned += 1
	game.effects.append({"p": target, "life": 0.65, "color": Color("72d8ac"), "radius": 62.0})
