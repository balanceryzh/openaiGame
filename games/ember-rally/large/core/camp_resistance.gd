extends RefCounted
## Authoritative, ordinary combat for the six besieged soldiers.
## No expiry/death timer: only a landed melee swing or projectile changes HP.
## Main must skip owns_guard() enemies in its normal enemy AI, and include
## actors() in hostile projectile collision and its depth-sorted actor drawing.

const ACTIVATION_RADIUS := 750.0
const GUARD_ALERT_RADIUS := 260.0
const FIGHTER_ATTACK_INTERVAL := 1.8
const FIGHTER_DAMAGE := 8.0
const GUARD_ATTACK_INTERVAL := 2.0
const GUARD_DAMAGE := 4.0
const GUARD_WINDUP := 0.18
const MELEE_REACH := 62.0

func setup_camp(c: Dictionary) -> void:
	var health := 110.0 if c.kind == "shield" else 76.0
	c["fighter"] = {
		"p": c.p, "kind": c.kind, "hp": health, "max": health,
		"cd": 0.35, "hurt": 0.0, "block": 0.0, "flash": 0.0,
		"face": Vector2.UP, "attack_age": -1.0, "attack_done": false,
		"attack_direction": Vector2.UP, "guard": false, "moving": false,
		"camp_fighter": true,
		"view_id": str(c.get("view_id", "camp:%s:%s" % [c.p.x, c.p.y])) + ":fighter",
		"visual_kind": c.kind, "skin_kind": c.kind, "headgear_variant": "none", "rise_path": "",
	}
	c["status"] = "rescued" if c.get("rescued", false) else "dormant"
	c["active_age"] = 0.0
	c["death_recorded"] = false
	c["critical_reported"] = false
	for i in range(c.get("guards", []).size()):
		var g: Dictionary = c.guards[i]
		g["camp_attack_cd"] = 0.15 + i * 0.31
		g["camp_attack_age"] = -1.0
		g["camp_attack_done"] = true
		g["camp_target_actor"] = null

func owns_guard(game, e: Dictionary) -> bool:
	var index := int(e.get("camp", -1))
	if index < 0 or index >= game.camps.size():
		return false
	var c: Dictionary = game.camps[index]
	return c.has("fighter") and c.get("status", "dormant") in ["dormant", "active", "cleared"] and not c.get("rescued", false)

func actors(camps: Array) -> Array:
	var result: Array = []
	for c in camps:
		if c.has("fighter") and c.get("status", "dormant") in ["active", "cleared"] and c.fighter.hp > 0 and not c.get("rescued", false):
			result.append(c.fighter)
	return result

func living_guards(c: Dictionary) -> int:
	var count := 0
	for g in c.get("guards", []):
		if g.hp > 0:
			count += 1
	return count

func can_rescue(c: Dictionary) -> bool:
	return c.has("fighter") and c.fighter.hp > 0 and c.get("status", "dormant") in ["active", "cleared"] and not c.get("rescued", false) and living_guards(c) == 0

func rescue_in_reach(game, c: Dictionary) -> bool:
	if not can_rescue(c): return false
	# Rescue the surviving person at their current position, including small
	# crowd displacement. The contact rim matches friendly body occupancy
	# with an 8px interaction margin; walls and living guards still block it.
	var delta: Vector2 = game.hero - c.fighter.p
	return Vector2(delta.x / 84.0, delta.y / 140.0).length_squared() <= 1.0 and game.terrain.has_line_of_sight(game.hero, c.fighter.p)

func take_rescued_actor(c: Dictionary) -> Dictionary:
	if not can_rescue(c):
		return {}
	var actor: Dictionary = c.fighter
	c["status"] = "rescued"
	c["rescued"] = true
	actor["camp_fighter"] = false
	actor.cd = 0.0
	actor.attack_age = -1.0
	actor.attack_done = true
	actor.guard = false
	return actor

func update(game, dt: float) -> Array:
	var events: Array = []
	if game.state != "play" or dt <= 0:
		return events
	for c in game.camps:
		if not c.has("fighter"):
			setup_camp(c)
		if c.get("rescued", false) or c.status in ["rescued", "dead"]:
			continue
		if c.status == "dormant":
			if game.hero.distance_to(c.p) > ACTIVATION_RADIUS:
				continue
			c.status = "active"
			c["discovered"] = true
			events.append({"type": "activated", "camp": c})
		if c.fighter.hp <= 0:
			_record_death(game, c)
			events.append({"type": "dead", "camp": c})
			continue
		c.active_age += dt
		_update_fighter(game, c, dt)
		for g in c.guards:
			if g.hp > 0 and c.fighter.hp > 0:
				_update_guard(game, c, g, dt)
		if c.fighter.hp <= 0:
			_record_death(game, c)
			events.append({"type": "dead", "camp": c})
		elif c.fighter.hp <= c.fighter.max * 0.30 and living_guards(c) > 0 and not c.get("critical_reported", false):
			c.critical_reported = true
			events.append({"type": "critical", "camp": c})
		if c.fighter.hp > 0 and living_guards(c) == 0 and c.status != "cleared":
			c.status = "cleared"
			events.append({"type": "cleared", "camp": c})
	return events

func _nearest_threat(game, c: Dictionary, limit: float):
	var best = null
	for e in game.enemies:
		if e.hp <= 0:
			continue
		var distance: float = c.fighter.p.distance_to(e.p)
		if distance < limit and game.terrain.has_line_of_sight(c.fighter.p, e.p):
			limit = distance
			best = e
	return best

func _update_fighter(game, c: Dictionary, dt: float) -> void:
	var a: Dictionary = c.fighter
	a.cd -= dt
	a.hurt = maxf(0.0, a.hurt - dt)
	a.block = maxf(0.0, a.block - dt)
	a.flash = maxf(0.0, a.flash - dt)
	a.moving = false
	var reach := 490.0 if a.kind == "archer" else MELEE_REACH
	var target = _nearest_threat(game, c, reach)
	if target != null:
		a.face = (target.p - a.p).normalized()
		if a.cd <= 0 and a.attack_age < 0:
			a.cd = FIGHTER_ATTACK_INTERVAL
			a.attack_age = 0.0
			a.attack_done = false
			a.attack_direction = a.face
			if a.kind == "archer":
				game.play_sound("bow_draw")
	if a.attack_age >= 0:
		a.attack_age += dt
		var release := 0.18 if a.kind == "archer" else 0.12
		if a.attack_age >= release and not a.attack_done:
			a.attack_done = true
			if a.kind == "archer":
				game.shoot(a.p, a.attack_direction, 460.0, FIGHTER_DAMAGE, true)
				game.play_sound("bow_release")
				game.play_sound("arrow_flight")
			else:
				game.play_sound("sword_swing")
				# Recheck contact, fixed attack arc and sight on the strike frame.
				if target != null and target.hp > 0:
					var delta: Vector2 = target.p - a.p
					if delta.length() < MELEE_REACH and delta.normalized().dot(a.attack_direction) > -0.18 and game.terrain.has_line_of_sight(a.p, target.p):
						game.hit_enemy(target, FIGHTER_DAMAGE)
		if a.attack_age >= 0.38:
			a.attack_age = -1.0
	a.guard = false
	if a.kind == "shield":
		var nearest_bullet := 220.0
		for b in game.bullets:
			if not b.friendly and a.p.distance_to(b.p) < nearest_bullet and b.v.dot(a.p - b.p) > 0:
				nearest_bullet = a.p.distance_to(b.p)
				a.face = (b.p - a.p).normalized()
				a.guard = true

func _update_guard(game, c: Dictionary, e: Dictionary, dt: float) -> void:
	var previous_position: Vector2 = e.p
	e.flash = maxf(0.0, float(e.get("flash", 0.0)) - dt)
	e["camp_attack_cd"] = float(e.get("camp_attack_cd", 0.0)) - dt
	var victim = c.fighter
	var target: Vector2 = victim.p
	var distance: float = e.p.distance_to(target)
	# Saving a soldier can start with physically drawing the guards away.
	var hero_distance: float = e.p.distance_to(game.hero)
	if hero_distance < minf(distance, GUARD_ALERT_RADIUS):
		target = game.hero
		victim = null
		distance = hero_distance
	for a in game.allies:
		var ally_distance: float = e.p.distance_to(a.p)
		if a.hp > 0 and ally_distance < minf(distance, GUARD_ALERT_RADIUS):
			target = a.p
			victim = a
			distance = ally_distance
	var direction: Vector2 = (target - e.p).normalized()
	e["face"] = direction
	var age := float(e.get("camp_attack_age", -1.0))
	if age < 0 and e.camp_attack_cd <= 0 and distance < game.enemy_radius(e) + 46.0 and game.terrain.has_line_of_sight(e.p, target):
		age = 0.0
		e.camp_attack_cd = GUARD_ATTACK_INTERVAL
		e.camp_attack_done = false
		e.camp_target_actor = victim
		e["camp_target_hero"] = victim == null
		e["attack_direction"] = direction
	if age >= 0:
		age += dt
		if age >= GUARD_WINDUP and not e.get("camp_attack_done", true):
			e.camp_attack_done = true
			var struck = e.get("camp_target_actor")
			var hit_position: Vector2 = game.hero if e.get("camp_target_hero", false) else struck.p
			var delta: Vector2 = hit_position - e.p
			if delta.length() < game.enemy_melee_reach(e) and delta.normalized().dot(e.attack_direction) > 0.10 and game.terrain.has_line_of_sight(e.p, hit_position):
				e["crowd_landed_at"] = game.time
				if e.get("camp_target_hero", false):
					game.hurt_hero(10.0)
				elif struck.hp > 0:
					if struck.get("camp_fighter", false):
						var crowd_scale := 1.0 if c.guards.size() <= 3 else 2.8 / float(c.guards.size())
						var defense_scale := 0.70 if struck.kind == "archer" else 1.0
						var amount := (GUARD_DAMAGE + (0.5 if e.kind == "demon" else 0.0)) * crowd_scale * defense_scale
						hurt_fighter(game, struck, amount)
					else:
						game.hurt_ally(struck, 9.0)
		if age >= 0.4:
			age = -1.0
	e.camp_attack_age = age
	e["attack_age"] = age
	e["melee_done"] = true # Ordinary AI cannot replay an already-owned attack.
	var movement_target: Vector2 = e.get("crowd_approach", target)
	if e.p.distance_to(movement_target) > 1.0:
		var speed := 57.0 if e.kind == "undead" else 78.0
		e.p = game.terrain.steer_actor(e, movement_target, dt, speed, game.enemy_radius(e))
	# Shared cross-team spatial solver owns all foot separation.
	e["moving"] = e.p.distance_to(previous_position) > 0.05

func hurt_fighter(_game, a: Dictionary, amount: float) -> void:
	if a.hp <= 0 or amount <= 0:
		return
	# Each guard's attack_done prevents repeat hits. A different actual attacker
	# is not discarded by a shared immunity timer, so a surrounded fighter tires.
	a.hp = maxf(0.0, a.hp - amount)
	a.hurt = 0.18
	a.flash = 0.15

func finalize_deaths(game) -> void:
	for c in game.camps:
		if c.has("fighter") and not c.get("rescued", false) and c.fighter.hp <= 0 and c.get("status", "dormant") != "dead":
			_record_death(game, c)

func _record_death(game, c: Dictionary) -> void:
	if c.get("death_recorded", false):
		return
	c["death_recorded"] = true
	c.status = "dead"
	c.fighter.hp = 0.0
	c.fighter.attack_age = -1.0
	c.fighter.guard = false
	game.corpses.append(game.make_death_corpse(c.fighter, 2.0, c.fighter.face))
	game.fallen += 1
	game.play_sound("death")
	game.notice = "来迟了：一名被围困的士兵已经阵亡"
	game.notice_time = 4.0
	for e in c.guards:
		if e.hp > 0:
			e["camp"] = -1
		e["camp_target_actor"] = null
		e["camp_attack_age"] = -1.0
		e["attack_age"] = -1.0
		e["melee_done"] = true
		e["melee_cd"] = maxf(0.4, float(e.get("camp_attack_cd", 0.0)))
