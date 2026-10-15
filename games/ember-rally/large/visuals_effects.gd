extends Node3D
## Pure 3D projections of authoritative bullet positions and attack clocks.
const SLASH_DURATIONS=[0.05,0.07,0.045,0.045,0.04,0.04,0.03,0.03]
var game:Node3D
var renderer:RefCounted
var bullets:Dictionary={}
var slashes:Dictionary={}
var warnings:Dictionary={}
var summoners:Dictionary={}
var bursts:Array=[]
var gem_batch:MultiMeshInstance3D
var arrow_mesh:ArrayMesh
var fire_mesh:SphereMesh
var arrow_material:StandardMaterial3D
var fire_material:StandardMaterial3D
var gem_mesh:SphereMesh
var gem_material:StandardMaterial3D

func setup(owner_game:Node3D,source_renderer:RefCounted) -> void:
	game=owner_game;renderer=source_renderer
	arrow_material=_material(Color("eddfb8"));fire_material=_material(Color("f47b44"))
	fire_material.emission_enabled=true;fire_material.emission=Color("e85b33");fire_material.emission_energy_multiplier=1.4
	fire_mesh=SphereMesh.new();fire_mesh.radius=0.12;fire_mesh.height=0.24;fire_mesh.radial_segments=8;fire_mesh.rings=4
	arrow_mesh=_make_arrow()
	gem_mesh=SphereMesh.new();gem_mesh.radius=0.10;gem_mesh.height=0.29;gem_mesh.radial_segments=4;gem_mesh.rings=2
	gem_material=_material(Color("81c4b3"))
	gem_batch=MultiMeshInstance3D.new();gem_batch.name="ExperienceGems";gem_batch.material_override=gem_material;gem_batch.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(gem_batch)

func reset() -> void:
	for set in [bullets,slashes,warnings,summoners]:
		for node in set.values():node.queue_free()
		set.clear()
	for node in bursts:node.queue_free()
	bursts.clear()

func _material(color:Color) -> StandardMaterial3D:
	var mat:=StandardMaterial3D.new();mat.albedo_color=color;mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;return mat

func _at(p:Vector2,height:float) -> Vector3:
	var point:=p/50.0
	return Vector3(point.x,game.terrain.floor_height(point)+height,point.y)

func sync(logic:Node2D,view_rect:Rect2,actors:Array) -> void:
	var used:Dictionary={}
	for bullet in logic.bullets:
		if not view_rect.has_point(bullet.p):continue
		var id:String=String(bullet.view_id);used[id]=true
		var node:MeshInstance3D
		if bullets.has(id):node=bullets[id]
		else:
			node=MeshInstance3D.new();node.name="Arrow" if bullet.friendly else "EnemyFireball"
			node.mesh=arrow_mesh if bullet.friendly else fire_mesh;node.material_override=arrow_material if bullet.friendly else fire_material
			node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(node);bullets[id]=node
		node.position=_at(bullet.p,0.85)
		node.rotation.y=atan2(bullet.v.x,bullet.v.y)
	_cleanup(bullets,used)
	used.clear()
	for actor in actors:
		if actor.kind not in ["hero","shield"] or actor.death>=0:continue
		var age:float=float(actor.attack_age)
		if age<0 or age>=0.35:continue
		var id:String=String(actor.view_id);used[id]=true
		var sprite:Sprite3D
		if slashes.has(id):sprite=slashes[id]
		else:
			sprite=Sprite3D.new();sprite.name="AuthoredSwordSlash"
			var atlas:=AtlasTexture.new();atlas.atlas=renderer.slash_texture;sprite.texture=atlas
			sprite.texture_filter=BaseMaterial3D.TEXTURE_FILTER_NEAREST;sprite.shaded=false;sprite.no_depth_test=false
			sprite.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;sprite.rotation_degrees.x=-90
			add_child(sprite);slashes[id]=sprite
		var direction:Vector2=logic.attack_direction if actor.kind=="hero" else actor.source.get("attack_direction",actor.dir)
		var reach:float=float(logic.reach)/50.0 if actor.kind=="hero" else 42.0/50.0
		var frame:=0;var boundary:float=float(SLASH_DURATIONS[0])
		# Exact .12s is the contact frame, matching the authoritative hit event.
		while frame<7 and age+0.000001>=boundary:
			frame+=1
			boundary+=float(SLASH_DURATIONS[frame])
		sprite.texture.region=Rect2((frame%4)*512,floori(float(frame)/4.0)*512,512,512)
		sprite.pixel_size=reach/225.0
		sprite.rotation.y=-atan2(direction.y,direction.x)
		var p:Vector2=actor.p*50.0
		if actor.kind=="shield":p+=direction*12.0
		sprite.position=_at(p,0.66 if actor.kind=="hero" else 0.85)
		sprite.modulate=Color(1,0.9,0.72,0.90)
	_cleanup(slashes,used)
	used.clear()
	for enemy in logic.enemies:
		if not view_rect.has_point(enemy.p):continue
		if bool(enemy.get("necromancer",false)):continue
		var charge:bool=enemy.kind in ["boss","caster"] and float(enemy.get("phase",0))>0
		var rising:bool=logic.director.is_rising(enemy)
		if not charge and not rising:continue
		var id:String=String(enemy.view_id);used[id]=true
		var ring:MeshInstance3D
		if warnings.has(id):ring=warnings[id]
		else:ring=_ring(Color("d2a565") if rising else Color("f38761"));add_child(ring);warnings[id]=ring
		var radius:float=0.53 if rising else ((100+(1.05-float(enemy.phase))*70)/50.0 if enemy.kind=="boss" else 0.7)
		ring.position=_at(enemy.p,0.065);ring.scale=Vector3(radius,1,radius)
	_cleanup(warnings,used)
	var visible_effects:Array=[]
	for effect in logic.effects:
		if view_rect.has_point(effect.p):visible_effects.append(effect)
	while bursts.size()<visible_effects.size():
		var node:MeshInstance3D=_ring(Color.WHITE);add_child(node);bursts.append(node)
	for index in range(bursts.size()):
		var node:MeshInstance3D=bursts[index];node.visible=index<visible_effects.size()
		if not node.visible:continue
		var effect:Dictionary=visible_effects[index]
		var radius:float=maxf(0.03,float(effect.radius)*(1.1-float(effect.life))/50.0)
		node.position=_at(effect.p,0.11);node.scale=Vector3(radius,1,radius);node.material_override.albedo_color=effect.color
	_sync_summoners(logic,view_rect)
	_sync_gems(logic,view_rect)

func _cleanup(nodes:Dictionary,used:Dictionary) -> void:
	for id in nodes.keys():
		if not used.has(id):nodes[id].queue_free();nodes.erase(id)

func _ring(color:Color) -> MeshInstance3D:
	var torus:=TorusMesh.new();torus.inner_radius=0.975;torus.outer_radius=1.0;torus.rings=40;torus.ring_segments=4
	var node:=MeshInstance3D.new();node.mesh=torus;node.material_override=_material(color);node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;return node

func _sync_gems(logic:Node2D,view_rect:Rect2) -> void:
	var gems:Array=[]
	for gem in logic.gems:
		if view_rect.has_point(gem):gems.append(gem)
	var batch:=MultiMesh.new();batch.transform_format=MultiMesh.TRANSFORM_3D;batch.mesh=gem_mesh;batch.instance_count=gems.size()
	for index in range(gems.size()):batch.set_instance_transform(index,Transform3D(Basis.IDENTITY,_at(gems[index],0.15)))
	gem_batch.multimesh=batch

func _make_arrow() -> ArrayMesh:
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The front tip is the exact authoritative hit point. Shaft trails behind it.
	var points:Array[Vector3]=[Vector3(0,0,0),Vector3(-0.07,0,-0.14),Vector3(0.07,0,-0.14),Vector3(-0.016,0,-0.11),Vector3(0.016,0,-0.11),Vector3(0.016,0,-0.50),Vector3(-0.016,0,-0.50),Vector3(-0.055,0,-0.52),Vector3(0,0,-0.43),Vector3(0.055,0,-0.52)]
	for i in [0,1,2,3,4,5,3,5,6,7,8,9]:st.set_normal(Vector3.UP);st.add_vertex(points[i])
	arrow_material.cull_mode=BaseMaterial3D.CULL_DISABLED
	return st.commit()

func _sync_summoners(logic:Node2D,view_rect:Rect2) -> void:
	var used:Dictionary={}
	for enemy in logic.enemies:
		if not bool(enemy.get("necromancer",false)) or float(enemy.get("hp",0))<=0 or not view_rect.grow(500).has_point(enemy.p):continue
		var id:String=String(enemy.view_id);used[id]=true
		var root:Node3D
		if summoners.has(id):root=summoners[id]
		else:
			root=Node3D.new();root.name="NecromancerSourceBoundTelegraph";add_child(root);summoners[id]=root
			var caster_ring:=_ring(Color("85dba6"));caster_ring.mesh.inner_radius=0.88;caster_ring.name="CasterSigil";root.add_child(caster_ring)
			var target_ring:=_ring(Color("b1f0bc"));target_ring.mesh.inner_radius=0.86;target_ring.name="ReservedCorpse";root.add_child(target_ring)
			var tether:=MeshInstance3D.new();tether.name="SourceTether";tether.mesh=BoxMesh.new();tether.mesh.size=Vector3(0.10,0.035,1.0);tether.material_override=_material(Color("72cfa2"));tether.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;root.add_child(tether)
		var sigil:MeshInstance3D=root.get_node("CasterSigil")
		sigil.position=_at(enemy.p,0.075);sigil.scale=Vector3(0.52,1,0.52)
		var target:MeshInstance3D=root.get_node("ReservedCorpse")
		var tether:MeshInstance3D=root.get_node("SourceTether")
		var casting:bool=float(enemy.get("summon_phase",0))>0 and enemy.has("summon_target_p")
		target.visible=casting;tether.visible=casting
		if casting:
			var at:Vector2=enemy.summon_target_p
			var progress:=clampf(float(enemy.get("summon_progress",0)),0,1)
			target.position=_at(at,0.09);target.scale=Vector3.ONE*(0.48+progress*0.28)
			var from:=_at(enemy.p,0.12);var to:=_at(at,0.12)
			tether.position=(from+to)*0.5
			var delta:=to-from;tether.scale=Vector3(1,1,maxf(0.01,delta.length()));tether.rotation.y=atan2(delta.x,delta.z)
	_cleanup(summoners,used)
