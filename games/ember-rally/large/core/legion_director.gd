extends RefCounted
## Finite, clock-crossing-safe waves. Pending actors never count as defeated.
const TIMES := [300.0, 600.0, 900.0, 1200.0]
const SIZES := [24, 32, 40, 60]
const RELEASE_INTERVAL := 0.35
const BRIDGE_SECONDS := 3.0
var waves: Dictionary = {}
var pending: Array = []
var release_cd := 0.0
var final_started := false
var bridge_lowering_started_at := -1.0
var main_bridge_open := false
var rewards_pending := 0

func reset() -> void:
	waves.clear(); pending.clear(); release_cd = 0.0
	final_started = false; bridge_lowering_started_at = -1.0
	main_bridge_open = false; rewards_pending = 0

func observe_clock(elapsed: float, state: String) -> void:
	if state != "play": return
	for index in range(TIMES.size()):
		var id := index + 1
		if elapsed < TIMES[index] or waves.has(id): continue
		waves[id] = {"rewarded": false, "final": id == 4}
		if id == 4:
			final_started = true
			bridge_lowering_started_at = TIMES[index]
		# Boss leads final army out after the bridge is physically passable.
		if id == 4: pending.push_front({"wave_id": id, "kind": "boss"})
		for n in range(SIZES[index]):
			pending.append({"wave_id": id, "kind": "caster" if n % 8 == 7 else "demon", "summoner": n == 7})
	main_bridge_open = final_started and elapsed >= bridge_lowering_started_at + BRIDGE_SECONDS

func pending_count(id: int) -> int:
	var count := 0
	for request in pending:
		if int(request.wave_id) == id: count += 1
	return count

func step(game, dt: float) -> void:
	if game.state != "play" or dt <= 0.0: return
	observe_clock(game.time, game.state)
	if game.terrain.has_method("set_bridge_progress"):
		game.terrain.set_bridge_progress(bridge_progress(game.time))
	release_cd -= dt
	if not pending.is_empty() and release_cd <= 0.0 and game.director.live_count(game.enemies) < 140:
		var request: Dictionary = pending[0]
		var limit := 140 if request.kind == "boss" or game.director.has_living_boss(game.enemies) else 139
		if game.director.live_count(game.enemies) < limit and (int(request.wave_id) != 4 or main_bridge_open):
			var point: Vector2 = game.director.find_entrance_position(game.hero, game.defenders(), game.enemies, game.WORLD, game.BOSS_POSITION if int(request.wave_id) == 4 else game.demon_entrance_position(), game.terrain.is_walkable)
			if point == Vector2.INF and int(request.wave_id) == 4:
				# A player already inside camp may occupy the boss's home. Use
				# the other real interior assembly point, never teleport to them.
				point = game.director.find_entrance_position(game.hero, game.defenders(), game.enemies, game.WORLD, game.demon_entrance_position(), game.terrain.is_walkable)
			if point != Vector2.INF:
				var actor: Dictionary = game.make_enemy(point, request.kind)
				actor["wave_id"] = int(request.wave_id)
				actor["origin"] = "demon_entrance"
				actor["spawn_style"] = "entrance"
				game.prepare_entrance_actor(actor, int(request.wave_id) == 4)
				if request.get("summoner", false) and game.necromancers.living_count(game) < game.necromancers.MAX_NECROMANCERS:
					game.necromancers.configure(actor)
				if request.kind == "boss":
					game.boss_spawned = true
					game.play_sound("boss_charge")
					if game.audio_controller: game.audio_controller.set_track(1)
				pending.pop_front()
				release_cd = RELEASE_INTERVAL
	settle(game)

func settle(game) -> void:
	for id in waves:
		if waves[id].rewarded or pending_count(id) > 0: continue
		var alive := false
		for actor in game.enemies + game.sleeping_enemies:
			if int(actor.get("wave_id", -1)) == id and float(actor.get("hp", 0)) > 0:
				alive = true; break
		if alive or (id == 4 and not game.boss_dead): continue
		waves[id].rewarded = true
		if id == 4:
			if game.boss_dead and game.hp > 0:
				game.state = "win"; game.play_sound("rescue")
		else:
			rewards_pending += 1
	if rewards_pending > 0 and game.state == "play" and game.hp > 0:
		rewards_pending -= 1
		game.hp = minf(game.max_hp, game.hp + 20.0)
		for ally in game.allies: ally.hp = minf(ally.max, ally.hp + 20.0)
		game.notice = "军团全灭：三选一升级，队伍恢复20生命"
		game.notice_time = 5.0
		game.state = "upgrade"

func bridge_progress(elapsed: float) -> float:
	return clampf((elapsed - bridge_lowering_started_at) / BRIDGE_SECONDS, 0.0, 1.0) if final_started else 0.0

func status(enemies: Array) -> Array:
	var result: Array = []
	for id in waves:
		var living := 0
		for actor in enemies:
			if int(actor.get("wave_id", -1)) == id and float(actor.get("hp", 0)) > 0: living += 1
		result.append({"wave_id": id, "pending": pending_count(id), "living": living, "cleared": waves[id].rewarded, "final": id == 4})
	return result
