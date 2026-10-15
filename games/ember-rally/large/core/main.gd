extends Node2D
# Original code-drawn art and combat. Positions are authoritative world coordinates.
const WORLD = Vector2(10000,5500)
const VIEWPORT_SIZE = Vector2(1280,720)
const CAMERA_ZOOM = 0.8
const WORLD_VIEW_SIZE = VIEWPORT_SIZE / CAMERA_ZOOM
const MAX_ENEMY_HEALTH_BARS = 4
# CanvasLayer zoom changes presentation only: authoritative positions, TileSet
# collision metadata, attack ranges and input hitboxes remain in world/UI units.
class WorldCanvas extends Node2D:
	var ui_font: Font
	func txt(p:Vector2,s:String,size:int=18,col:Color=Color("e6c783")):
		draw_string(ui_font,p,s,HORIZONTAL_ALIGNMENT_LEFT,-1,size,col)
var world_layer: CanvasLayer
var world_canvas: WorldCanvas
const START_POSITION=Vector2(700,3050)
const BOSS_POSITION=Vector2(9100,2750)
const DEMON_ENTRANCE_POSITION=Vector2(8490,2740)
const BOSS_TRIGGER_RECT=Rect2(8150,1400,1500,2750)
const BOSS_LEASH_RECT=Rect2(8250,1470,1350,2600)
const NecromancerEncounters=preload("res://large/core/necromancer_encounters.gd")
var necromancers=NecromancerEncounters.new()
const LegionDirector=preload("res://large/core/legion_director.gd")
var legions=LegionDirector.new()
var main_bridge_open: bool:
	get: return legions.main_bridge_open
var bridge_lowering_started_at: float:
	get: return legions.bridge_lowering_started_at
var rewarded_source_ids:Dictionary={}
const CampResistance=preload("res://large/core/camp_resistance.gd")
var camp_resistance=CampResistance.new()
var sleeping_enemies:Array=[]
const GOLD = Color("e6c783")
const INK = Color("10181d")
const SpawnDirector = preload("res://large/core/spawn_director.gd")
var director = SpawnDirector.new()
const CorpseField=preload("res://large/core/corpse_field.gd")
var corpse_field=CorpseField.new()
const Terrain = preload("res://large/core/terrain.gd")
var terrain = Terrain.new()
const CrowdSpacing = preload("res://large/core/crowd_spacing.gd")
var crowd_spacing = CrowdSpacing.new()
var demo_nav: Dictionary = {}
var corpses: Array = []
var ambient_bodies: Array = []
const SpriteRenderer=preload("res://sprite_renderer.gd")
var sprites=SpriteRenderer.new()
var font: Font
var hero = START_POSITION
var facing = Vector2.UP
var hero_moving=false
var attack_age=-1.0
var attack_direction=Vector2.UP
var strike_applied=false
var hero_death_age=0.0
var tiles:Node2D
const AudioController=preload("res://audio_controller.gd")
var audio_controller:Node
var hp = 120.0
var max_hp = 120.0
var time = 0.0
var level = 1
var xp = 0
var needed = 8
var damage = 24.0
var reach = 114.0
var attack_rate = 0.74
var attack_cd = 0.0
var slash = 0.0
var hurt_cd = 0.0
var spawn_cd = 1.0
var enemies: Array = []
var allies: Array = []
var camps: Array = []
var bullets: Array = []
var gems: Array = []
var effects: Array = []
var decor: Array = []
var state = "title"
const BattleInput = preload("res://large/core/battle_input.gd")
var controls = BattleInput.new()
var upgrade_selection := 0
var _input_state := ""
var _map_return_state := "play"
var kills = 0
var rescued = 0
var fallen = 0
var blocks = 0
var arrow_hits = 0
var boss_spawned = false
var boss_dead = false
var boss_warning = 0.0
var volume = 0.5
var camera = Vector2.ZERO
var rng = RandomNumberGenerator.new()
var music: AudioStreamPlayer
var sounds = {}
var demo = false
var demo_mode="normal"
var demo_frames = 0
var notice = ""
var notice_time = 0.0
# Identity belongs to a combat actor, never to its current array index.
var next_view_serial := 1
var run_generation := 0
var hero_view_id := "hero"

func allocate_view_id(prefix: String = "actor") -> String:
	var result := "%s:%d:%d" % [prefix, run_generation, next_view_serial]
	next_view_serial += 1
	return result

func visual_identity(kind: String, identity: String) -> Dictionary:
	# Hashing does not consume the authoritative combat random-number stream.
	var variant := posmod(identity.hash(), 4)
	var visual_kind := ("undead" if variant < 2 else "zombie") if kind == "undead" else kind
	var headgear := ("retained" if variant == 2 else "fallen") if visual_kind == "zombie" else ("fallen" if visual_kind == "undead" else "none")
	return {"visual_kind": visual_kind, "skin_kind": visual_kind,
		"headgear_variant": headgear,
		"rise_path": "skeleton_transform" if visual_kind == "undead" else (("zombie_" + headgear) if visual_kind == "zombie" else ("demon_rise" if kind in ["demon", "caster"] else ""))}

func make_death_corpse(actor: Dictionary, lifespan: float, face: Vector2) -> Dictionary:
	if not actor.has("view_id"):
		actor["view_id"] = allocate_view_id()
	var body := {"p": actor.p, "kind": actor.kind, "life": lifespan,
		"elapsed": 0.0, "death_age": 0.0, "face": face,
		"view_id": actor.view_id, "hp": 0.0, "max": actor.get("max", 1.0)}
	for key in ["visual_kind", "skin_kind", "headgear_variant", "rise_path", "corpse_id", "body_kind", "source_type", "body_variant", "origin", "role", "subtype", "necromancer"]:
		if actor.has(key): body[key] = actor[key]
	return body


func _ready():
	font = load("res://assets/interface.ttf")
	world_layer=CanvasLayer.new(); world_layer.name="WorldView"; world_layer.layer=-1
	world_layer.scale=Vector2.ONE*CAMERA_ZOOM; add_child(world_layer)
	world_canvas=WorldCanvas.new(); world_canvas.name="WorldCanvas"; world_canvas.ui_font=font
	world_canvas.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	world_layer.add_child(world_canvas); world_canvas.draw.connect(_draw_world)
	rng.seed = 73127
	for i in range(1400):
		decor.append({"p":Vector2(rng.randf_range(40,WORLD.x-40),rng.randf_range(100,WORLD.y-40)),"kind":i%5,"a":rng.randf()*TAU,"size":rng.randf_range(5,20)})
	audio_controller=AudioController.new(); add_child(audio_controller)
	music=audio_controller.music
	# The controller owns persisted audio preferences; do not overwrite them.
	volume=audio_controller.volume
	tiles=load("res://tile_battlefield.tscn").instantiate(); tiles.z_index=-1; world_canvas.add_child(tiles); tiles.setup(terrain)
	reset_game()
	state="title"
	texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	sprites.enabled = not "--legacy-geometry" in OS.get_cmdline_user_args()
	demo_mode="late" if "--camp-late-demo" in OS.get_cmdline_user_args() else "normal"
	demo = "--demo" in OS.get_cmdline_user_args() or demo_mode=="late"
	if demo: state="play"

func reset_game():
	upgrade_selection = 0; _input_state = ""; _map_return_state = "play"
	controls.reset_menu_navigation()
	run_generation += 1; next_view_serial = 1
	hero=START_POSITION; facing=Vector2.UP; hp=120; max_hp=120
	time=0; level=1; xp=0; needed=8; damage=24; reach=114; attack_rate=0.74
	attack_cd=0; attack_age=-1; strike_applied=false; hero_death_age=0; slash=0; hurt_cd=0; spawn_cd=1; kills=0; rescued=0; fallen=0; blocks=0; arrow_hits=0
	boss_spawned=false; boss_dead=false; boss_warning=0
	necromancers.reset(); legions.reset(); rewarded_source_ids.clear(); crowd_spacing.reset()
	director.reset(73127); corpses.clear(); terrain=Terrain.new(); terrain.reset(); demo_nav.clear(); ambient_bodies.clear()
	corpse_field.reset(73127,WORLD,terrain.is_walkable)
	corpse_field.prime(hero,world_view_rect(),0.0)
	director.bind_corpse_field(corpse_field)
	enemies.clear(); sleeping_enemies.clear(); allies.clear(); camps.clear(); bullets.clear(); gems.clear(); effects.clear()
	var positions=Terrain.CAMP_POSITIONS
	for i in range(positions.size()):
		camps.append({"p":positions[i],"kind":"shield" if i%2==0 else "archer","rescued":false,"guards":[],"discovered":false,"view_id":"camp:%d:%d"%[run_generation,i]})
		for j in range(3+i/2):
			var e=make_enemy(positions[i]+Vector2.from_angle(j*TAU/(3+i/2))*80,"demon" if i>=3 and j==0 else "undead",i)
			camps[i].guards.append(e)
		camp_resistance.setup_camp(camps[i])
	if tiles: tiles.setup(terrain)
	if audio_controller:
		audio_controller.stop_effects()
		audio_controller.set_track(0)
	terrain.update_discoveries(hero,camps)
	camera=camera_for_hero(hero)
	if tiles:tiles.update_camera(camera,WORLD_VIEW_SIZE)
	state="play"

func demon_entrance_position() -> Vector2:
	return Vector2(9020,3490)

func prepare_entrance_actor(actor: Dictionary, final_wave: bool) -> void:
	actor["origin"] = "demon_entrance"
	actor["spawn_style"] = "entrance"
	actor["entrance_route"] = [Vector2(8490,2740),Vector2(7620,2740)] if final_wave else [Vector2(9020,4300),Vector2(9180,4380),Vector2(8400,4510),Vector2(7560,4400),Vector2(7620,2740)]
	actor["entrance_waypoint"] = 0

func make_enemy(p:Vector2, kind:String, camp:int=-1):
	var health=48.0 if kind=="undead" else 70.0
	if kind=="caster": health=42
	if kind=="boss": health=1700
	p=terrain.nearest_open(p,36 if kind=="boss" else 18)
	var e={"p":p,"kind":kind,"hp":health,"max":health,"cd":rng.randf_range(0.7,2),"camp":camp,"flash":0.0,"phase":0.0,"aim":Vector2.ZERO}
	e["view_id"] = allocate_view_id("enemy")
	e.merge(visual_identity(kind, e.view_id))
	enemies.append(e)
	return e

func play_sound(s:String):
	if audio_controller: audio_controller.play_event(s)

func set_volume(v:float):
	volume=clampf(v,0,1)
	if audio_controller: audio_controller.set_volume(volume)

func _sync_input_state() -> void:
	if state == _input_state: return
	if state == "upgrade":
		upgrade_selection = 0
		# A stick held while walking into a level-up must first return to neutral.
		controls.reset_menu_navigation(true)
	else:
		controls.reset_menu_navigation()
	_input_state = state

func _move_upgrade_selection(dt: float) -> void:
	var step: int = controls.menu_horizontal_step(dt)
	if step != 0: upgrade_selection = posmod(upgrade_selection + step, 3)

func _unhandled_input(event):
	_sync_input_state()
	controls.observe_event(event)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M and audio_controller:
			audio_controller.toggle_mute(); volume = audio_controller.volume
		if event.keycode == KEY_MINUS: set_volume(volume - 0.1)
		if event.keycode == KEY_EQUAL: set_volume(volume + 0.1)
		if event.keycode == KEY_BRACKETLEFT and audio_controller: audio_controller.set_music_gain(audio_controller.music_gain - 0.1)
		if event.keycode == KEY_BRACKETRIGHT and audio_controller: audio_controller.set_music_gain(audio_controller.music_gain + 0.1)
		if state == "upgrade" and event.keycode in [KEY_1, KEY_2, KEY_3]: choose_upgrade(event.keycode - KEY_1)
	if state == "upgrade": _move_upgrade_selection(0.0)
	if event.is_action_pressed(BattleInput.CONFIRM):
		if state == "title" or state == "pause": state = "play"
		elif state in ["win", "lose"]: reset_game()
		elif state == "upgrade": choose_upgrade(upgrade_selection)
	elif event.is_action_pressed(BattleInput.MAP):
		if state == "map": state = _map_return_state
		elif state in ["play", "pause"]:
			_map_return_state = state
			state = "map"
	elif event.is_action_pressed(BattleInput.BACK) or event.is_action_pressed(BattleInput.PAUSE):
		if state == "map": state = _map_return_state
		elif state in ["play", "pause"]: state = "pause" if state == "play" else "play"
		elif state == "title" and event.is_action_pressed(BattleInput.PAUSE): state = "play"
	elif event.is_action_pressed(BattleInput.RESTART) and state in ["win", "lose", "pause"]:
		reset_game()
	elif event.is_action_pressed(BattleInput.HOLY_FLASH) and state == "play" and has_method("cast_holy_flash"):
		call("cast_holy_flash")
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var p = event.position
		if state == "title": state = "play"
		elif state in ["win", "lose"]: reset_game()
		elif state == "upgrade" and p.y > 285 and p.y < 505:
			for i in range(3):
				if Rect2(160 + i * 330, 285, 310, 220).has_point(p):
					choose_upgrade(i)
					break
	_sync_input_state()
	# Apply pause immediately on input so same-frame track requests stay queued.
	if audio_controller: audio_controller.set_paused(state in ["pause", "upgrade", "map"])

func choose_upgrade(i:int):
	if i < 0 or i > 2: return
	upgrade_selection = i
	if i==0: damage+=9; reach+=8
	if i==1: attack_rate=maxf(0.24,attack_rate*0.86)
	if i==2:
		max_hp+=15; hp=minf(hp+45,max_hp)
		for a in allies: a.hp=minf(a.hp+42,a.max)
	state="play"; play_sound("level")

func _process(dt):
	dt=minf(dt,0.05)
	_sync_input_state()
	if state == "upgrade": _move_upgrade_selection(dt)
	if demo:
		demo_frames+=1
		if state=="upgrade": choose_upgrade(0 if level%3 else 2)
	if audio_controller: audio_controller.set_paused(state in ["pause","upgrade","map"])
	if state=="play": simulate(dt)
	elif state in ["win","lose"]:
		hero_death_age+=dt
		advance_corpses(dt)
	_sync_input_state()
	# Level-ups raised during simulation pause audio in this same frame.
	if audio_controller: audio_controller.set_paused(state in ["pause", "upgrade", "map"])
	camera=camera.lerp(camera_for_hero(hero),minf(dt*8,1)).clamp(Vector2.ZERO,WORLD-WORLD_VIEW_SIZE)
	if tiles: tiles.update_camera(camera,WORLD_VIEW_SIZE)
	if world_canvas:world_canvas.queue_redraw()
	queue_redraw()

func simulate(dt:float):
	if state!="play" or dt<=0:return
	if hp<=0:
		state="lose"; attack_age=-1; slash=0; return
	terrain.begin_frame()
	crowd_spacing.begin_movement(self)
	if tiles and tiles.has_method("update_ambience"):tiles.update_ambience(dt,camera,WORLD_VIEW_SIZE)
	_update_enemy_regions()
	time+=dt; legions.observe_clock(time,state); attack_cd-=dt; hurt_cd-=dt; slash=maxf(0,slash-dt); notice_time-=dt
	var move: Vector2 = controls.movement()
	if demo: move=demo_direction(dt)
	hero_moving = not move.is_zero_approx()
	if hero_moving:
		# Preserve stick strength: normalize facing, never analog displacement.
		move = move.limit_length(1.0)
		hero = terrain.move_actor(hero, move * 205 * dt, 20).clamp(Vector2(40,110), WORLD-Vector2(40,40))
		facing = move.normalized()
		crowd_spacing.follow_direction = facing
	var newly_found=terrain.update_discoveries(hero,camps)
	if not newly_found.is_empty(): notice="听见求救声：掩体后有幸存部队！"; notice_time=3
	var nearest=nearest_enemy(hero,reach+30)
	if attack_cd<=0 and nearest!=null and hero.distance_to(nearest.p)<reach+enemy_radius(nearest):
		attack_cd=attack_rate; attack_age=0; strike_applied=false
		if nearest!=null: facing=(nearest.p-hero).normalized()
		attack_direction=facing; slash=0.35
	if attack_age>=0:
		attack_age+=dt; slash=maxf(0,0.35-attack_age)
		if attack_age>=0.12 and not strike_applied:
			strike_applied=true; play_sound("sword_swing")
			for e in enemies.duplicate():
				var d=e.p-hero
				if d.length()<reach+enemy_radius(e) and d.normalized().dot(attack_direction)>-0.18 and terrain.has_line_of_sight(hero,e.p):
					hit_enemy(e,damage); e.p=constrain_enemy_position(e,terrain.move_actor(e.p,d.normalized()*24,enemy_radius(e)))
		if attack_age>=0.35: attack_age=-1
	crowd_spacing.prepare_combat_slots(self)
	var camp_events=camp_resistance.update(self,dt)
	for event in camp_events:
		var label=str(event.get("type",""))
		if label=="activated":notice="求救已响应！残部正在反抗，不能久等";notice_time=4
		elif label=="critical":notice="残部濒危！请立即清除围兵";notice_time=4
		elif label=="dead":notice="援救太迟：一支残部已阵亡";notice_time=5
	for c in camps:
		if camp_resistance.rescue_in_reach(self,c):rescue(c)
	update_allies(dt)
	crowd_spacing.prepare_combat_slots(self)
	update_enemies(dt)
	crowd_spacing.solve(self,dt)
	update_bullets(dt)
	camp_resistance.finalize_deaths(self)
	for i in range(gems.size()-1,-1,-1):
		if hero.distance_to(gems[i])<145: gems[i]=gems[i].move_toward(hero,360*dt)
		if hero.distance_to(gems[i])<25: gems.remove_at(i); xp+=1
	if xp>=needed and state=="play":
		xp-=needed; level+=1; needed+=5; state="upgrade"
	# Independent waves never become camp guards and cannot reset rescue progress.
	director.cooldown=spawn_cd
	corpse_field.step(dt,state if hp>0 else "lose",time,hero,world_view_rect(),defenders())
	if not legions.final_started and legions.pending.is_empty(): necromancers.step_spawn(self,dt)
	var requests=[] if legions.final_started or not legions.pending.is_empty() else director.step(dt,state if hp>0 else "lose",time,hero,defenders(),enemies,WORLD,terrain.is_walkable)
	spawn_cd=director.cooldown
	for request in requests:
		var spawned=make_enemy(request.p,request.kind,-1)
		director.apply_rise(spawned,request)
		spawned.face=request.get("body_face",(hero-spawned.p).normalized())
		if request.get("origin","corpse")=="corpse" and request.kind!="undead" and notice_time<=0:notice="恶魔残体正在苏醒";notice_time=2.5
	for request in ([] if legions.final_started or not legions.pending.is_empty() else director.step_entrance(dt,state if hp>0 else "lose",hero,defenders(),enemies,WORLD,demon_entrance_position(),terrain.is_walkable)):
		var entrant=make_enemy(request.p,request.kind,-1)
		director.apply_rise(entrant,request)
		prepare_entrance_actor(entrant,false)
		entrant.face=(hero-entrant.p).normalized()
		if notice_time<=0:notice="恶魔营门涌出援兵";notice_time=2.5
	legions.step(self,dt)
	advance_corpses(dt)
	for f in effects.duplicate():
		f.life-=dt
		if f.life<=0: effects.erase(f)
	if hp<=0: state="lose"; play_sound("death")

func advance_corpses(dt:float):
	for body in corpses.duplicate():
		body.elapsed+=dt; body.death_age=body.elapsed; body.life-=dt
		if body.life<=0: corpses.erase(body)

func demo_direction(dt:float=1.0/60.0):
	if demo_mode=="late":
		# Input-only demonstration: intentionally stay outside the first rescue camp.
		# No health, damage, spawns or combat clocks are changed.
		var wait_point:Vector2=camps[0].p+Vector2(440,120)
		var threat=nearest_enemy(hero,90)
		if threat!=null:wait_point=hero+(hero-threat.p).normalized()*100
		if hero.distance_to(wait_point)<12:return Vector2.ZERO
		demo_nav.p=hero
		return (terrain.steer_actor(demo_nav,wait_point,dt,205,20)-hero).normalized()
	if boss_spawned:
		for e in enemies:
			if e.kind=="boss":
				var away=(hero-e.p).normalized()
				var distance=hero.distance_to(e.p)
				var steer=away.orthogonal()*0.85+away*clampf((210-distance)/100.0,-0.5,1.5)
				if hero.x<220: steer.x+=1.2
				if hero.x>WORLD.x-220: steer.x-=1.2
				if hero.y<260: steer.y+=1.4
				if hero.y>WORLD.y-280: steer.y-=1.2
				return steer.normalized()
	var target=BOSS_POSITION
	for c in camps:
		if not c.rescued and c.get("status","")!="dead":
			target=c.fighter.p if c.has("fighter") else c.p
			for g in c.guards:
				if g.hp>0: target=g.p; break
			break
	var e=nearest_enemy(hero,85)
	if e!=null and hero.distance_to(target)>120: target=hero+(hero-e.p).normalized()*120
	if hero.distance_to(target)<=12:return Vector2.ZERO
	demo_nav.p=hero
	var next=terrain.steer_actor(demo_nav,target,dt,205,20)
	return (next-hero).normalized()

func rescue(c:Dictionary):
	if not camp_resistance.can_rescue(c):return
	var actor=camp_resistance.take_rescued_actor(c)
	if actor.is_empty():return
	rescued+=1;allies.append(actor)
	notice="同伴加入："+("剑盾兵" if c.kind=="shield" else "弓箭手")+" · 保留战斗后的生命 %d"%int(actor.hp)
	notice_time=4;hp=minf(max_hp,hp+12);play_sound("rescue")
	effects.append({"p":c.p,"life":0.8,"color":Color("83dfc0"),"radius":80.0})

func settled_camps()->int:
	var count=0
	for c in camps:
		if c.rescued or c.get("status","")=="dead":count+=1
	return count

func defenders()->Array:
	var result=allies.duplicate()
	result.append_array(camp_resistance.actors(camps))
	return result

func _update_enemy_regions():
	# Distant roaming enemies sleep without damage, XP or camp-clear side effects.
	for e in enemies.duplicate():
		if e.has("wave_id") or e.get("origin", "") == "demon_entrance": continue
		if e.get("entry_awake", false):
			var arrived: bool = e.p.distance_squared_to(hero) <= 1500.0 * 1500.0
			var left_entry_area: bool = hero.distance_squared_to(e.get("entry_anchor", hero)) > 750.0 * 750.0
			if not arrived and not left_entry_area and time < float(e.get("entry_expires_at", 0.0)):
				continue
			e["entry_awake"] = false
		if e.camp>=0 or e.kind=="boss" or e.p.distance_squared_to(hero)<=1550.0*1550.0:continue
		var near_friend=false
		for a in allies:
			if a.p.distance_squared_to(e.p)<=1300.0*1300.0:near_friend=true;break
		if near_friend:continue
		if e.get("necromancer",false):necromancers.interrupt(self,e)
		enemies.erase(e);sleeping_enemies.append(e)
	# Bound only dormant, non-wave roamers. Retirement has no kill, XP,
	# corpse or wave-clear side effect; camp guards and legions are never retired.
	while sleeping_enemies.size() > 256:
		var retired := false
		for sleeper in sleeping_enemies:
			if not sleeper.has("wave_id") and int(sleeper.get("camp", -1)) < 0:
				sleeping_enemies.erase(sleeper); retired = true; break
		if not retired: break
	for e in sleeping_enemies.duplicate():
		if enemies.size()>=139:break
		if not legions.pending.is_empty() and not e.has("wave_id"): continue
		if e.p.distance_squared_to(hero)>1000.0*1000.0:continue
		if e.kind!="undead":
			var elites=0
			for live in enemies:
				if live.camp<0 and live.kind in ["demon","caster"]:elites+=1
			if elites>=5:continue
		sleeping_enemies.erase(e);enemies.append(e)

func nearest_enemy(p:Vector2, limit:float):
	var best=null
	for e in enemies:
		if e.hp>0 and p.distance_to(e.p)<limit and terrain.has_line_of_sight(p,e.p): limit=p.distance_to(e.p); best=e
	return best

func enemy_radius(e:Dictionary): return 35.0 if e.kind=="boss" else 17.0

func enemy_melee_reach(e:Dictionary)->float:
	# Body-aware melee contact; damage, clocks and hero weapon reach unchanged.
	if e.kind=="boss": return 53.0
	return 50.0 if e.kind=="demon" else 42.0

func hit_enemy(e:Dictionary, amount:float, arrow:bool=false):
	if e.hp<=0: return
	e.hp-=amount; e.flash=0.12
	if e.get("necromancer",false) and amount>0:necromancers.interrupt(self,e,true)
	play_sound("arrow_hit" if arrow else ("undead_hit" if e.kind=="undead" else "demon_hit"))
	if e.hp<=0:
		var source_id=String(e.get("corpse_id",""))
		if source_id.is_empty() or not rewarded_source_ids.has(source_id):
			kills+=1
			if not e.get("summoned_by", ""): gems.append(e.p)
			if not source_id.is_empty():rewarded_source_ids[source_id]=true
		var ash=make_death_corpse(e,0.54,(hero-e.p).normalized())
		ash["disintegrate"]=true
		corpses.append(ash)
		if e.kind=="boss":
			boss_dead=true
		enemies.erase(e)

func update_allies(dt:float):
	for i in range(allies.size()-1,-1,-1):
		var a=allies[i]
		if a.hp<=0:
			corpses.append(make_death_corpse(a,2.0,a.face))
			allies.remove_at(i); fallen+=1; play_sound("death"); continue
		var before_position:Vector2=a.p
		a.cd-=dt; a.hurt-=dt; a.block=maxf(0,a.block-dt); a.flash=maxf(0,a.flash-dt)
		var desired=crowd_spacing.follow_target(self,a,i)
		# Arrival steering: match a moving formation instead of alternating full-speed
		# steps and one-frame stops at the old 12px cutoff. Hysteresis is only
		# for genuine arrival; collision/terrain still owns the actual displacement.
		var follow_distance:float=a.p.distance_to(desired)
		var following:bool=bool(a.get("following",false))
		if follow_distance>6.0:following=true
		elif follow_distance<=2.0:following=false
		a["following"]=following
		if following:
			var speed_cap:float=215.0 if a.p.distance_to(hero)<260 else 320.0
			var arrival_speed:float=minf(speed_cap,maxf(0.0,follow_distance-2.0)*8.0)
			a.p=terrain.steer_actor(a,desired,dt,arrival_speed,18)
		a["moving"]=a.p.distance_to(before_position)>0.05
		var e=nearest_enemy(a.p,510 if a.kind=="archer" else 88)
		if e!=null:
			a.face=(e.p-a.p).normalized()
			if a.cd<=0:
				a.cd=1.0 if a.kind=="archer" else 1.1
				a.attack_age=0.0; a.attack_done=false; a.attack_direction=a.face
				if a.kind=="archer":play_sound("bow_draw")
		elif facing.length()>0:a.face=facing
		if a.get("attack_age",-1.0)>=0:
			a.attack_age+=dt
			var release=0.18 if a.kind=="archer" else 0.12
			if a.attack_age>=release and not a.attack_done:
				a.attack_done=true
				if a.kind=="archer":shoot(a.p,a.attack_direction,460,20+level*2,true);play_sound("bow_release");play_sound("arrow_flight")
				elif e!=null and a.p.distance_to(e.p)<88:hit_enemy(e,18+level*2)
			if a.attack_age>=0.38:a.attack_age=-1.0
		a.guard=false
		if a.kind=="shield":
			var threat=220.0
			for b in bullets:
				if not b.friendly and a.p.distance_to(b.p)<threat and b.v.dot(a.p-b.p)>0:
					threat=a.p.distance_to(b.p); a.face=(b.p-a.p).normalized();a.guard=true

func shoot(p:Vector2, direction:Vector2, speed:float, amount:float, friendly:bool):
	bullets.append({"p":p,"v":direction.normalized()*speed,"damage":amount,"friendly":friendly,"life":4.0,"view_id":allocate_view_id("bullet")})

func update_enemies(dt:float):
	for e in enemies.duplicate():
		if e.hp<=0: continue
		if camp_resistance.owns_guard(self,e):continue
		if not director.advance_rise(e,dt,state): continue
		var previous_position:Vector2=e.p
		e.flash=maxf(0,e.flash-dt); e.cd-=dt
		e["attack_age"]=float(e.get("attack_age",-1.0))
		if e.attack_age>=0:e.attack_age+=dt
		if e.attack_age>=0.4:e.attack_age=-1.0
		e["melee_cd"]=float(e.get("melee_cd",0.0))-dt
		var target=hero; var victim=null
		var distance=e.p.distance_to(hero)
		for a in defenders():
			if e.p.distance_to(a.p)<distance: target=a.p; victim=a; distance=e.p.distance_to(a.p)
		if e.camp>=0 and distance>255:
			var home=camps[e.camp].p
			if e.p.distance_to(home)>85: e.p=terrain.steer_actor(e,home,dt,45,enemy_radius(e))
			continue
		# Physical marching waypoints, never elapsed-time repositioning.
		var route: Array = e.get("entrance_route", [])
		var waypoint := int(e.get("entrance_waypoint", 0))
		if waypoint < route.size() and distance > 420.0:
			if e.p.distance_to(route[waypoint]) < 85.0:
				waypoint += 1; e["entrance_waypoint"] = waypoint
			if waypoint < route.size(): target = route[waypoint]
		var dir=(target-e.p).normalized()
		e["face"]=dir
		var speed=57.0 if e.kind=="undead" else 78.0
		if e.get("necromancer",false):
			speed=55 if distance>280 else (-30 if distance<210 else 0)
			if not necromancers.step_actor(self,e,dt):speed=0
		elif e.kind=="caster":
			speed=55
			if distance<230: speed=-30
			if e.phase>0:
				e.phase-=dt; speed=0
				if e.phase<=0:shoot(e.p,(e.aim-e.p).normalized(),185,13,false); e.attack_age=0.18
			elif e.cd<=0 and distance<540 and terrain.has_line_of_sight(e.p,target):
				e.phase=0.4;e.cd=2.4;e.aim=target;e["attack_direction"]=dir
		if e.kind=="boss":
			if not e.has("wave_id") and not BOSS_LEASH_RECT.has_point(target):
				e.phase=0.0
				e.p=constrain_enemy_position(e,terrain.steer_actor(e,BOSS_POSITION,dt,57,enemy_radius(e)))
				e["moving"]=e.p.distance_to(previous_position)>0.05
				continue
			speed=57
			if e.phase>0:
				e.phase-=dt; speed=0
				if e.phase<=0:
					e.attack_age=0.18; e.attack_direction=dir
					for j in range(12): shoot(e.p,Vector2.from_angle(j*TAU/12+time*0.13),160,18,false)
					for j in range(3): shoot(e.p,dir.rotated((j-1)*0.18),230,20,false)
			elif e.cd<=0: e.cd=4.5 if e.hp>850 else 3.0; e.phase=1.05; e.aim=target; e["attack_direction"]=dir; play_sound("boss_charge")
		var movement_target:Vector2=e.get("crowd_approach",target) if e.kind!="caster" else target
		e.p=constrain_enemy_position(e,terrain.steer_actor(e,movement_target,dt,speed,enemy_radius(e)))
		e["moving"]=e.p.distance_to(previous_position)>0.05
		if distance<enemy_melee_reach(e)+8.0 and e.melee_cd<=0 and e.kind!="caster":
			e.melee_cd=CampResistance.GUARD_ATTACK_INTERVAL if victim!=null and victim.get("camp_fighter",false) else 0.65
			e.attack_age=0.0;e["melee_done"]=false;e["attack_direction"]=dir
		if e.get("melee_done",true)==false and e.attack_age>=(0.16 if e.kind=="undead" else 0.18):
			e.melee_done=true
			if e.p.distance_to(target)<enemy_melee_reach(e) and terrain.has_line_of_sight(e.p,target):
				e["crowd_landed_at"]=time
				if victim==null:hurt_hero(10 if e.kind!="boss" else 24)
				else:
					if victim.get("camp_fighter",false):camp_resistance.hurt_fighter(self,victim,(CampResistance.GUARD_DAMAGE+(0.5 if e.kind=="demon" else 0.0)) if e.kind!="boss" else 22)
					else:hurt_ally(victim,9 if e.kind!="boss" else 22)

func hurt_hero(amount:float):
	if hurt_cd>0: return
	hp-=amount; hurt_cd=0.65; play_sound("hit")

func hurt_ally(a:Dictionary,amount:float):
	if a.hurt>0: return
	a.hp-=amount; a.hurt=0.7; a.flash=0.15

func update_bullets(dt:float):
	for b in bullets.duplicate():
		var old_position: Vector2=b.p
		b.p+=b.v*dt; b.life-=dt
		if terrain.projectile_blocked(old_position,b.p): bullets.erase(b); continue
		if b.life<=0: bullets.erase(b); continue
		var used=false
		if b.friendly:
			for e in enemies.duplicate():
				if b.p.distance_to(e.p)<enemy_radius(e)+7:
					hit_enemy(e,b.damage,true); arrow_hits+=1; used=true; break
		else:
			for a in defenders():
				var delta=b.p-a.p
				if a.hp>0 and a.kind=="shield" and a.block<=0 and delta.length()<64 and delta.normalized().dot(a.face)>0.30:
					a.block=0.32; a.flash=0.25; blocks+=1; used=true; play_sound("block")
					effects.append({"p":b.p,"life":0.25,"color":Color("91e4ed"),"radius":29.0}); break
			if not used:
				if b.p.distance_to(hero)<21: hurt_hero(b.damage); used=true
				else:
					for a in defenders():
						if a.hp>0 and b.p.distance_to(a.p)<21:
							if a.get("camp_fighter",false):camp_resistance.hurt_fighter(self,a,b.damage)
							else:hurt_ally(a,b.damage)
							used=true;break
		if used: bullets.erase(b)

func should_trigger_boss()->bool:
	return false # Final boss is issued only by the timed final legion.

func constrain_enemy_position(enemy:Dictionary,proposed:Vector2)->Vector2:
	if enemy.kind=="boss" and not enemy.has("wave_id"):
		var bounded=proposed.clamp(BOSS_LEASH_RECT.position,BOSS_LEASH_RECT.end-Vector2.ONE)
		return bounded if terrain.is_walkable(bounded,enemy_radius(enemy)) else enemy.p
	if enemy.get("necromancer",false) and enemy.get("origin", "") != "demon_entrance":
		var bounded=Vector2(clampf(proposed.x,NecromancerEncounters.MIDDLE_MIN_X+18,NecromancerEncounters.MIDDLE_MAX_X-18),proposed.y)
		return bounded if terrain.is_walkable(bounded,enemy_radius(enemy)) else enemy.p
	return proposed

func spawn_boss():
	if boss_spawned or state!="play" or hp<=0 or not legions.main_bridge_open:return
	boss_spawned=true; boss_warning=4
	var boss=make_enemy(BOSS_POSITION,"boss")
	boss["home"]=BOSS_POSITION
	boss["origin"]="demon_camp"
	if audio_controller:audio_controller.set_track(1)
	notice="恶魔军士长据守营内！避开蓄力，护住你的队伍"; notice_time=5

func camera_for_hero(p:Vector2)->Vector2:
	return (p-WORLD_VIEW_SIZE*0.5).clamp(Vector2.ZERO,WORLD-WORLD_VIEW_SIZE)

func world_view_rect(margin:float=0.0)->Rect2:
	return Rect2(camera,WORLD_VIEW_SIZE).grow(margin)

func experience_ratio()->float:return clampf(float(xp)/maxi(needed,1),0,1)
func hero_health_ratio()->float:return clampf(hp/maxf(max_hp,1.0),0,1)

func world_position(p:Vector2)->Vector2:return p-camera
func screen(p:Vector2)->Vector2:return world_position(p)*CAMERA_ZOOM
func screen_to_world(p:Vector2)->Vector2:return p/CAMERA_ZOOM+camera
func world_txt(p:Vector2,s:String,size:int=18,col:Color=GOLD):world_canvas.txt(p,s,size,col)
func world_healthbar(p:Vector2,width:float,ratio:float,col:Color,height:float=5.0):
	world_canvas.draw_rect(Rect2(p-Vector2.ONE,Vector2(width+2,height+2)),Color(0.015,0.025,0.03,0.94))
	world_canvas.draw_rect(Rect2(p,Vector2(width,height)),Color("24312f"))
	world_canvas.draw_rect(Rect2(p,Vector2(width*clampf(ratio,0,1),height)),col)

func show_actor_health(actor:Dictionary,role:String)->bool:
	if float(actor.get("hp",0))<=0:return false
	if role=="ally":
		return actor.get("camp_fighter",false) or float(actor.hp)<float(actor.max) or float(actor.get("hurt",0))>0
	return role=="enemy" and actor.get("kind","")!="boss" and float(actor.hp)<float(actor.max)

func visible_enemy_health_ids()->Array:
	var result:Array=[]
	for i in range(enemies.size()):
		if show_actor_health(enemies[i],"enemy") and world_view_rect().has_point(enemies[i].p):result.append(i)
	result.sort_custom(func(a,b):return hero.distance_squared_to(enemies[a].p)<hero.distance_squared_to(enemies[b].p))
	if result.size()>MAX_ENEMY_HEALTH_BARS:result.resize(MAX_ENEMY_HEALTH_BARS)
	return result

func camp_is_critical(c:Dictionary)->bool:
	var fighter:Dictionary=c.get("fighter",{})
	return c.get("discovered",false) and not c.get("rescued",false) and c.get("status","")=="active" and float(fighter.get("hp",0))>0 and float(fighter.get("hp",0))<=float(fighter.get("max",1))*0.30

func visible_boss()->Dictionary:
	for enemy in enemies:
		if enemy.get("kind","")=="boss" and float(enemy.get("hp",0))>0:return enemy
	return {}

func camp_marker(c:Dictionary)->Dictionary:
	var result={"visible":false,"critical":camp_is_critical(c),"position":screen(c.get("p",Vector2.ZERO)),"direction":Vector2.ZERO}
	if c.get("rescued",false) or c.get("status","") not in ["active","cleared"] or not c.get("discovered",false):return result
	if float(c.get("fighter",{}).get("hp",0))<=0:return result
	var safe=Rect2(30,64,1220,558)
	var p:Vector2=result.position
	if safe.has_point(p):return result
	var direction=(p-safe.get_center()).normalized()
	var half=safe.size*0.5
	var distance=minf(half.x/maxf(absf(direction.x),0.001),half.y/maxf(absf(direction.y),0.001))
	result.visible=true;result.direction=direction;result.position=safe.get_center()+direction*distance
	return result

func hud_sections()->Array:
	if state!="play":return []
	var result=["experience","clock","level","hero_health"]
	if not visible_boss().is_empty():result.append("boss_health")
	for camp in camps:
		if camp_marker(camp).visible:result.append("camp_markers");break
	return result

func txt(p:Vector2,s:String,size:int=18,col:Color=GOLD): draw_string(font,p,s,HORIZONTAL_ALIGNMENT_LEFT,-1,size,col)
func panel(rect:Rect2,col:Color=Color("152027")):
	draw_style_box(style(col),rect)
func style(col:Color):
	var s=StyleBoxFlat.new(); s.bg_color=col; s.border_color=Color("526064"); s.set_border_width_all(1); s.set_corner_radius_all(7); return s

func _draw():
	if state=="play":draw_hud()
	else:draw_overlay()

func _draw_world():
	if tiles==null:
		world_canvas.draw_rect(Rect2(Vector2.ZERO,WORLD_VIEW_SIZE),Color("28302c"))
		draw_battlefield()
		terrain.draw_world(world_canvas,camera,time,WORLD_VIEW_SIZE)
	for c in camps:
		if c.rescued or not c.get("discovered",false):continue
		var p=world_position(c.p)
		if not world_view_rect(120).has_point(c.p):continue
		if c.get("status","")=="dead":
			world_txt(p+Vector2(-44,-28),"残部已阵亡",16,Color("b3a49b"));continue
		var left=0
		for g in c.guards:
			if g.hp>0:left+=1
		world_txt(p+Vector2(-60,-91),"反抗中 · 围兵 %d"%left if left>0 else "靠近营救",15,Color("efdb9b"))
	for body in corpse_field.bodies_in_rect(world_view_rect(100)):
		var body_role=str(body.get("actor_kind","demon")) if body.body_kind=="demon" else ("shield" if int(body.variant)%2==0 else "archer")
		if body.body_kind=="demon" and sprites.draw_corpse_rise(world_canvas,world_position(body.p),body_role,body.face,0,0.72):continue
		if sprites.can_draw(body_role):sprites.draw_keypose(world_canvas,world_position(body.p),body_role,body.face,11,0,0.72)
	for body in corpses:
		if sprites.can_draw(body.kind):sprites.draw_keypose(world_canvas,world_position(body.p),body.kind,body.get("face",Vector2.RIGHT),sprites.frame_for(body.kind,false,time,-1,0,body.elapsed),0,minf(1,body.life/0.2))
	for g in gems:
		var p=world_position(g); world_canvas.draw_colored_polygon(PackedVector2Array([p+Vector2(0,-6),p+Vector2(5,0),p+Vector2(0,6),p+Vector2(-5,0)]),Color("81c4b3"))
	var enemy_health_ids=visible_enemy_health_ids()
	var drawables=[]
	for e in enemies: drawables.append({"p":e.p,"ref":e,"role":"enemy"})
	for a in defenders():drawables.append({"p":a.p,"ref":a,"role":"ally"})
	drawables.append({"p":hero,"role":"hero"})
	drawables.sort_custom(func(a,b):return a.p.y<b.p.y)
	for d in drawables:
		if not world_view_rect(120).has_point(d.p):continue
		if d.role=="hero": draw_person(world_position(hero),"hero",attack_direction if attack_age>=0 else facing,hurt_cd, true,1.0,sprites.frame_for("hero",hero_moving,time,attack_age,hurt_cd,hero_death_age if state=="lose" else -1))
		else:
			var a=d.ref
			var visual_attack=float(a.get("attack_age",-1.0))
			if a.kind in ["boss","caster"] and a.phase>0:visual_attack=0.02 if a.phase>(0.6 if a.kind=="boss" else 0.2) else 0.1
			var pose=sprites.frame_for(a.kind,a.get("moving",false),time,visual_attack,a.flash,-1,a.rise_elapsed if director.is_rising(a) else -1,a.get("block",0.0),a.get("guard",false))
			var special_rise=d.role=="enemy" and director.is_rising(a) and sprites.draw_corpse_rise(world_canvas,world_position(a.p),a.kind,a.get("body_face",Vector2.RIGHT),a.rise_elapsed)
			if not special_rise:draw_person(world_position(a.p),a.kind,actor_draw_direction(a),a.flash,d.role=="ally",1.0,pose)
			if show_actor_health(a,d.role) and (d.role=="ally" or enemies.find(a) in enemy_health_ids):
				world_healthbar(world_position(a.p)+Vector2(-19,-78 if sprites.can_draw(a.kind) else -47),38,a.hp/a.max,Color("e57f63") if a.hp/a.max<=0.30 else (Color("8ac6a2") if d.role=="ally" else Color("c17065")))
			if a.kind=="shield" and d.role=="ally":
				var blade=infantry_slash_state(a)
				if not blade.is_empty():sprites.draw_slash(world_canvas,world_position(blade.position),blade.direction,blade.age,blade.reach)
			if d.role=="enemy" and director.is_rising(a):
				world_canvas.draw_arc(world_position(a.p),27,-PI/2,-PI/2+TAU*(a.rise_elapsed/a.rise_duration),24,Color("c59b67"),2)
				world_txt(world_position(a.p)+Vector2(-24,-61),"苏醒中",12,Color("d6b483"))
			if a.kind=="boss" and a.phase>0:
				world_canvas.draw_arc(world_position(a.p),100+(1.05-a.phase)*70,0,TAU,60,Color("f38761"),3)
	if slash>0: sprites.draw_slash(world_canvas,world_position(hero),attack_direction,0.35-slash,reach)
	for b in bullets:
		var p=world_position(b.p)
		if b.friendly:
			world_canvas.draw_line(p-b.v.normalized()*20,p,Color("e9d6a1"),3); world_canvas.draw_circle(p,3,Color("fff0c1"))
		else:
			world_canvas.draw_circle(p,10,Color(0.9,0.22,0.12,0.2)); world_canvas.draw_circle(p,5,Color("f37b4e")); world_canvas.draw_line(p-b.v.normalized()*12,p,Color("ffca86"),2)
	for f in effects: world_canvas.draw_arc(world_position(f.p),f.radius*(1.1-f.life),0,TAU,24,f.color,2)
	# The hero's bar is drawn last in world space so effects never obscure it.
	if state!="title":world_healthbar(world_position(hero)+Vector2(-27,15),54,hero_health_ratio(),Color("e9755f") if hero_health_ratio()<=0.30 else Color("8bd0a2"),6)

func draw_battlefield():
	# Layered mud, roads, burned standards, broken spears and fire pits.
	for y in range(-1,ceili(WORLD_VIEW_SIZE.y/64)+1):
		for x in range(-1,ceili(WORLD_VIEW_SIZE.x/64)+1):
			var pos=Vector2(x*64-fmod(camera.x,64),y*64-fmod(camera.y,64))
			var n=sin((x+int(camera.x/64))*23.1+(y+int(camera.y/64))*87.3)
			world_canvas.draw_rect(Rect2(pos,Vector2(64,64)),Color(0.15+n*0.008,0.18+n*0.009,0.16+n*0.008))
	for d in decor:
		var p=world_position(d.p)
		if not world_view_rect(50).has_point(d.p):continue
		if d.kind==0:
			world_canvas.draw_set_transform(p,0,Vector2(1,0.45)); world_canvas.draw_circle(Vector2.ZERO,d.size,Color("202722")); world_canvas.draw_set_transform(Vector2.ZERO)
		elif d.kind==1:
			world_canvas.draw_line(p+Vector2(-8,7),p+Vector2(5,-17),Color("777360"),3); world_canvas.draw_line(p+Vector2(-4,-3),p+Vector2(8,3),Color("474d46"),3)
		elif d.kind==2:
			world_canvas.draw_circle(p,12,Color("1b211f")); world_canvas.draw_line(p+Vector2(-7,4),p+Vector2(7,-4),Color("695045"),4)
		elif d.kind==3:
			world_canvas.draw_line(p,p+Vector2(1,-35),Color("696658"),3); world_canvas.draw_colored_polygon(PackedVector2Array([p+Vector2(1,-34),p+Vector2(21,-28),p+Vector2(14,-17),p+Vector2(1,-19)]),Color("694745"))
		else:
			world_canvas.draw_circle(p,15,Color(0.65,0.30,0.1,0.07)); world_canvas.draw_circle(p,4+sin(time*5+d.a)*2,Color("9c653a"))

func infantry_slash_state(actor:Dictionary)->Dictionary:
	# Reuse the seven drawn sword phases + transparent end at a much smaller size.
	# The ally attack clock is also the 0.12-second single-hit damage clock.
	var age=float(actor.get("attack_age",-1.0))
	if actor.get("kind","")!="shield" or float(actor.get("hp",0))<=0 or age<0 or age>=0.35:return {}
	var direction:Vector2=actor.get("attack_direction",Vector2.RIGHT)
	if direction.is_zero_approx():direction=Vector2.RIGHT
	direction=direction.normalized()
	return {"position":actor.p+Vector2(0,-24)+direction*12,"direction":direction,"age":age,"reach":42.0}

func actor_draw_direction(actor:Dictionary)->Vector2:
	if actor.kind=="shield" and (actor.get("guard",false) or actor.get("block",0.0)>0):return actor.get("face",Vector2.RIGHT)
	if actor.get("attack_age",-1.0)>=0 or actor.get("phase",0.0)>0:return actor.get("attack_direction",actor.get("face",Vector2.RIGHT))
	return actor.get("face",Vector2.RIGHT)

func draw_person(p:Vector2,kind:String,dir:Vector2,flash:float,friendly:bool=false,alpha:float=1.0,pose:int=0):
	if sprites.can_draw(kind):
		sprites.draw_keypose(world_canvas,p,kind,dir,pose,flash,alpha)
		return
	var boss=kind=="boss"; var scale_value=1.7 if boss else 1.0
	world_canvas.draw_set_transform(p,0,Vector2.ONE*scale_value)
	world_canvas.draw_set_transform(p,0,Vector2(scale_value,scale_value*0.45)); world_canvas.draw_circle(Vector2(0,5),19,Color(0.02,0.04,0.04,0.45*alpha)); world_canvas.draw_set_transform(p,0,Vector2.ONE*scale_value)
	var cloth=Color("bc7853") if kind=="hero" else Color("607e82")
	if kind=="archer": cloth=Color("758764")
	if kind=="undead": cloth=Color("737765")
	if kind in ["demon","caster","boss"]: cloth=Color("82504d")
	if flash>0: cloth=cloth.lightened(0.5)
	cloth.a=alpha
	var step=sin(time*10+p.x*0.01)*3
	world_canvas.draw_line(Vector2(-7,-3),Vector2(-8,10+step),Color("242a2a"),7); world_canvas.draw_line(Vector2(7,-3),Vector2(8,10-step),Color("242a2a"),7)
	world_canvas.draw_colored_polygon(PackedVector2Array([Vector2(-12,-22),Vector2(12,-22),Vector2(16,1),Vector2(0,6),Vector2(-16,1)]),cloth.darkened(0.2))
	world_canvas.draw_style_box(style(cloth),Rect2(-10,-28,20,25))
	world_canvas.draw_line(Vector2(-7,-20),Vector2(8,-11),Color("b0a58a"),2)
	var skin=Color("bcb49b") if kind=="undead" else Color("c9aa86")
	if kind in ["demon","caster","boss"]: skin=Color("a56c61")
	world_canvas.draw_circle(Vector2(0,-34),8,skin)
	world_canvas.draw_arc(Vector2(0,-34),8,PI,TAU,12,cloth.lightened(0.22),5)
	world_canvas.draw_line(Vector2(-4,-34),Vector2(4,-34),Color("242d2d"),3)
	if kind in ["demon","boss"]:
		world_canvas.draw_line(Vector2(-7,-37),Vector2(-13,-48),Color("d7b694"),4); world_canvas.draw_line(Vector2(7,-37),Vector2(13,-48),Color("d7b694"),4)
	if kind=="hero":
		world_canvas.draw_colored_polygon(PackedVector2Array([Vector2(-11,-24),Vector2(-18,8),Vector2(-4,4),Vector2(-3,-18)]),Color("b9855b"))
		world_canvas.draw_line(Vector2(13,-9),Vector2(26,-35),Color("d7e1dc"),4); world_canvas.draw_line(Vector2(13,-17),Vector2(23,-12),GOLD,3)
	elif kind=="shield":
		var side=1 if dir.x>=0 else -1
		world_canvas.draw_colored_polygon(PackedVector2Array([Vector2(side*9,-27),Vector2(side*25,-23),Vector2(side*23,-5),Vector2(side*15,1),Vector2(side*8,-7)]),Color("adb5a7"))
		world_canvas.draw_line(Vector2(side*16,-22),Vector2(side*16,-7),Color("657b83"),3)
		world_canvas.draw_line(Vector2(-side*12,-8),Vector2(-side*18,-34),Color("d7ddc9"),3)
	elif kind=="archer":
		world_canvas.draw_arc(Vector2(12,-18),17,-1.4,1.4,12,Color("c6a476"),3); world_canvas.draw_line(Vector2(15,-35),Vector2(15,-1),Color("c7c4a2"),1)
	elif kind=="caster":
		world_canvas.draw_line(Vector2(15,2),Vector2(18,-39),Color("afa087"),3); world_canvas.draw_circle(Vector2(18,-39),5,Color("e98e58"))
	else: world_canvas.draw_line(Vector2(14,-7),Vector2(26,-29),Color("a7a18b"),4)
	if friendly:
		world_canvas.draw_arc(Vector2(0,8),19,0,PI,14,Color("7aa9ad"),2)
	world_canvas.draw_set_transform(Vector2.ZERO)

func healthbar(p:Vector2,width:float,ratio:float,col:Color):
	draw_rect(Rect2(p,Vector2(width,5)),Color("1b2427")); draw_rect(Rect2(p,Vector2(width*clampf(ratio,0,1),5)),col)

func draw_hud():
	# A narrow XP edge, clock and level leave the entire combat field readable.
	draw_rect(Rect2(0,0,VIEWPORT_SIZE.x,8),Color("101d20"))
	draw_rect(Rect2(0,1,VIEWPORT_SIZE.x*experience_ratio(),5),Color("70b9ca"))
	draw_rect(Rect2(587,13,106,32),Color(0.025,0.04,0.045,0.66))
	var clock_label="%02d:%02d"%[int(time)/60,int(time)%60]
	txt(Vector2(640-font.get_string_size(clock_label,HORIZONTAL_ALIGNMENT_LEFT,-1,24).x*0.5,37),clock_label,24,Color("f2ead7"))
	txt(Vector2(1182,32),"Lv. %d"%level,16,Color("d6daca"))
	var stage_index=terrain.stage_index_at(hero)
	txt(Vector2(20,32),["Ⅰ  人类残营","Ⅱ  破阵战场","Ⅲ  焦土战场","Ⅳ  恶魔营地"][stage_index],16,Color("b8c9bb"))
	draw_camp_directions()
	txt(Vector2(900,57),controls.prompt("Q 圣闪 · Tab 地图 · Esc 暂停", "X/RB 圣闪 · View 地图 · Start 暂停"),13,Color("b7c4bc"))
	# Brief rescue/boss events sit at the lower left rather than across the hero.
	if notice_time>0 and not notice.is_empty() and not notice.begins_with("精英"):
		var message=compact_notice()
		var width=minf(490,font.get_string_size(message,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x+24)
		draw_rect(Rect2(18,641,width,29),Color(0.035,0.055,0.055,0.80))
		txt(Vector2(30,661),message,15,Color("e8d298"))
	var boss=visible_boss()
	if not boss.is_empty():
		draw_rect(Rect2(409,678,462,29),Color(0.035,0.045,0.045,0.86))
		txt(Vector2(421,690),"恶魔军士长 · 断翼者",12,Color("e6b89b"))
		healthbar(Vector2(421,696),438,boss.hp/boss.max,Color("c56c57"))

func compact_notice()->String:
	if notice.begins_with("听见") or notice.begins_with("求救已"):return "听见求救 · 残部正在交战"
	if notice.begins_with("残部濒危"):return "残部濒危 · 立即清除围兵"
	if notice.begins_with("援救太迟"):return "援救太迟 · 一支残部已阵亡"
	if notice.begins_with("同伴加入"):return "同伴加入 · "+("剑盾兵" if "剑盾兵" in notice else "弓箭手")
	if notice.begins_with("恶魔军士长"):return "军士长到来 · 留意蓄力攻击"
	return notice

func draw_camp_directions():
	for c in camps:
		var marker=camp_marker(c)
		if not marker.visible:continue
		var q:Vector2=marker.position
		var direction:Vector2=marker.direction
		var critical:bool=marker.critical
		var col=Color("ee8a69") if critical else Color("d6c28a")
		var side=Vector2(-direction.y,direction.x)
		draw_colored_polygon(PackedVector2Array([q+direction*8,q-direction*6+side*5,q-direction*6-side*5]),col)
		txt(q-direction*21+Vector2(-6,5),"!" if critical else "救",13,col)

func draw_audio_controls():
	if not audio_controller or state!="pause":return
	var queued="（待切换）" if audio_controller.paused and audio_controller.selected_track!=audio_controller.current_track else ""
	txt(Vector2(151,539),"音乐  %s%s"%[audio_controller.get_track_name(),queued],17,Color("c5cbbb"))
	txt(Vector2(151,572),"[ / ] 音乐 %d%%     - / = 总音量 %d%%     M 静音 / 恢复"%[roundi(audio_controller.music_gain*100),roundi(volume*100)],16,Color("b7c4bc"))

func draw_pause_details():
	panel(Rect2(120,65,1040,565),Color(0.035,0.055,0.065,0.97))
	txt(Vector2(150,116),"战场已暂停",35)
	txt(Vector2(830,110),"%02d:%02d   等级 %d"%[int(time)/60,int(time)%60,level],22,Color("d0d6c5"))
	txt(Vector2(151,153),controls.prompt("ESC / Enter 继续    R 重新开始    TAB 行军图", "A / B / Start 继续    Y 重新开始    View 行军图"),17,Color("a7b9b1"))
	draw_line(Vector2(150,173),Vector2(1130,173),Color("394846"),1)
	txt(Vector2(151,208),"勇者  %d / %d      经验  %d / %d"%[maxi(0,int(hp)),int(max_hp),xp,needed],19)
	txt(Vector2(151,243),"存活同伴 %d    已救 %d / 4    阵亡 %d"%[allies.size(),rescued,fallen],18,Color("b9c9b8"))
	txt(Vector2(151,277),"击杀 %d    弓箭命中 %d    盾挡 %d"%[kills,arrow_hits,blocks],17,Color("a9b8b1"))
	txt(Vector2(151,329),"目标 · 坚守20分钟，清灭最终军团",21)
	txt(Vector2(151,364),"5 / 10 / 15分钟：军团全灭获升级与20生命恢复",17,Color("bcc5b5"))
	txt(Vector2(151,393),"人类营地援救 %d / 4；20分钟落桥，首领与大军出营"%rescued,17,Color("bcc5b5"))
	txt(Vector2(151,436),controls.prompt("WASD / 方向键移动 · 自动挥刀 · Q 圣闪", "左摇杆 / 十字键移动 · 自动挥刀 · X / RB 圣闪"),16,Color("9fb3ab"))
	txt(Vector2(151,464),"靠近750px开战；清围后靠近营救，继承剩余生命",16,Color("9fb3ab"))
	txt(Vector2(805,208),"同行残部",20)
	if allies.is_empty():txt(Vector2(805,244),"尚未集结同伴",16,Color("8eaaa0"))
	for i in range(allies.size()):
		var ally=allies[i]
		var y=240+i*39
		txt(Vector2(805,y),("剑盾兵" if ally.kind=="shield" else "弓箭手")+"   %d / %d"%[maxi(0,int(ally.hp)),int(ally.max)],16,Color("b9c9b8"))
		healthbar(Vector2(805,y+9),275,ally.hp/ally.max,Color("8ac6a2") if ally.hp/ally.max>0.30 else Color("d87f63"))
	draw_line(Vector2(150,499),Vector2(1130,499),Color("394846"),1)
	draw_audio_controls()

func draw_overlay():
	if state=="map":
		draw_tactical_map();return
	draw_rect(Rect2(0,0,1280,720),Color(0.02,0.04,0.05,0.86))
	if state=="title":
		txt(Vector2(170,177),"余 烬 集 结",58)
		txt(Vector2(174,226),"ASHEN MUSTER  /  第一关：战场逃生",21,Color("a5b7b2"))
		txt(Vector2(175,290),"人类败了。战场上，阵亡士兵再次站起。",24)
		txt(Vector2(175,333),"你是幸存的勇者。救出同伴，集结残兵，击穿恶魔军士长的封锁。",21)
		txt(Vector2(175,402),controls.prompt("WASD / 方向键移动 · 自动挥刀 · Q 圣闪 · 清围后靠近营救", "左摇杆 / 十字键移动 · 自动挥刀 · X / RB 圣闪 · 清围后靠近营救"),19)
		txt(Vector2(175,439),"进入求救范围才开战；残部会反击也会阵亡，救出继承剩余生命。",19)
		txt(Vector2(175,476),controls.prompt("升级：1 / 2 / 3 或左右 + Enter · ESC 暂停 · Tab 地图 · M 静音", "升级：左右 + A · Start 暂停 · B 返回 · View 地图"),19)
		txt(Vector2(175,509),"5/10/15分钟清军团领奖；20分钟落桥，首领和最终军团全灭才胜利",18)
		panel(Rect2(175,530,690,61)); txt(Vector2(205,570),controls.prompt("Enter / 点击开始    20分钟战场 · 营救、清军团、决战", "A / Start 开始    20分钟战场 · 营救、清军团、决战"),24)
	elif state=="pause":
		draw_pause_details()
	elif state=="upgrade":
		txt(Vector2(444,205),"余烬中成长",38); txt(Vector2(280,249),controls.prompt("战斗已暂停 · 1 / 2 / 3、点击或左右 + Enter", "战斗已暂停 · 左摇杆 / 十字键左右选择，A 确认"),21)
		var names=["1   锋芒","2   迅击","3   整顿军阵"]
		var descs=["刀光伤害 +9\n攻击范围 +8","攻击间隔缩短 14%\n更快击退包围","勇者上限 +15 / 恢复 45\n全体同伴恢复 42"]
		for i in range(3):
			var card := Rect2(160+i*330,285,310,220)
			panel(card)
			if i == upgrade_selection:
				draw_rect(card.grow(4), GOLD, false, 3)
				txt(Vector2(185+i*330,478),controls.prompt("Enter 确认", "A 确认"),17,GOLD)
			txt(Vector2(185+i*330,337),names[i],26)
			var lines=descs[i].split("\n")
			for j in range(lines.size()): txt(Vector2(185+i*330,393+j*35),lines[j],18,Color("b3c1b8"))
	else:
		txt(Vector2(340,228),"你们突破了封锁" if state=="win" else "余烬仍未熄灭",43)
		txt(Vector2(350,289),"魔王仍在北方。活下来的人，才有下一场战斗。" if state=="win" else "勇者倒下了。调整路线，先救同伴，再迎战军士长。",20)
		txt(Vector2(405,355),"救出 %d 人  ·  生还 %d 人  ·  阵亡 %d 人"%[rescued,allies.size(),fallen],24)
		txt(Vector2(405,400),"击杀 %d  /  等级 %d  /  用时 %02d:%02d"%[kills,level,int(time)/60,int(time)%60],23)
		panel(Rect2(420,470,440,70)); txt(Vector2(468,515),controls.prompt("R / Enter / 点击，再次集结", "A / Y，再次集结"),25)

func draw_tactical_map():
	draw_rect(Rect2(0,0,1280,720),Color("101d20"))
	txt(Vector2(50,49),"四阶段战场 · 行军图",28)
	txt(Vector2(50,78),controls.prompt("TAB / ESC 返回 · 战斗暂停 · 残部只在听见求救后标记", "View / B / Start 返回 · 战斗暂停 · 残部只在听见求救后标记"),17,Color("b7c9b2"))
	var origin=Vector2(55,105)
	var scale_value=0.106
	var bounds=Rect2(origin,WORLD*scale_value)
	draw_rect(bounds,Color("303b32"))
	for road in terrain.routes:
		for i in range(1,road.size()):draw_line(origin+road[i-1]*scale_value,origin+road[i]*scale_value,Color("786746"),3)
	for b in terrain.blockers:
		draw_rect(Rect2(origin+b.rect.position*scale_value,b.rect.size*scale_value),Color("1b2228") if b.kind=="trench" else Color("85866c"))
	for bridge in terrain.bridges:draw_rect(Rect2(origin+bridge.position*scale_value,bridge.size*scale_value),Color("c69858"))
	for c in camps:
		if not c.get("discovered",false):continue
		var q=origin+c.p*scale_value
		var status=str(c.get("status","dormant"))
		var col=Color("80cca0");var label="已救"
		if status=="dead":col=Color("a69d92");label="阵亡"
		elif status!="rescued":
			var health=float(c.fighter.hp)/float(c.fighter.max)
			col=Color("e66f48") if health<0.3 else Color("edce75")
			label=("濒危" if health<0.3 else ("可救" if status=="cleared" else "交战"))+" %d"%int(c.fighter.hp)
		draw_circle(q,7,col);txt(q+Vector2(11,5),label,15,col)
	var gate=origin+BOSS_POSITION*scale_value
	draw_rect(Rect2(gate-Vector2(9,9),Vector2(18,18)),Color("b96749"));txt(gate+Vector2(-60,-16),"东部恶魔营地",16)
	draw_circle(origin+hero*scale_value,7,Color("fcf0c2"));txt(origin+hero*scale_value+Vector2(10,-8),"勇者",16)
	txt(Vector2(1135,151),"行军目标",16)
	txt(Vector2(1135,180),"西营援救",15)
	txt(Vector2(1135,209),"中部突围",15)
	txt(Vector2(1135,248),"进入东营",15)
	txt(Vector2(1135,277),"击败首领",15)
