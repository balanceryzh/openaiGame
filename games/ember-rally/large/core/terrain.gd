extends RefCounted
# Battlefield geometry is authoritative for drawing, movement, projectiles and AI.
# All coordinates are world coordinates. No actor physics bodies are required.
const WORLD := Vector2(10000, 5500)
const START_POSITION := Vector2(700, 3050)
const BOSS_POSITION := Vector2(9100, 2750)
const DEMON_ENTRANCE_POSITION := Vector2(8490, 2740)
const SIDE_GATE_SPAWN_POSITION := Vector2(9020,3490)
const SIDE_GATE_ROUTE := [Vector2(9020,4300),Vector2(9180,4380),Vector2(8400,4510),Vector2(7560,4400),Vector2(7620,2740)]
const DRAWBRIDGE_RECT := Rect2(7820, 2470, 360, 540)
const PLAY_RECT := Rect2(20, 90, 9960, 5390)
const CELL := 40.0
const DISCOVERY_RADIUS := 310.0
const CAMP_POSITIONS := [Vector2(1050,2430), Vector2(1620,2330), Vector2(1170,3370), Vector2(1770,3260)]
const DISTRICT_NAMES := ["残帆人类营地", "破阵战场", "焦土围城战场", "恶魔木垒"]
const STAGE_CENTERS := [Vector2(1420,2800), Vector2(3700,2800), Vector2(6250,2880), Vector2(9020,2800)]
const SPATIAL_CELL := 256.0
var bridge_progress := 0.0
var bridge_open := false
var navigation_revision := 0
var blockers: Array[Dictionary] = []
var landmarks: Array[Dictionary] = []
var routes: Array[PackedVector2Array] = []
var bridges: Array[Rect2] = []
var grids: Dictionary = {}
var explored: Dictionary = {}
var last_hero := START_POSITION
var blocker_buckets: Dictionary = {}
var indexed_blocker_count := -1
var nav_rebuilds := 0
var path_budget := -1
var paths_this_frame := 0
const MAX_PATH_REBUILDS_PER_FRAME := 8

func begin_frame() -> void:
	path_budget=MAX_PATH_REBUILDS_PER_FRAME
	paths_this_frame=0

func _init() -> void:
	_build_layout()
	_build_spatial_index()
	_build_grid(18)
	_build_grid(36)

func reset() -> void:
	set_bridge_progress(0.0)
	explored.clear()
	last_hero = START_POSITION

func set_main_bridge_open(value: bool) -> void:
	set_bridge_progress(1.0 if value else 0.0)

func set_bridge_progress(value: float) -> void:
	bridge_progress = clampf(value,0.0,1.0)
	var now_open := bridge_progress >= 1.0
	if now_open == bridge_open: return
	bridge_open = now_open
	for i in range(blockers.size()-1,-1,-1):
		if blockers[i].kind == "raised_drawbridge": blockers.remove_at(i)
	if not bridge_open: _add("raised_drawbridge",DRAWBRIDGE_RECT.position.x,DRAWBRIDGE_RECT.position.y,DRAWBRIDGE_RECT.size.x,DRAWBRIDGE_RECT.size.y)
	invalidate_navigation()

func invalidate_navigation() -> void:
	# Actor path caches use this revision, including actors off-screen at the change.
	navigation_revision += 1
	_build_spatial_index()
	grids.clear()

func safe_side_gate_spawn(offset := Vector2.ZERO, radius := 18.0, avoid: Array = []) -> Vector2:
	return safe_spawn(SIDE_GATE_SPAWN_POSITION+offset,radius,avoid)

func _add(kind: String, x: float, y: float, w: float, h: float) -> void:
	blockers.append({"kind":kind, "rect":Rect2(x,y,w,h)})

func _build_layout() -> void:
	# Four connected west-to-east stages in the SAME 10000 x 5500 world.
	# The camps have wooden fences and torn canvas; only the two middle
	# battlefields contain trenches only as defensive lines. No fence or masonry belts.
	# 1. Broken human encampment: an uneven perimeter with broad visible breaches.
	for r in [Rect2(430,1710,470,54),Rect2(900,1490,480,54),Rect2(1390,1670,570,54),Rect2(1960,1730,54,430),Rect2(2200,2210,54,320),Rect2(2200,3100,54,440),Rect2(1930,3650,54,430),Rect2(1450,4050,520,54),Rect2(570,3820,530,54),Rect2(370,3210,54,540),Rect2(370,2020,54,450)]:
		_add("palisade",r.position.x,r.position.y,r.size.x,r.size.y)
	# These footprints are the actual ground-contact canvas and broken frames.
	for r in [Rect2(680,1900,285,235),Rect2(1250,1860,320,230),Rect2(1750,2190,270,205),Rect2(600,3440,280,225),Rect2(1340,3570,310,230),Rect2(1830,3370,270,225),Rect2(570,2590,250,185)]:
		_add("tent",r.position.x,r.position.y,r.size.x,r.size.y)
	_add("wagon",1790,2850,165,85)
	_add("wagon",940,3690,150,75)
	_add("wagon",1120,1730,160,80)
	# 2. Broken battle line: offset firing trenches and interrupted side arms.
	for r in [Rect2(2740,1510,950,105),Rect2(2740,1510,105,430),Rect2(4020,1710,690,105),Rect2(4605,1710,105,480),Rect2(3030,3500,770,105),Rect2(3695,3500,105,470),Rect2(4260,3870,630,110),Rect2(2820,4470,920,105),Rect2(2820,4190,105,280)]:
		_add("trench",r.position.x,r.position.y,r.size.x,r.size.y)
	_add("wagon",2900,2600,185,85)
	_add("wagon",3820,2980,180,84)
	_add("wagon",4570,3200,175,82)
	_add("wagon",3910,4630,190,88)
	# 3. Scorched siege ground: only short zig-zag excavations, with corpses
	# and wrecked supply carts. No above-ground walls, fences or chevaux-de-frise.
	for r in [Rect2(5210,1180,830,110),Rect2(5930,1180,110,450),Rect2(6430,1610,700,110),Rect2(7020,1270,110,340),Rect2(5390,3580,900,115),Rect2(5390,3580,115,440),Rect2(6590,3760,770,110),Rect2(7250,3440,110,320),Rect2(5960,4590,850,110)]:
		_add("trench",r.position.x,r.position.y,r.size.x,r.size.y)
	_add("wagon",5160,3060,180,84)
	_add("wagon",6370,2470,195,90)
	_add("wagon",6880,3070,180,82)
	_add("wagon",6030,3960,190,86)
	# 4. Demon camp: a real entrance ravine, a wide lowerable deck, and
	# staggered wooden perimeter. The south breach is deliberate and visible.
	_add("moat",7840,1320,290,1150)
	_add("moat",7840,3010,290,1190)
	bridges.append(DRAWBRIDGE_RECT)
	_add("raised_drawbridge",7820,2470,360,540)
	for r in [Rect2(8130,1320,66,1150),Rect2(8130,3010,66,1190),Rect2(8196,1320,700,66),Rect2(8896,1140,700,66),Rect2(8896,1140,66,246),Rect2(9530,1206,66,430),Rect2(9690,1636,66,1960),Rect2(9530,1570,226,66),Rect2(9530,3596,226,66),Rect2(9530,3662,66,540),Rect2(8196,4136,694,66),Rect2(9440,4136,90,66)]:
		_add("palisade",r.position.x,r.position.y,r.size.x,r.size.y)
	_add("tent",8430,1580,350,270)
	_add("tent",9060,1450,330,250)
	_add("tent",8450,3610,330,255)
	_add("tent",9130,3720,270,220)
	_add("wagon",9300,2050,200,90)
	_add("wagon",8400,3230,195,90)
	# Sparse abandoned wagons mark optional outer flanks without fences.
	_add("wagon",1410,850,175,80)
	_add("wagon",1630,4660,165,80)
	# Roads bend around authored cover. Middle lanes and outer flanks reconnect
	# before the 540px-wide bridge; all centerlines and troop margins are clear.
	routes.append(PackedVector2Array([START_POSITION,Vector2(1130,2810),Vector2(1720,2720),Vector2(2370,2760),Vector2(3050,3000),Vector2(3630,2750),Vector2(4440,2850),Vector2(4950,2700),Vector2(5650,2780),Vector2(6150,2980),Vector2(7000,2770),Vector2(7620,2740),Vector2(8000,2740),DEMON_ENTRANCE_POSITION,BOSS_POSITION]))
	routes.append(PackedVector2Array([Vector2(1130,2810),CAMP_POSITIONS[0],Vector2(1170,2230),CAMP_POSITIONS[1],Vector2(1720,2720)]))
	routes.append(PackedVector2Array([Vector2(1130,2810),CAMP_POSITIONS[2],Vector2(1540,3330),CAMP_POSITIONS[3],Vector2(1560,3010),Vector2(1720,2720)]))
	routes.append(PackedVector2Array([Vector2(2370,2760),Vector2(2470,2120),Vector2(2560,1210),Vector2(3400,1280),Vector2(3910,1390),Vector2(4900,1440),Vector2(5100,1830),Vector2(5720,1850),Vector2(6200,1790),Vector2(6530,1830),Vector2(7400,1930),Vector2(7620,2740)]))
	routes.append(PackedVector2Array([Vector2(2370,2760),Vector2(2580,3550),Vector2(2930,3940),Vector2(3370,4110),Vector2(3980,4180),Vector2(4200,3650),Vector2(4920,3430),Vector2(5140,4100),Vector2(5680,4270),Vector2(6440,4170),Vector2(6950,4070),Vector2(7460,4070),Vector2(7520,3690),Vector2(7620,2740)]))
	routes.append(PackedVector2Array([Vector2(3630,2750),Vector2(3470,2490),Vector2(3460,1810),Vector2(3820,1810),Vector2(3910,1390)]))
	routes.append(PackedVector2Array([Vector2(4440,2850),Vector2(4920,3090),Vector2(4920,3430)]))
	routes.append(PackedVector2Array([Vector2(6150,2980),Vector2(6270,3160),Vector2(6390,3530),Vector2(6440,4170)]))
	routes.append(PackedVector2Array([Vector2(7620,2740),Vector2(7560,4400),Vector2(8400,4510),Vector2(9180,4380),Vector2(9020,4300),Vector2(9020,3490),BOSS_POSITION]))
	landmarks = [
		{"p":STAGE_CENTERS[0],"label":DISTRICT_NAMES[0],"kind":"human_camp","stage":0},
		{"p":STAGE_CENTERS[1],"label":DISTRICT_NAMES[1],"kind":"battlefield","stage":1},
		{"p":STAGE_CENTERS[2],"label":DISTRICT_NAMES[2],"kind":"siege","stage":2},
		{"p":STAGE_CENTERS[3],"label":DISTRICT_NAMES[3],"kind":"demon_camp","stage":3},
		{"p":Vector2(8000,2740),"label":"恶魔营地吊桥","kind":"drawbridge","stage":3},
		{"p":Vector2(6240,1420),"label":"北侧壕沟绕行道","kind":"route","stage":2},
		{"p":Vector2(3670,1180),"label":"北部进军道","kind":"route","stage":1}
	]

func stage_index_at(p: Vector2) -> int:
	return 0 if p.x < 2500.0 else 1 if p.x < 5000.0 else 2 if p.x < 7500.0 else 3

func corpse_density_at(p: Vector2) -> float:
	# Read-only dressing hint; the corpse ecology owns all actual source creation.
	return [1.0,3.0,4.0,1.0][stage_index_at(p)]

func _build_spatial_index() -> void:
	blocker_buckets.clear()
	indexed_blocker_count = blockers.size()
	for index in range(blockers.size()):
		var r: Rect2 = blockers[index].rect
		var first := Vector2i((r.position/SPATIAL_CELL).floor())
		var last := Vector2i((r.end/SPATIAL_CELL).floor())
		for y in range(first.y,last.y+1):
			for x in range(first.x,last.x+1):
				var cell := Vector2i(x,y)
				if not blocker_buckets.has(cell): blocker_buckets[cell] = []
				blocker_buckets[cell].append(index)

func is_blocked(p: Vector2, radius: float = 18.0) -> bool:
	# Legacy test arenas and runtime editors may clear/append blockers directly.
	# Refresh on count changes so stale bucket indices can never reach movement.
	if indexed_blocker_count != blockers.size():
		invalidate_navigation()
	if not p.is_finite(): return true
	if p.x < PLAY_RECT.position.x+radius or p.x > PLAY_RECT.end.x-radius or p.y < PLAY_RECT.position.y+radius or p.y > PLAY_RECT.end.y-radius: return true
	# Only inspect nearby cover during movement, even on the expanded map.
	var padding := Vector2.ONE*(radius+0.4)
	var first := Vector2i(((p-padding)/SPATIAL_CELL).floor())
	var last := Vector2i(((p+padding)/SPATIAL_CELL).floor())
	for y in range(first.y,last.y+1):
		for x in range(first.x,last.x+1):
			for index in blocker_buckets.get(Vector2i(x,y),[]):
				var r: Rect2 = blockers[index].rect
				if r.grow(radius+0.4).has_point(p): return true
	return false

func is_walkable(p: Vector2, radius: float = 18.0) -> bool:
	return not is_blocked(p,radius)

func _clamp_actor(p: Vector2, radius: float) -> Vector2:
	return p.clamp(PLAY_RECT.position+Vector2.ONE*(radius+0.1), PLAY_RECT.end-Vector2.ONE*(radius+0.1))

func move_actor(p: Vector2, displacement: Vector2, radius: float = 18.0) -> Vector2:
	# Small swept steps avoid tunnelling even with knockback or unusually long dt.
	p = _clamp_actor(p,radius)
	if is_blocked(p,radius): p = nearest_open(p,radius)
	var steps := maxi(1, int(ceil(displacement.length()/6.0)))
	var delta := displacement/float(steps)
	for _step in range(steps):
		var candidate := _clamp_actor(p+delta,radius)
		if not is_blocked(candidate,radius):
			p = candidate
		else:
			# Sliding along walls never changes the actor's intended speed upwards.
			var px := _clamp_actor(p+Vector2(delta.x,0),radius)
			if not is_blocked(px,radius): p = px
			var py := _clamp_actor(p+Vector2(0,delta.y),radius)
			if not is_blocked(py,radius): p = py
	return p

func nearest_open(p: Vector2, radius: float = 18.0) -> Vector2:
	var origin := _clamp_actor(p,radius)
	if not is_blocked(origin,radius): return origin
	for ring in range(1,181):
		var distance := float(ring)*8.0
		for sample in range(24):
			var candidate := _clamp_actor(origin+Vector2.from_angle(sample*TAU/24.0)*distance,radius)
			if not is_blocked(candidate,radius): return candidate
	return START_POSITION

func _segment_hits_rect(from: Vector2, to: Vector2, rect: Rect2) -> bool:
	# Slab clipping, including contact, prevents projectiles crossing thin walls.
	var delta := to-from
	var t_min := 0.0
	var t_max := 1.0
	for axis in range(2):
		if absf(delta[axis]) < 0.0001:
			if from[axis] < rect.position[axis] or from[axis] > rect.end[axis]: return false
		else:
			var a: float = (rect.position[axis]-from[axis])/delta[axis]
			var b: float = (rect.end[axis]-from[axis])/delta[axis]
			if a > b:
				var swap := a; a = b; b = swap
			t_min = maxf(t_min,a); t_max = minf(t_max,b)
			if t_min > t_max: return false
	return true

func _segment_cover_intersects(from: Vector2, to: Vector2, radius: float, ignore_trenches: bool = false) -> bool:
	# Local actors and arrows inspect only the chunks touched by their segment.
	# Long strategic routes use one linear pass instead of thousands of empty cells.
	if indexed_blocker_count != blockers.size():
		invalidate_navigation()
	var padding := radius if ignore_trenches else radius+0.4
	var bounds := Rect2(from,Vector2.ZERO).expand(to).grow(maxf(0.001,padding))
	var first := Vector2i((bounds.position/SPATIAL_CELL).floor())
	var last := Vector2i((bounds.end/SPATIAL_CELL).floor())
	if (last.x-first.x+1)*(last.y-first.y+1)>64:
		for b in blockers:
			if ignore_trenches and b.kind in ["trench","moat"]: continue
			if b.rect.intersects(bounds,true) and _segment_hits_rect(from,to,b.rect.grow(padding)): return true
		return false
	var seen: Dictionary = {}
	for y in range(first.y,last.y+1):
		for x in range(first.x,last.x+1):
			for index in blocker_buckets.get(Vector2i(x,y),[]):
				if seen.has(index): continue
				seen[index] = true
				var b: Dictionary = blockers[index]
				if ignore_trenches and b.kind in ["trench","moat"]: continue
				if b.rect.intersects(bounds,true) and _segment_hits_rect(from,to,b.rect.grow(padding)): return true
	return false

func has_line_of_sight(from: Vector2, to: Vector2, radius: float = 0.0) -> bool:
	if is_blocked(from,radius) or is_blocked(to,radius): return false
	return not _segment_cover_intersects(from,to,radius)

func projectile_blocked(from: Vector2, to: Vector2, radius: float = 3.0) -> bool:
	# Arrows and fireballs can cross ditches, but solid cover intercepts them.
	if not from.is_finite() or not to.is_finite() or not PLAY_RECT.has_point(to): return true
	# Match the original projectile footprint; sight adds a 0.4px safety margin.
	return _segment_cover_intersects(from,to,radius,true)

func _grid_radius(radius: float) -> int:
	return 18 if radius <= 18.0 else 36 if radius <= 36.0 else int(ceil(radius))

func _build_grid(radius: int) -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0,0,int(ceil(WORLD.x/CELL)),int(ceil(WORLD.y/CELL)))
	grid.cell_size = Vector2.ONE*CELL
	grid.offset = Vector2.ONE*CELL*0.5
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	# Rasterize each inflated AABB directly. A large map must not scan every
	# blocker for every navigation node (O(nodes * blockers)).
	var lo := PLAY_RECT.position+Vector2.ONE*radius
	var hi := PLAY_RECT.end-Vector2.ONE*radius
	for y in range(grid.region.size.y):
		for x in range(grid.region.size.x):
			var point := Vector2(x,y)*CELL+Vector2.ONE*CELL*0.5
			if point.x<lo.x or point.y<lo.y or point.x>hi.x or point.y>hi.y:
				grid.set_point_solid(Vector2i(x,y),true)
	for blocker in blockers:
		var rect: Rect2 = blocker.rect.grow(float(radius)+0.4)
		var first := Vector2i(((rect.position-Vector2.ONE*CELL*0.5)/CELL).ceil())
		var end := Vector2i(((rect.end-Vector2.ONE*CELL*0.5)/CELL).ceil())
		var cells := Rect2i(first,end-first).intersection(grid.region)
		if cells.has_area(): grid.fill_solid_region(cells,true)
	grids[radius] = grid
	return grid

func _nearest_cell(p: Vector2, grid: AStarGrid2D, radius: float, require_visible: bool) -> Vector2i:
	var base := Vector2i(floor(p.x/CELL),floor(p.y/CELL))
	var best := Vector2i(-1,-1)
	var best_distance := INF
	for ring in range(0,12):
		for y in range(base.y-ring,base.y+ring+1):
			for x in range(base.x-ring,base.x+ring+1):
				if ring>0 and absi(x-base.x)!=ring and absi(y-base.y)!=ring: continue
				var id := Vector2i(x,y)
				if not grid.region.has_point(id) or grid.is_point_solid(id): continue
				var point := grid.get_point_position(id)
				var distance := p.distance_squared_to(point)
				if distance < best_distance and (not require_visible or has_line_of_sight(p,point,radius)):
					best = id; best_distance = distance
		if best.x>=0: return best
	return best

func find_path(from: Vector2, to: Vector2, radius: float = 18.0) -> PackedVector2Array:
	var start := nearest_open(from,radius)
	var finish := nearest_open(to,radius)
	if has_line_of_sight(start,finish,radius): return PackedVector2Array([finish])
	var clearance := _grid_radius(radius)
	var grid: AStarGrid2D = grids[clearance] if grids.has(clearance) else _build_grid(clearance)
	var from_id := _nearest_cell(start,grid,radius,true)
	var to_id := _nearest_cell(finish,grid,radius,true)
	if from_id.x<0 or to_id.x<0: return PackedVector2Array()
	var raw := grid.get_point_path(from_id,to_id)
	if raw.is_empty(): return raw
	if has_line_of_sight(raw[-1],finish,radius): raw.append(finish)
	# Greedy string-pulling keeps the squad flowing through broad, readable turns.
	var result := PackedVector2Array()
	var anchor := start
	var index := 0
	while index < raw.size():
		var farthest := index
		for next in range(raw.size()-1,index-1,-1):
			if has_line_of_sight(anchor,raw[next],radius):
				farthest = next
				break
		if not has_line_of_sight(anchor,raw[farthest],radius): return PackedVector2Array()
		result.append(raw[farthest]); anchor = raw[farthest]; index = farthest+1
	nav_rebuilds += 1
	return result

func steer_actor(actor: Dictionary, target: Vector2, dt: float, speed: float, radius: float = 18.0) -> Vector2:
	var p: Vector2 = actor.p
	if int(actor.get("_terrain_revision",-1)) != navigation_revision:
		actor["_terrain_path"] = PackedVector2Array()
		actor["_terrain_timer"] = 0.0
		actor["_terrain_revision"] = navigation_revision
	if speed == 0.0: return move_actor(p,Vector2.ZERO,radius)
	if speed < 0.0:
		return move_actor(p,(p-target).normalized()*absf(speed)*dt,radius)
	var goal := nearest_open(target,radius)
	if has_line_of_sight(p,goal,radius):
		actor["_terrain_path"] = PackedVector2Array()
		return move_actor(p,(goal-p).limit_length(speed*dt),radius)
	var remaining := float(actor.get("_terrain_timer",0.0))-dt
	var old_goal: Vector2 = actor.get("_terrain_goal",Vector2.INF)
	var path: PackedVector2Array = actor.get("_terrain_path",PackedVector2Array())
	if remaining<=0.0 or old_goal.distance_to(goal)>90.0 or path.is_empty():
		if path_budget!=0:
			if path_budget>0:path_budget-=1
			paths_this_frame+=1
			path = find_path(p,goal,radius)
			actor["_terrain_goal"] = goal
			remaining = 0.8
	actor["_terrain_timer"] = remaining
	while not path.is_empty() and p.distance_to(path[0]) < 9.0: path.remove_at(0)
	if path.size()>1 and has_line_of_sight(p,path[1],radius): path.remove_at(0)
	actor["_terrain_path"] = path
	if path.is_empty(): return p
	return move_actor(p,(path[0]-p).limit_length(speed*dt),radius)

func safe_spawn(candidate: Vector2, radius: float = 18.0, avoid: Array = [], min_distance: float = 90.0) -> Vector2:
	candidate = _clamp_actor(candidate,radius)
	if _spawn_clear(candidate,radius,avoid,min_distance): return candidate
	for ring in range(1,61):
		var distance := float(ring)*24.0
		for sample in range(24):
			var p := _clamp_actor(candidate+Vector2.from_angle(sample*TAU/24.0)*distance,radius)
			if _spawn_clear(p,radius,avoid,min_distance): return p
	# Return an explicit failure instead of silently spawning on top of an actor.
	return Vector2.INF

func _spawn_clear(p: Vector2, radius: float, avoid: Array, min_distance: float) -> bool:
	if is_blocked(p,radius): return false
	for actor in avoid:
		var point: Vector2 = actor if actor is Vector2 else actor.get("p",Vector2.INF)
		if p.distance_to(point)<min_distance: return false
	return true

func update_discoveries(hero: Vector2, camps: Array) -> Array:
	last_hero = hero
	var newly_discovered: Array = []
	for i in range(camps.size()):
		var camp: Dictionary = camps[i]
		if not camp.get("discovered",false) and hero.distance_to(camp.p)<=DISCOVERY_RADIUS and has_line_of_sight(hero,camp.p):
			camp["discovered"] = true
			newly_discovered.append(i)
	var origin := Vector2i(hero/100.0)
	for y in range(-4,5):
		for x in range(-4,5):
			var cell := origin+Vector2i(x,y)
			var center := Vector2(cell)*100.0+Vector2(50,50)
			if Rect2(Vector2.ZERO,WORLD).has_point(center) and hero.distance_to(center)<=DISCOVERY_RADIUS+70.0: explored[cell] = true
	return newly_discovered

func _visible(rect: Rect2, camera: Vector2,view_size:Vector2=Vector2(1280,720)) -> bool:
	return rect.grow(70).intersects(Rect2(camera,view_size))

func draw_world(owner: Node2D, camera: Vector2, time: float,view_size:Vector2=Vector2(1280,720)) -> void:
	# Dusty paths lie under all cover. Dark lips make impassable edges explicit.
	for path in routes:
		var points := PackedVector2Array()
		for point in path: points.append(point-camera)
		owner.draw_polyline(points,Color("303329"),104,true)
		owner.draw_polyline(points,Color("3b3b2e"),74,true)
		owner.draw_polyline(points,Color(0.27,0.26,0.20,0.36),24,true)
	for bridge in bridges:
		if not _visible(bridge,camera,view_size): continue
		var r := Rect2(bridge.position-camera,bridge.size)
		owner.draw_rect(r,Color("4a4433") if bridge_open else Color("171b1d"))
		if not bridge_open: continue
		for y in range(int(r.position.y),int(r.end.y),14):
			owner.draw_line(Vector2(r.position.x,y),Vector2(r.end.x,y),Color("70634a"),4)
		owner.draw_line(r.position,r.position+Vector2(0,r.size.y),Color("9c8659"),5)
		owner.draw_line(Vector2(r.end.x,r.position.y),r.end,Color("9c8659"),5)
	for b in blockers:
		if b.kind == "raised_drawbridge": continue
		var world_rect: Rect2 = b.rect
		if not _visible(world_rect,camera,view_size): continue
		var r := Rect2(world_rect.position-camera,world_rect.size)
		if b.kind in ["trench","moat"]: _draw_trench(owner,r)
		elif b.kind == "wall": _draw_wall(owner,r)
		elif b.kind == "wagon": _draw_wagon(owner,r)
		else: _draw_barricade(owner,r)
	for landmark in landmarks:
		var p: Vector2 = landmark.p-camera
		if not Rect2(Vector2.ZERO,view_size).grow(130).has_point(p):continue
		_draw_landmark(owner,p,landmark.kind,time)
		# Location names are found in the world, never disclosed as remote pins.
		if last_hero.distance_to(landmark.p)<460:
			owner.txt(p+Vector2(-70,-116),landmark.label,16,Color("bdb698"))

func _draw_trench(owner: Node2D, r: Rect2) -> void:
	owner.draw_rect(r.grow(10),Color("474535"))
	owner.draw_rect(r,Color("101917"))
	owner.draw_rect(Rect2(r.position+Vector2(0,12),r.size-Vector2(0,17)),Color("17221d"))
	owner.draw_line(r.position,r.position+Vector2(r.size.x,0),Color("72705a"),5)
	owner.draw_line(Vector2(r.position.x,r.end.y),r.end,Color("665943"),7)
	for x in range(int(r.position.x)+12,int(r.end.x)-6,31):
		owner.draw_line(Vector2(x,r.position.y+4),Vector2(x+8,r.position.y+22),Color("504e3d"),4)
		owner.draw_line(Vector2(x+7,r.end.y-3),Vector2(x+1,r.end.y-18),Color("3d3a2c"),4)

func _draw_wall(owner: Node2D, r: Rect2) -> void:
	owner.draw_rect(Rect2(r.position+Vector2(10,12),r.size),Color(0.025,0.035,0.03,0.4))
	owner.draw_rect(r,Color("454a43"))
	owner.draw_rect(Rect2(r.position,r.size-Vector2(0,10)),Color("626558"))
	owner.draw_line(r.position,r.position+Vector2(r.size.x,0),Color("8a8871"),3)
	for x in range(int(r.position.x)+18,int(r.end.x),38):
		owner.draw_line(Vector2(x,r.position.y),Vector2(x-6,r.end.y-7),Color("3b433c"),2)
	for y in range(int(r.position.y)+22,int(r.end.y)-5,25):
		owner.draw_line(Vector2(r.position.x,y),Vector2(r.end.x,y),Color("42483e"),2)
	# Cracks and fallen stone stay inside the collision footprint.
	var center := r.get_center()
	owner.draw_polyline(PackedVector2Array([center+Vector2(-13,-12),center+Vector2(-3,0),center+Vector2(-9,11),center+Vector2(9,17)]),Color("303a34"),3,true)

func _draw_barricade(owner: Node2D, r: Rect2) -> void:
	owner.draw_rect(r,Color("343c2f"))
	var horizontal := r.size.x>r.size.y
	var count := int((r.size.x if horizontal else r.size.y)/22.0)
	for n in range(count):
		var p := r.position+Vector2(12+n*22,0) if horizontal else r.position+Vector2(0,12+n*22)
		var end := p+Vector2(0,r.size.y) if horizontal else p+Vector2(r.size.x,0)
		owner.draw_line(p,end,Color("786a4d"),10)
		owner.draw_line(p+Vector2(3,0),end+Vector2(3,0),Color("a28b60"),2)
	owner.draw_line(r.position+Vector2(4,7),r.end-Vector2(4,7),Color("463a2b"),7)
	owner.draw_line(Vector2(r.position.x+4,r.end.y-7),Vector2(r.end.x-4,r.position.y+7),Color("8b7853"),5)

func _draw_wagon(owner: Node2D, r: Rect2) -> void:
	owner.draw_rect(r.grow(7),Color(0.035,0.04,0.03,0.45))
	owner.draw_rect(r,Color("564b37"))
	for y in range(int(r.position.y)+6,int(r.end.y),12): owner.draw_line(Vector2(r.position.x+5,y),Vector2(r.end.x-5,y),Color("8a7450"),4)
	owner.draw_line(r.position+Vector2(15,0),r.end-Vector2(14,0),Color("332e25"),8)
	for p in [r.position+Vector2(24,14),r.end-Vector2(24,14)]:
		owner.draw_arc(p,20,0,TAU,16,Color("aaa081"),4)
		for j in range(4): owner.draw_line(p-Vector2.from_angle(j*PI/4)*18,p+Vector2.from_angle(j*PI/4)*18,Color("665640"),3)

func _draw_landmark(owner: Node2D, p: Vector2, kind: String, time: float) -> void:
	if kind == "gate":
		owner.draw_arc(p+Vector2(0,40),145,0,PI,32,Color("827655"),5)
		owner.draw_line(p+Vector2(-88,4),p+Vector2(-88,-58),Color("878571"),6)
		owner.draw_line(p+Vector2(88,4),p+Vector2(88,-58),Color("878571"),6)
		return
	# Landmarks are nonblocking small props outside the rescue interaction circle.
	var q := p+Vector2(-72,-72)
	if kind in ["flag","cart"]:
		owner.draw_line(q+Vector2(0,20),q+Vector2(0,-45),Color("a19677"),4)
		var sway := sin(time*2.1+p.x)*4.0
		owner.draw_colored_polygon(PackedVector2Array([q+Vector2(1,-44),q+Vector2(35,-39+sway),q+Vector2(22,-22+sway),q+Vector2(1,-25)]),Color("778a75"))
		owner.draw_line(q+Vector2(10,-37),q+Vector2(10,-27),Color("c8bd87"),3)
	elif kind == "fire":
		owner.draw_circle(q,19,Color("20271f"))
		owner.draw_circle(q,10+sin(time*4)*2,Color("9a6335"))
		owner.draw_circle(q+Vector2(1,-5),5,Color("e1a55a"))
	else:
		owner.draw_rect(Rect2(q-Vector2(16,8),Vector2(32,20)),Color("737867"))
		owner.draw_line(q+Vector2(0,3),q+Vector2(0,-46),Color("9a9d84"),9)
		owner.draw_line(q+Vector2(-17,-28),q+Vector2(17,-28),Color("9a9d84"),8)

func camp_marker_color(camp: Dictionary) -> Color:
	var status: String = camp.get("status","rescued" if camp.get("rescued",false) else "dormant")
	if status=="dead": return Color("71746f")
	if status=="rescued": return Color("77ac83")
	if status=="cleared": return Color("badf96")
	if status=="active":
		var fighter: Dictionary = camp.get("fighter",{})
		if float(fighter.get("hp",1.0))<=float(fighter.get("max",1.0))*0.30: return Color("f06d58")
		return Color("f2ba65")
	return Color("e6c783")

func draw_exploration(owner: Node2D, _camera: Vector2, camps: Array) -> void:
	# Fogged survey map: no exact pins for undiscovered survivors.
	var frame := Rect2(1080,171,179,177)
	owner.panel(frame,Color(0.04,0.07,0.075,0.91))
	owner.txt(frame.position+Vector2(11,21),"战地手图     北 ↑",13,Color("c0b88e"))
	var available := Vector2(154,133)
	var unit_scale := minf(available.x/WORLD.x,available.y/WORLD.y)
	var scale := Vector2.ONE*unit_scale
	var map_size := WORLD*unit_scale
	var origin := frame.position+Vector2(12,30)+(available-map_size)*0.5
	owner.draw_rect(Rect2(origin,map_size),Color("111c1c"))
	for cell in explored:
		owner.draw_rect(Rect2(origin+Vector2(cell)*100*scale,Vector2(100,100)*scale),Color("354337"))
	for b in blockers:
		var r: Rect2 = b.rect
		var cell := Vector2i(r.get_center()/100.0)
		if explored.has(cell): owner.draw_rect(Rect2(origin+r.position*scale,r.size*scale),Color("807963") if b.kind!="trench" else Color("0b1313"))
	for camp in camps:
		if not camp.get("discovered",false): continue
		var marker: Vector2 = origin+camp.p*scale
		var color := camp_marker_color(camp)
		if camp.get("status","")=="dead":
			owner.draw_line(marker-Vector2(3,3),marker+Vector2(3,3),color,1.5)
			owner.draw_line(marker+Vector2(-3,3),marker+Vector2(3,-3),color,1.5)
		else:
			owner.draw_circle(marker,3.0,color)
			if camp.get("status","")=="active": owner.draw_arc(marker,5,0,TAU,12,color,1)
	var hero := origin+last_hero*scale
	owner.draw_circle(hero,4.0,Color("9ddcd5"))
	owner.draw_arc(hero,7,0,TAU,12,Color(0.6,0.86,0.82,0.4),1)
