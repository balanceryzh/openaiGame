extends RefCounted
## Foot occupancy is separate from terrain radii and every combat hit range.
## A spatial hash bounds neighbour work; no team-size-squared separation loops.
const CELL := 160.0
const VISUAL_AXES := Vector2(76.0, 132.0)
const PUSH_SPEED := 175.0
var cells: Dictionary = {}
var bodies: Array = []
var pair_checks := 0
var movement_starts: Dictionary = {}
var follow_direction := Vector2.RIGHT

func reset() -> void:
	cells.clear(); bodies.clear(); movement_starts.clear(); follow_direction = Vector2.RIGHT

func begin_movement(game) -> void:
	movement_starts.clear()
	movement_starts["hero"] = game.hero
	for actor in game.defenders() + game.enemies:
		movement_starts[str(actor.get("view_id", ""))] = actor.p

func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))

func _add(actor: Dictionary, team: int, radius: float, fixed: bool = false) -> void:
	if float(actor.get("hp", 1)) <= 0: return
	var entry := {"actor": actor, "p": movement_starts.get(str(actor.get("view_id", "")), actor.p), "team": team, "radius": radius, "fixed": fixed, "push": Vector2.ZERO}
	entry["intent"] = actor.p - entry.p
	var key := _cell(entry.p)
	if not cells.has(key): cells[key] = []
	cells[key].append(bodies.size()); bodies.append(entry)

func follow_target(game, actor: Dictionary, index: int) -> Vector2:
	# Slots stay stable while attacking: sword facing must not rotate the march.
	if follow_direction.is_zero_approx(): follow_direction = Vector2.RIGHT
	var side := follow_direction.orthogonal()
	var leader: Vector2 = game.hero if index == 0 else game.allies[index - 1].p
	var narrow: bool = not game.terrain.is_walkable(actor.p + side * 66.0, 18) or not game.terrain.is_walkable(actor.p - side * 66.0, 18)
	narrow = narrow or not game.terrain.is_walkable(leader + side * 66.0, 18) or not game.terrain.is_walkable(leader - side * 66.0, 18)
	var slot: Vector2 = game.hero - follow_direction * (100.0 + (index / 2) * 95.0) + side * (-64.0 if index % 2 == 0 else 64.0)
	if narrow or not game.terrain.is_walkable(slot, 18):
		# Queue behind the preceding actor, not across a trench from a wide slot.
		var toward: Vector2 = (leader - actor.p).normalized()
		if toward.is_zero_approx(): toward = follow_direction
		return leader - toward * 86.0
	return slot

func prepare_combat_slots(game) -> void:
	# Two side contacts rotate after resolved strikes and a brief dwell; cooldowns are unchanged.
	# Everyone else uses a spaced approach ring, rather than a compressed pile.
	var targets: Array = [{"p": game.hero, "id": "hero", "kind": "hero"}]
	for defender in game.defenders():
		targets.append({"p": defender.p, "id": str(defender.get("view_id", defender.p)), "kind": defender.kind})
	var groups: Dictionary = {}
	for enemy in game.enemies:
		enemy.erase("crowd_approach")
		var swing_age := float(enemy.get("attack_age",-1.0))
		if swing_age < 0.16: enemy["crowd_yield_latched"] = false
		if enemy.get("crowd_contact",false) and swing_age >= 0.20 and game.time - float(enemy.get("crowd_contact_since",game.time)) > 2.0 and float(enemy.get("crowd_landed_at",-1.0)) > float(enemy.get("crowd_last_yield_at",-1.0)):
			enemy["crowd_last_yield_at"] = game.time
			enemy["crowd_yield_until"] = game.time + 1.25
			enemy["crowd_yield_latched"] = true
		if enemy.get("crowd_contact",false) and enemy.has("crowd_slot_target"):
			var gap: float = enemy.p.distance_to(enemy.crowd_slot_target)
			if gap < game.enemy_melee_reach(enemy) + 4.0 and not enemy.has("crowd_contact_since"):
				enemy["crowd_contact_since"] = game.time
			if enemy.has("crowd_contact_since") and (game.time - float(enemy.crowd_contact_since) > 3.0 and swing_age < 0.0):
				enemy["crowd_yield_until"] = game.time + 1.25
				enemy.erase("crowd_contact_since")
		if enemy.hp <= 0 or enemy.kind == "caster" or game.director.is_rising(enemy): continue
		var closest: Dictionary = targets[0]
		for candidate in targets:
			if enemy.p.distance_squared_to(candidate.p) < enemy.p.distance_squared_to(closest.p): closest = candidate
		var engagement_limit := 1100.0 if enemy.has("crowd_slot_target") and enemy.crowd_slot_target.distance_squared_to(closest.p) < 100.0 * 100.0 else 300.0
		if enemy.p.distance_squared_to(closest.p) > engagement_limit * engagement_limit: continue
		enemy["crowd_slot_target"] = closest.p
		if not groups.has(closest.id): groups[closest.id] = {"target": closest.p, "kind": closest.kind, "actors": []}
		groups[closest.id].actors.append(enemy)
	for group in groups.values():
		var target: Vector2 = group.target
		group.actors.sort_custom(func(a,b): return a.p.distance_squared_to(target) + (100000.0 if float(a.get("crowd_yield_until",0)) > game.time else 0.0) - (10000.0 if a.get("crowd_contact",false) else 0.0) < b.p.distance_squared_to(target) + (100000.0 if float(b.get("crowd_yield_until",0)) > game.time else 0.0) - (10000.0 if b.get("crowd_contact",false) else 0.0))
		var slots_used: Dictionary = {}
		for index in range(group.actors.size()):
			var enemy: Dictionary = group.actors[index]
			var slot: Vector2
			enemy["crowd_contact"] = index < 2
			if index >= 2: enemy.erase("crowd_contact_since")
			if index < 2:
				var half := Vector2(40.0 if group.kind == "shield" else 34.8,2.0)
				var quadrants := [Vector2(-1,-1),Vector2(1,-1)]
				var chosen := -1
				var best := INF
				for candidate in range(2):
					if slots_used.has(candidate): continue
					var score: float = enemy.p.distance_squared_to(target + quadrants[candidate] * half)
					if int(enemy.get("crowd_quadrant",-1)) == candidate: score -= 1600.0
					if score < best: best = score; chosen = candidate
				slots_used[chosen] = true
				enemy["crowd_quadrant"] = chosen
				slot = target + quadrants[chosen] * half
				if enemy.kind == "boss": slot = target + Vector2(0, -51.5)
				elif (enemy.p.x - target.x) * quadrants[chosen].x < 8.0:
					# Cross to the assigned side outside the occupied silhouette,
					# rather than projecting an inside-target move onto the wrong arc.
					var arc := target + Vector2(quadrants[chosen].x * 54.0, -132.0 if enemy.p.y < target.y else 132.0)
					if game.terrain.is_walkable(arc, game.enemy_radius(enemy)): slot = arc
			else:
				var rank := index - 2
				var ring := 1
				while rank >= 8 * ring:
					rank -= 8 * ring
					ring += 1
				var angle := TAU * float(rank) / float(8 * ring)
				slot = target + Vector2(cos(angle) * 108.0, sin(angle) * 165.0) * ring
			if game.terrain.is_walkable(slot, game.enemy_radius(enemy)):
				enemy["crowd_approach"] = slot
			elif index >= 2:
				# A blocked waiting slot means wait at the current safe footpoint.
				enemy["crowd_approach"] = enemy.p

func solve(game, dt: float) -> void:
	cells.clear(); bodies.clear(); pair_checks = 0
	var hero_actor := {"p": game.hero, "hp": game.hp, "kind": "hero", "view_id": "hero"}
	_add(hero_actor, 0, 20)
	for actor in game.defenders(): _add(actor, 0, 18)
	for actor in game.enemies: _add(actor, 1, game.enemy_radius(actor), game.director.is_rising(actor))
	# Sweep intended movement against nearby occupied body ellipses before
	# relaxation. Fast actors slide along the boundary instead of tunnelling
	# through a slow convoy; existing overlap may still relax outwards.
	for i in range(bodies.size()):
		var body: Dictionary = bodies[i]
		if body.fixed: continue
		var start: Vector2 = body.p
		var requested: Vector2 = body.actor.p - start
		var steps := maxi(1, ceili(requested.length() / 6.0))
		var step: Vector2 = requested / float(steps)
		for _part in range(steps):
			var motion := step
			var yielded_side := false
			var key := _cell(body.p)
			for _pass in range(2):
				for y in range(-2, 3):
					for x in range(-2, 3):
						for j in cells.get(key + Vector2i(x, y), []):
							if j == i: continue
							var other: Dictionary = bodies[j]
							var axes := _pair_axes(body, other)
							var offset: Vector2 = body.p - other.p
							var current_metric := Vector2(offset.x / axes.x, offset.y / axes.y).length_squared()
							# Opposing streams consistently pass to their own right.
							# This spends the requested motion budget, never extra speed.
							if not yielded_side and current_metric < 1.7 and step.dot(other.intent) < -0.01 and offset.dot(step) < 0.0:
								motion = (motion + step.orthogonal() * 1.25).limit_length(step.length())
								yielded_side = true
							var next_offset: Vector2 = offset + motion
							var next_metric := Vector2(next_offset.x / axes.x, next_offset.y / axes.y).length_squared()
							if next_metric >= minf(1.0, current_metric): continue
							var normal := Vector2(offset.x / (axes.x * axes.x), offset.y / (axes.y * axes.y)).normalized()
							if normal.is_zero_approx(): motion = Vector2.ZERO
							else: motion -= normal * minf(0.0, motion.dot(normal))
			var proposed: Vector2 = game.terrain.move_actor(body.p, motion, body.radius)
			if body.team == 1: proposed = game.constrain_enemy_position(body.actor, proposed)
			var old_key := _cell(body.p)
			var new_key := _cell(proposed)
			body.p = proposed
			if old_key != new_key:
				cells[old_key].erase(i)
				if not cells.has(new_key): cells[new_key] = []
				cells[new_key].append(i)
		body.actor.p = body.p
	for i in range(bodies.size()):
		var a: Dictionary = bodies[i]
		var key := _cell(a.p)
		for y in range(-1, 2):
			for x in range(-1, 2):
				for j in cells.get(key + Vector2i(x, y), []):
					if j <= i: continue
					pair_checks += 1
					_pair(a, bodies[j], dt, i, j)
	for body in bodies:
		if body.fixed: continue
		var actor: Dictionary = body.actor
		var displacement: Vector2 = body.push
		var cap := 14.0 if actor.kind == "hero" else PUSH_SPEED
		displacement = displacement.limit_length(cap * dt)
		# Only sweep from a valid footpoint: never use nearest_open as a teleport.
		if not game.terrain.is_walkable(body.p, body.radius): continue
		var proposed: Vector2 = game.terrain.move_actor(body.p, displacement, body.radius)
		if body.team == 1: proposed = game.constrain_enemy_position(actor, proposed)
		actor.p = proposed
		if proposed.distance_squared_to(body.p) > 0.04: actor["moving"] = true
	game.hero = hero_actor.p
	movement_starts.clear()

func _pair(a: Dictionary, b: Dictionary, dt: float, i: int, j: int) -> void:
	var delta: Vector2 = a.p - b.p
	var distance := delta.length()
	var direction := delta / distance if distance > 0.001 else Vector2.from_angle(float((i * 73 + j * 137) % 360) * PI / 180.0)
	var same_team: bool = a.team == b.team
	var axes := _pair_axes(a, b)
	var metric := Vector2(delta.x / axes.x, delta.y / axes.y).length()
	if metric >= 1.0: return
	var desired := 1.0 / Vector2(direction.x / axes.x, direction.y / axes.y).length()
	var penetration := desired - distance
	var magnitude := minf(PUSH_SPEED * dt, penetration * (0.30 if same_team else 0.40))
	var wa := 0.5
	var wb := 0.5
	if a.actor.kind == "hero": wa = 0.04; wb = 0.96
	if b.actor.kind == "hero": wa = 0.96; wb = 0.04
	if a.fixed: wa = 0.0; wb = 1.0
	if b.fixed: wa = 1.0; wb = 0.0
	a.push += direction * magnitude * wa
	b.push -= direction * magnitude * wb

func _pair_axes(a: Dictionary, b: Dictionary) -> Vector2:
	var same_team: bool = a.team == b.team
	# Terrain radii remain original. Active contacts may approach inside the
	# separately tuned body-aware melee reach.
	var contact := maxf(a.radius, b.radius) + 12.0
	if a.actor.kind == "shield" or b.actor.kind == "shield": contact = maxf(contact, 39.0)
	var visual_axes := Vector2(115.0,205.0) if a.actor.kind == "boss" or b.actor.kind == "boss" else VISUAL_AXES
	var axes := visual_axes if same_team else Vector2(contact, 51.5 if a.actor.kind == "boss" or b.actor.kind == "boss" else 110.0)
	# Two opposite side contacts need a shorter horizontal preference.
	# Preserve full vertical separation while contacts approach or rotate.
	if same_team and a.team == 1 and a.actor.get("crowd_contact",false) and b.actor.get("crowd_contact",false):
		if a.actor.get("crowd_slot_target",Vector2.INF).distance_squared_to(b.actor.get("crowd_slot_target",Vector2.ZERO)) < 1.0:
			axes = Vector2(68.0,132.0)
	if not same_team:
		var enemy: Dictionary = a.actor if a.team == 1 else b.actor
		var defender: Vector2 = b.p if a.team == 1 else a.p
		if enemy.has("crowd_slot_target") and (not enemy.get("crowd_contact",false) or enemy.crowd_slot_target.distance_squared_to(defender) > 75.0 * 75.0):
			axes = visual_axes
	return axes
