extends Node3D
## Visible source bodies are atlas-exact MultiMeshes, never thousands of sprites.
## A full billboard basis keeps the authored source root on the 3D floor.
var renderer: RefCounted
var game: Node3D
var batches: Dictionary = {}
var mesh_cache: Dictionary = {}
var material_cache: Dictionary = {}
var source_signature := ""
var visible_source_count := 0
var prop_records: Dictionary = {}
var prop_regions: Dictionary = {}
var visible_prop_count := 0
var contact_shadows:MultiMeshInstance3D
const REST_TINT:=Color(0.8,0.8,0.8,1.0)

func setup(owner_game: Node3D, source_renderer: RefCounted) -> void:
	game=owner_game
	renderer=source_renderer
	contact_shadows=MultiMeshInstance3D.new();contact_shadows.name="QuietCorpseContactShadows"
	contact_shadows.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader:=Shader.new()
	shader.code="shader_type spatial; render_mode unshaded, blend_mix, depth_draw_never, cull_disabled; void fragment(){ float r=length(UV*2.0-1.0); ALBEDO=vec3(0.035,0.045,0.038); ALPHA=(1.0-smoothstep(0.25,1.0,r))*0.22; }"
	var mat:=ShaderMaterial.new();mat.shader=shader;contact_shadows.material_override=mat
	add_child(contact_shadows)

func reset() -> void:
	for batch in batches.values(): batch.queue_free()
	batches.clear()
	prop_records.clear()
	prop_regions.clear()
	source_signature=""

func _packet_for(body: Dictionary) -> Dictionary:
	return renderer.corpse_source_for_slot(body)

func sync(logic: Node2D, rect: Rect2) -> void:
	var bodies: Array = logic.corpse_field.bodies_in_rect(rect.grow(130.0))
	visible_source_count=bodies.size()
	# A consumed body disappears in the same sync as its first live rise frame.
	var signature: String=""
	for body in bodies: signature+=String(body.corpse_id)+";"
	for enemy in logic.enemies:
		if String(enemy.get("rise_path",""))!="zombie_fallen":continue
		if float(enemy.get("rise_elapsed",-1))<1.5:continue
		var id: String=String(enemy.get("corpse_id",""))
		if id.is_empty() or prop_records.has(id):continue
		var source:Dictionary=logic.corpse_field.bodies_by_id.get(id,{})
		if source.is_empty():continue
		var packet: Dictionary=renderer.settled_prop_for(source)
		if packet.is_empty():continue
		var record:Dictionary={"p":source.p,"face":source.get("face",Vector2.RIGHT),"packet":packet,"id":id}
		prop_records[id]=record
		var region:=Vector2i(floori(source.p.x/1200.0),floori(source.p.y/1200.0))
		if not prop_regions.has(region):prop_regions[region]=[]
		prop_regions[region].append(record)
	var props: Array=[]
	var start:=Vector2i(floori(rect.position.x/1200.0),floori(rect.position.y/1200.0))
	var end:=Vector2i(floori(rect.end.x/1200.0),floori(rect.end.y/1200.0))
	for y in range(start.y,end.y+1):
		for x in range(start.x,end.x+1):
			for record in prop_regions.get(Vector2i(x,y),[]):
				if rect.grow(100).has_point(record.p):props.append(record);signature+="prop:"+record.id+";"
	visible_prop_count=props.size()
	if signature==source_signature:return
	source_signature=signature
	_sync_contact_shadows(bodies)
	var groups:Dictionary={}
	for body in bodies:
		var packet:Dictionary=_packet_for(body)
		if packet.is_empty():continue
		_group_packet(groups,packet,body.p,body.get("face",Vector2.RIGHT))
	for prop in props:_group_packet(groups,prop.packet,prop.p,prop.face)
	for key in batches:
		if not groups.has(key):batches[key].visible=false
	for key in groups:
		var group:Dictionary=groups[key]
		var batch:MultiMeshInstance3D
		if batches.has(key):batch=batches[key]
		else:
			batch=MultiMeshInstance3D.new();batch.name="CorpseAtlasBatch_"+str(batches.size())
			batch.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			batch.material_override=_material(group.packet.texture)
			add_child(batch);batches[key]=batch
		var instances:=MultiMesh.new()
		instances.transform_format=MultiMesh.TRANSFORM_3D
		instances.mesh=_mesh(key,group.packet,group.flipped)
		instances.instance_count=group.positions.size()
		for index in range(group.positions.size()):
			var p:Vector2=group.positions[index]/50.0
			instances.set_instance_transform(index,Transform3D(game.camera.global_basis,Vector3(p.x,game.terrain.floor_height(p)+0.035,p.y)))
		batch.multimesh=instances;batch.visible=true

func _group_packet(groups:Dictionary,packet:Dictionary,p:Vector2,face:Vector2) -> void:
	var flipped:bool=face.x<0
	var key:String=str(packet.texture.get_instance_id())+":"+str(packet.frame.source_rect)+":"+str(packet.frame.ground_anchor)+":"+str(flipped)
	if not groups.has(key):groups[key]={"packet":packet,"flipped":flipped,"positions":[]}
	groups[key].positions.append(p)

func _material(texture:Texture2D) -> StandardMaterial3D:
	var key:int=texture.get_instance_id()
	if material_cache.has(key):return material_cache[key]
	var material:=StandardMaterial3D.new()
	material.albedo_texture=texture
	material.albedo_color=REST_TINT
	material.shading_mode=BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.texture_filter=BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold=0.18
	material.cull_mode=BaseMaterial3D.CULL_DISABLED
	material.roughness=1.0
	material_cache[key]=material
	return material

func _mesh(key:String,packet:Dictionary,flipped:bool) -> ArrayMesh:
	if mesh_cache.has(key):return mesh_cache[key]
	var frame:Dictionary=packet.frame
	var r:Array=frame.source_rect
	var anchor:=Vector2(frame.ground_anchor[0],frame.ground_anchor[1])
	var scale_px:float=float(frame.get("pixel_scale",0.008))
	var x0:float=-anchor.x*scale_px;var x1:float=(float(r[2])-anchor.x)*scale_px
	if flipped:x0=-x0;x1=-x1
	var y0:float=(anchor.y-float(r[3]))*scale_px;var y1:float=anchor.y*scale_px
	var texture_size:Vector2=packet.texture.get_size()
	var u0:float=float(r[0])/texture_size.x;var u1:float=float(r[0]+r[2])/texture_size.x
	var v0:float=float(r[1])/texture_size.y;var v1:float=float(r[1]+r[3])/texture_size.y
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var positions: Array[Vector3]=[Vector3(x0,y0,0),Vector3(x1,y0,0),Vector3(x1,y1,0),Vector3(x0,y1,0)]
	var uvs: Array[Vector2]=[Vector2(u0,v1),Vector2(u1,v1),Vector2(u1,v0),Vector2(u0,v0)]
	for i in [0,1,2,0,2,3]:st.set_normal(Vector3(0,0,1));st.set_uv(uvs[i]);st.add_vertex(positions[i])
	var mesh:ArrayMesh=st.commit();mesh_cache[key]=mesh;return mesh

func get_stats() -> Dictionary:
	return {"source_bodies_visible":visible_source_count,"source_batches":batches.size(),"settled_helmets_visible":visible_prop_count,"source_sprite_nodes":0}

func _sync_contact_shadows(bodies:Array) -> void:
	var mesh:=PlaneMesh.new();mesh.size=Vector2(2.6,0.8)
	var batch:=MultiMesh.new();batch.transform_format=MultiMesh.TRANSFORM_3D;batch.mesh=mesh;batch.instance_count=bodies.size()
	for index in range(bodies.size()):
		var p:Vector2=bodies[index].p/50.0
		batch.set_instance_transform(index,Transform3D(Basis.IDENTITY,Vector3(p.x,game.terrain.floor_height(p)+0.018,p.y)))
	contact_shadows.multimesh=batch
