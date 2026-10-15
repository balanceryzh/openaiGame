extends Node3D
## Authored six-frame ash sprites; no procedural opacity or scale animation.
const DURATION := 0.54
const MANIFEST := "res://assets/death_dissolve/death_dissolve_manifest.json"
var game:Node3D
var nodes:Dictionary={}
var frames:Array=[]
var texture:Texture2D
var load_errors:Array=[]
var frame_changes:=0

func setup(owner_game:Node3D)->void:
	game=owner_game
	if not FileAccess.file_exists(MANIFEST):load_errors.append("Missing dissolve frame manifest");return
	var document=JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not document is Dictionary:load_errors.append("Invalid dissolve manifest");return
	var path:String=String(document.get("atlas",""))
	if not path.begins_with("res://"):path=MANIFEST.get_base_dir().path_join(path)
	if not ResourceLoader.exists(path):load_errors.append("Missing dissolve atlas: "+path);return
	texture=load(path)
	frames=document.get("frames",[])
	if frames.size()!=6:load_errors.append("Dissolve needs six independent source frames")

func reset()->void:
	for sprite in nodes.values():sprite.queue_free()
	nodes.clear()

func sync(logic:Node2D,view_rect:Rect2)->void:
	var used:Dictionary={}
	if texture==null or frames.size()!=6:return
	for body in logic.corpses:
		if not bool(body.get("disintegrate",false)) or float(body.elapsed)>=DURATION or not view_rect.grow(140).has_point(body.p):continue
		var id:String=String(body.view_id);used[id]=true
		var sprite:Sprite3D
		if nodes.has(id):sprite=nodes[id]
		else:
			sprite=Sprite3D.new();sprite.name="DefeatedEnemyAsh";sprite.texture=AtlasTexture.new();sprite.texture.atlas=texture
			sprite.billboard=BaseMaterial3D.BILLBOARD_ENABLED;sprite.texture_filter=BaseMaterial3D.TEXTURE_FILTER_NEAREST
			sprite.shaded=false;sprite.double_sided=true;sprite.alpha_cut=SpriteBase3D.ALPHA_CUT_DISCARD;sprite.alpha_scissor_threshold=0.06
			sprite.no_depth_test=false;sprite.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			sprite.set_meta("source_view_id",id);sprite.set_meta("source_frame",-1)
			add_child(sprite);nodes[id]=sprite
		var index:=clampi(int(float(body.elapsed)/0.09),0,5)
		var frame:Dictionary=frames[index]
		var r:Array=frame.source_rect
		var anchor:Array=frame.ground_anchor
		if int(sprite.get_meta("source_frame",-1))!=index:frame_changes+=1
		sprite.set_meta("source_frame",index)
		sprite.texture.region=Rect2(r[0],r[1],r[2],r[3])
		sprite.pixel_size=(3.7 if body.kind=="boss" else 2.4)/512.0
		sprite.offset=Vector2(float(r[2])*0.5-float(anchor[0]),float(anchor[1])-float(r[3])*0.5)
		var point:Vector2=body.p/50.0
		sprite.position=Vector3(point.x,game.terrain.floor_height(point)+0.06,point.y)
		sprite.modulate=Color(0.78,0.83,0.81,1.0) if body.kind in ["undead","earth"] else Color(0.76,0.30,0.25,1.0)
	for id in nodes.keys():
		if not used.has(id):nodes[id].queue_free();nodes.erase(id)
