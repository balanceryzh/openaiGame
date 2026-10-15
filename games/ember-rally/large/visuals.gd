extends Node3D
## Read-only presentation adapters. Core dictionaries are never rewritten here.
const ActorView=preload("res://large/actor_view.gd")
const SourceRenderer=preload("res://large/visuals_renderer.gd")
const CorpseBatches=preload("res://large/visuals_corpses.gd")
const Overlay=preload("res://large/visuals_overlay.gd")
const Effects=preload("res://large/visuals_effects.gd")
const DeathDissolve=preload("res://large/death_dissolve.gd")
const GroundWeapons=preload("res://ground_weapons_hd.gd")
var game:Node3D
var renderer:RefCounted
var actor_views:Dictionary={}
var actor_pool:Array=[]
var visible_actors:Array=[]
var corpse_batches:Node3D
var effects:Node3D
var death_dissolves:Node3D
var overlay:Node2D
var weapon_chunks:Dictionary={}
var actor_root:Node3D
var weapon_root:Node3D
var source_count:=0

func setup(owner_game:Node3D) -> void:
	game=owner_game;renderer=SourceRenderer.new()
	actor_root=Node3D.new();actor_root.name="VisibleAuthoredActors";add_child(actor_root)
	corpse_batches=CorpseBatches.new();corpse_batches.name="AtlasBatchedCorpseSources";add_child(corpse_batches);corpse_batches.setup(game,renderer)
	effects=Effects.new();effects.name="CombatEffects";add_child(effects);effects.setup(game,renderer)
	death_dissolves=DeathDissolve.new();death_dissolves.name="AuthoredEnemyDissolves";add_child(death_dissolves);death_dissolves.setup(game)
	weapon_root=Node3D.new();weapon_root.name="PreexistingScatteredWeapons";add_child(weapon_root)
	var layer:=CanvasLayer.new();layer.name="ProjectedWorldStatus";layer.layer=2;add_child(layer)
	overlay=Overlay.new();layer.add_child(overlay);overlay.setup(game)

func reset() -> void:
	for view in actor_views.values():view.queue_free()
	for view in actor_pool:view.queue_free()
	actor_views.clear();actor_pool.clear();visible_actors.clear()
	corpse_batches.reset();effects.reset();death_dissolves.reset()
	for chunk in weapon_chunks.values():chunk.queue_free()
	weapon_chunks.clear()

func _packet(source:Dictionary,team:String,clock:float,dying:bool=false) -> Dictionary:
	var kind:String=String(source.get("visual_kind",source.get("kind","undead")))
	var direction:Vector2=source.get("face",Vector2.RIGHT)
	var rise:float=-1.0
	var attack:float=float(source.get("attack_age",-1.0))
	if not dying:
		if game.logic.director.is_rising(source):
			rise=float(source.get("rise_elapsed",0));direction=source.get("body_face",direction)
		elif kind=="shield" and (source.get("guard",false) or float(source.get("block",0))>0):pass
		elif attack>=0 or float(source.get("phase",0))>0:direction=source.get("attack_direction",direction)
		if kind in ["boss","caster"] and float(source.get("phase",0))>0:
			attack=0.02 if float(source.phase)>(0.6 if kind=="boss" else 0.2) else 0.1
	return {"view_id":String(source.get("view_id","")),"kind":kind,"team":team,"p":source.p/50.0,"hp":float(source.get("hp",0 if dying else 1)),"max_hp":float(source.get("max",1)),"dir":direction,"moving":bool(source.get("moving",false)),"hurt":float(source.get("flash",0)),"death":float(source.get("elapsed",source.get("death_age",clock))) if dying else -1.0,"rise":rise,"attack_age":-1.0 if dying else attack,"block":float(source.get("block",0)),"guard":bool(source.get("guard",false)),"rise_path":String(source.get("rise_path","")),"headgear_variant":String(source.get("headgear_variant","retained")),"source":source}

func sync(logic:Node2D,view_rect:Rect2) -> void:
	var visible:Rect2=view_rect.grow(150.0)
	var desired:Dictionary={}
	visible_actors.clear()
	var hero:Dictionary={"view_id":"hero","kind":"hero","team":"hero","p":logic.hero/50.0,"hp":logic.hp,"max_hp":logic.max_hp,"dir":logic.attack_direction if logic.attack_age>=0 else logic.facing,"moving":logic.hero_moving,"hurt":logic.hurt_cd,"death":logic.hero_death_age if logic.state=="lose" else -1.0,"rise":-1.0,"attack_age":logic.attack_age}
	desired.hero=hero;visible_actors.append(hero)
	for source in logic.enemies:
		if visible.has_point(source.p):
			var a:Dictionary=_packet(source,"enemy",logic.time);desired[a.view_id]=a;visible_actors.append(a)
	for source in logic.defenders():
		if visible.has_point(source.p):
			var a:Dictionary=_packet(source,"ally",logic.time);desired[a.view_id]=a;visible_actors.append(a)
	for source in logic.corpses:
		if bool(source.get("disintegrate",false)):continue
		if visible.has_point(source.p):
			var a:Dictionary=_packet(source,"dead",logic.time,true);desired[a.view_id]=a;visible_actors.append(a)
	for id in actor_views.keys():
		if not desired.has(id):
			var view:Node3D=actor_views[id];actor_views.erase(id);view.visible=false
			if actor_pool.size()<24:actor_pool.append(view)
			else:view.queue_free()
	for id in desired:
		var view:Node3D
		if actor_views.has(id):view=actor_views[id]
		else:
			view=actor_pool.pop_back() if not actor_pool.is_empty() else ActorView.new()
			if view.get_parent()==null:actor_root.add_child(view)
			view.name="Actor_"+String(id).replace(":","_");view.visible=true;actor_views[id]=view
		var a:Dictionary=desired[id]
		view.update_actor(a,renderer,logic.time,game.terrain.floor_height(a.p),Vector2.RIGHT)
	corpse_batches.sync(logic,view_rect)
	death_dissolves.sync(logic,view_rect)
	effects.sync(logic,visible,visible_actors)
	_update_weapons(logic,view_rect)
	overlay.queue_redraw()

func _update_weapons(logic:Node2D,view_rect:Rect2) -> void:
	var first:=Vector2i(floori(view_rect.position.x/1200),floori(view_rect.position.y/1200))
	var last:=Vector2i(floori(view_rect.end.x/1200),floori(view_rect.end.y/1200))
	var desired:Dictionary={}
	for y in range(maxi(0,first.y),mini(4,last.y)+1):
		for x in range(maxi(0,first.x),mini(8,last.x)+1):
			var key:=Vector2i(x,y);desired[key]=true
			if weapon_chunks.has(key):continue
			var area:=Rect2(Vector2(key)*1200,Vector2.ONE*1200)
			var sources:Array=[]
			# Include spent originals: re-entering never erases their ground weapons.
			for region_key in logic.corpse_field._region_keys(area):
				for body in logic.corpse_field.regions.get(region_key,[]):
					if area.has_point(body.p):sources.append(body)
			if sources.is_empty():continue
			var normalized:Array=[]
			# Pick a sparse, fixed initial subset per chunk, independent of deaths.
			for source in sources:
				var placement_id:String="%.3f:%.3f"%[source.p.x,source.p.y]
				if posmod(placement_id.hash(),7)==0:
					normalized.append({"p":source.p/50.0,"corpse_id":placement_id.hash()})
			if normalized.size()>9:normalized.resize(9)
			var chunk=GroundWeapons.new();weapon_root.add_child(chunk)
			chunk.build_from_sources(normalized,game.terrain,false)
			weapon_chunks[key]=chunk
	for key in weapon_chunks.keys():
		if not desired.has(key):weapon_chunks[key].queue_free();weapon_chunks.erase(key)

func get_stats() -> Dictionary:
	var result:Dictionary=corpse_batches.get_stats()
	result.merge({"actor_view_count":actor_views.size(),"actor_pool_count":actor_pool.size(),"weapon_chunk_count":weapon_chunks.size(),"visible_actor_count":visible_actors.size()})
	return result
