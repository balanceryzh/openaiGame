extends Node3D
## Full-map native HD-2D presentation. Core positions stay authoritative pixels.
## This root owns no combat simulation, damage, spawn clock or difficulty override.
const PX_PER_UNIT := 50.0
const Logic = preload("res://large/battle_logic.gd")
const TerrainWorld = preload("res://large/terrain_world.gd")
const Visuals = preload("res://large/visuals.gd")
var logic: Node2D
var terrain: Node3D
var visuals: Node3D
var camera: Camera3D
var camera_target := Vector3.ZERO
var render_view_rect2d := Rect2()
var bound_terrain: RefCounted
var actor_views: Dictionary:
	get: return visuals.actor_views if is_instance_valid(visuals) else {}
var ready_complete := false
var review_region := ""
var review_boss_delay := 0.0
var demo_seconds := -1.0
var demo_wall := 0.0
var metrics_path := ""
var sample_frames: Array[float] = []
var finishing := false
var started_usec := 0
var last_frame_usec := 0
var total_frame_count := 0
var wall_frame_samples: Array[float] = []
var peak_visible_actor_count := 0
var peak_visible_source_count := 0
var terrain_world: Node3D:
	get: return terrain

func _ready() -> void:
	started_usec=Time.get_ticks_usec()
	last_frame_usec=started_usec
	process_priority = 20
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--large-review="):review_region=arg.get_slice("=",1)
		elif arg=="--large-review":review_region="1"
		elif arg.begins_with("--review-boss-delay="):review_boss_delay=float(arg.get_slice("=",1))
		elif arg.begins_with("--demo-seconds="):demo_seconds=float(arg.get_slice("=",1))
		elif arg.begins_with("--metrics="):metrics_path=arg.trim_prefix("--metrics=")
	_setup_environment()
	camera = Camera3D.new()
	camera.name = "HighBattlefieldCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 29.0
	camera.near = 0.1
	camera.far = 160.0
	camera.current = true
	add_child(camera)
	camera_target = Vector3(26,0,92)
	_position_camera()
	render_view_rect2d = _camera_ground_rect()
	logic = Logic.new()
	logic.name = "AuthoritativeBattleLogic"
	logic.view_adapter = self
	logic.render_view_rect2d = render_view_rect2d
	add_child(logic)
	_build_terrain()
	if not review_region.is_empty():
		var destination:Vector2=logic.BOSS_POSITION+Vector2(0,320) if review_region=="boss" else logic.camps[clampi(int(review_region)-1,0,logic.camps.size()-1)].p+Vector2(0,180)
		logic.hero=logic.terrain.nearest_open(destination,20)
		logic.state="play"
		logic.corpse_field.prime(logic.hero,Rect2(logic.hero-Vector2(1300,900),Vector2(2600,1800)),0.0)
		if review_region=="boss" and review_boss_delay<=0:logic.spawn_boss()
	visuals = Visuals.new()
	visuals.name = "StreamedBattlefieldVisuals"
	add_child(visuals)
	visuals.setup(self)
	_update_camera(0.0,true)
	terrain.update_view(logic.hero,logic.time,render_view_rect2d)
	visuals.sync(logic,render_view_rect2d)
	ready_complete = true
	last_frame_usec=Time.get_ticks_usec()
	_update_peaks()

func _setup_environment() -> void:
	var world := WorldEnvironment.new()
	world.name = "DuskAtmosphere"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("202b40")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("adbad4")
	env.ambient_light_energy = 0.48
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("687b90")
	env.fog_light_energy = 0.32
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.0
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.name = "EveningSun"
	sun.rotation_degrees = Vector3(-49,-33,0)
	sun.light_color = Color("dec2a7")
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 75.0
	sun.shadow_bias = 0.07
	sun.shadow_normal_bias = 1.4
	add_child(sun)

func _build_terrain() -> void:
	if is_instance_valid(terrain):
		remove_child(terrain)
		terrain.queue_free()
	terrain = TerrainWorld.new()
	terrain.name = "FullMapStreamedTerrain"
	add_child(terrain)
	bound_terrain = logic.terrain
	terrain.build(bound_terrain)

func _process(dt: float) -> void:
	if not ready_complete or finishing: return
	var now:int=Time.get_ticks_usec()
	if last_frame_usec>0 and wall_frame_samples.size()<36000:wall_frame_samples.append(float(now-last_frame_usec)/1000.0)
	last_frame_usec=now;total_frame_count+=1
	demo_wall+=dt
	if review_region=="boss" and not logic.boss_spawned and demo_wall>=review_boss_delay:
		logic.spawn_boss()
	if sample_frames.size()<36000:sample_frames.append(dt)
	if demo_seconds>0 and demo_wall>=demo_seconds:
		finish_demo()
		return
	if bound_terrain != logic.terrain:
		_build_terrain()
		visuals.reset()
		_update_camera(dt,true)
	else:
		_update_camera(dt)
	terrain.update_view(logic.hero,logic.time,render_view_rect2d)
	visuals.sync(logic,render_view_rect2d)
	_update_peaks()

func _update_peaks() -> void:
	peak_visible_actor_count=maxi(peak_visible_actor_count,visuals.actor_views.size())
	peak_visible_source_count=maxi(peak_visible_source_count,visuals.corpse_batches.visible_source_count)

func _update_camera(dt: float, instant: bool = false) -> void:
	var hero_world: Vector2 = logic.hero / PX_PER_UNIT
	# Keep the full orthographic ground footprint inside the finite battlefield.
	# Camera yaw/pitch/scale remain unchanged; edge players move off-centre.
	var viewport_size:Vector2=get_viewport().get_visible_rect().size
	var half_x:float=camera.size*viewport_size.x/maxf(1.0,viewport_size.y)*0.5
	var half_z:float=camera.size*sqrt(34.0*34.0+18.0*18.0)/34.0*0.5
	var wanted := Vector3(clampf(hero_world.x,half_x,200.0-half_x),terrain.floor_height(hero_world),clampf(hero_world.y,half_z,110.0-half_z))
	camera_target = wanted if instant else camera_target.lerp(wanted,minf(1.0,dt*8.0))
	_position_camera()
	render_view_rect2d = _camera_ground_rect()
	logic.render_view_rect2d = render_view_rect2d

func _position_camera() -> void:
	camera.position = camera_target + Vector3(0,34,18)
	camera.look_at(camera_target,Vector3.UP)

func _camera_ground_rect() -> Rect2:
	var size: Vector2 = get_viewport().get_visible_rect().size
	var points: Array[Vector2] = []
	for screen_pt in [Vector2.ZERO,Vector2(size.x,0),size,Vector2(0,size.y)]:
		var origin: Vector3 = camera.project_ray_origin(screen_pt)
		var ray: Vector3 = camera.project_ray_normal(screen_pt)
		var hit: Vector3 = origin + ray * (-origin.y/ray.y)
		points.append(Vector2(hit.x,hit.z)*PX_PER_UNIT)
	var result := Rect2(points[0],Vector2.ZERO)
	for point in points: result=result.expand(point)
	return result

func project_point(p: Vector2) -> Vector2:
	var world: Vector2 = p/PX_PER_UNIT
	var height: float = terrain.floor_height(world) if is_instance_valid(terrain) else 0.0
	return camera.unproject_position(Vector3(world.x,height+0.035,world.y))

func unproject_point(p: Vector2) -> Vector2:
	var origin: Vector3 = camera.project_ray_origin(p)
	var ray: Vector3 = camera.project_ray_normal(p)
	var hit: Vector3 = origin + ray * (-origin.y/ray.y)
	return Vector2(hit.x,hit.z)*PX_PER_UNIT

func screen_to_world(p: Vector2) -> Vector2:
	return unproject_point(p)

func get_stats() -> Dictionary:
	var result: Dictionary = terrain.get_stats() if terrain.has_method("get_stats") else {}
	result.merge(visuals.get_stats())
	result["world_units"] = Vector2(200,110)
	result["pixels_per_unit"] = PX_PER_UNIT
	result["view_rect_px"] = render_view_rect2d
	return result

func get_metrics() -> Dictionary:
	var result:Dictionary=get_stats()
	var sum:float=0.0
	var peak:float=0.0
	var actual_wall_seconds:float=float(Time.get_ticks_usec()-started_usec)/1000000.0
	var sorted_frames:Array[float]=wall_frame_samples.duplicate()
	sorted_frames.sort()
	var p95:float=sorted_frames[clampi(ceili(sorted_frames.size()*0.95)-1,0,sorted_frames.size()-1)] if not sorted_frames.is_empty() else 0.0
	result.merge({"real_wall_seconds":actual_wall_seconds,"total_frame_count":total_frame_count,"real_wall_fps":float(total_frame_count)/maxf(actual_wall_seconds,0.001),"p95_frame_ms":p95,"peak_visible_actor_count":peak_visible_actor_count,"peak_visible_source_count":peak_visible_source_count,"engine_delta_sample_fps":float(sample_frames.size())/maxf(demo_wall,0.001)})
	for value in sample_frames:sum+=value;peak=maxf(peak,value)
	result.merge({"mode":"REGION REVIEW: EXPLICIT TEST PLACEMENT" if review_region!="" else ("INPUT-ONLY DEMO" if logic.demo else "MANUAL PLAY"),"hidden_stat_overrides":false,"review_region":review_region,"game_seconds":logic.time,"wall_seconds":demo_wall,"state":logic.state,"hero_px":logic.hero,"hero_hp":logic.hp,"hero_max_hp":logic.max_hp,"damage":logic.damage,"reach":logic.reach,"attack_rate":logic.attack_rate,"kills":logic.kills,"rescued":logic.rescued,"fallen":logic.fallen,"allies":logic.allies.size(),"enemies":logic.enemies.size(),"boss_spawned":logic.boss_spawned,"boss_dead":logic.boss_dead,"source_bodies_total":logic.corpse_field.total_slots,"mean_fps":sample_frames.size()/maxf(sum,0.001),"slowest_frame_ms":peak*1000.0,"camera_offset":Vector3(0,34,18),"camera_size":camera.size})
	return result

func finish_demo() -> void:
	if finishing:return
	finishing=true
	var metrics:Dictionary=get_metrics()
	if metrics_path!="":
		var file:=FileAccess.open(metrics_path,FileAccess.WRITE)
		if file:file.store_string(JSON.stringify(metrics,"  "))
	print("LARGE_HD2D_METRICS "+JSON.stringify(metrics))
	logic.set_process(false)
	if is_instance_valid(logic.audio_controller):
		logic.audio_controller.stop_effects()
		logic.music.stop();logic.music.stream=null
	await get_tree().create_timer(0.18).timeout
	get_tree().quit()
