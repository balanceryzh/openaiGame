extends Node3D
## Source-pixel-preserving Sprite3D adapter. Every pose uses its own manifest root.
var sprite: Sprite3D
var hp_back: Sprite3D
var hp_front: Sprite3D
var shadow: MeshInstance3D
var atlas: AtlasTexture
var last_frame := -99
var last_kind := ""
var source_frame := -1
var ground_anchor := Vector2.ZERO
var pixel_scale := 0.0080
var bar_tex: ImageTexture
var missing_art_reported := false

func _init():
	sprite = Sprite3D.new()
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.18
	sprite.shaded = true
	sprite.double_sided = true
	sprite.no_depth_test = false
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sprite)
	atlas = AtlasTexture.new()
	sprite.texture = atlas
	shadow = MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = 0.36; disk.bottom_radius = 0.36; disk.height = 0.015; disk.radial_segments = 16
	shadow.mesh = disk
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.055,0.07,0.06,0.38)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = mat
	shadow.position.y = 0.015
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)
	var img := Image.create(1,1,false,Image.FORMAT_RGBA8)
	img.fill(Color.WHITE); bar_tex = ImageTexture.create_from_image(img)
	for front in [false,true]:
		var bar := Sprite3D.new()
		bar.texture = bar_tex; bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		bar.shaded = false; bar.pixel_size = 1.0
		bar.position = Vector3(0,2.65,0)
		bar.modulate = Color(0.08,0.08,0.09,0.85) if not front else Color(0.55,0.85,0.60)
		bar.scale = Vector3(0.88,0.075,1)
		bar.no_depth_test = false
		add_child(bar)
		if front: hp_front=bar; bar.position.y += 0.003
		else: hp_back=bar

func update_actor(a: Dictionary, renderer: RefCounted, clock: float, floor_y: float, camera_right: Vector2):
	var kind: String = a.kind
	var art_kind:String=renderer.actor_art_kind(a) if renderer.has_method("actor_art_kind") else kind
	# A missing dedicated atlas is a visible build issue, never a skeleton alias.
	if not renderer.frame_tables.has(art_kind) or not renderer.textures.has(art_kind):
		sprite.visible=false;shadow.visible=false;hp_back.visible=false;hp_front.visible=false
		if not missing_art_reported:
			push_warning("Missing authored actor atlas: "+kind)
			missing_art_reported=true
		return
	sprite.visible=true
	var frame: int
	if a.has("block") or a.has("guard"):
		frame = renderer.frame_for(art_kind,a.moving,clock,a.attack_age,a.hurt,a.death,a.rise,float(a.get("block",0.0)),bool(a.get("guard",false)))
	else:
		frame = renderer.frame_for(art_kind,a.moving,clock,a.attack_age,a.hurt,a.death,a.rise)
	var frames: Array = renderer.frame_tables[art_kind]
	var tex: Texture2D = renderer.textures[art_kind]
	var rise_atlas: bool = a.rise >= 0.0 and kind in ["demon","caster"] and renderer.corpse_rise_texture!=null and renderer.corpse_rise_frames.size()==8
	if rise_atlas:
		frame = (0 if kind=="demon" else 4) + clampi(int(a.rise/0.375),0,3)
		frames = renderer.corpse_rise_frames
		tex = renderer.corpse_rise_texture
	var frame_tag := art_kind + ("_rise" if rise_atlas else "")
	var human_path:Dictionary=renderer.human_rise_packet(a) if renderer.has_method("human_rise_packet") else {}
	if not human_path.is_empty():
		frame=human_path.index;frames=human_path.frames;tex=human_path.texture
		frame_tag=String(human_path.path)+"_authored_transform"
	if frame!=last_frame or frame_tag!=last_kind:
		last_frame=frame; last_kind=frame_tag; source_frame=frame
		var f: Dictionary = frames[clampi(frame,0,frames.size()-1)]
		var r: Array = f.source_rect
		atlas.atlas=tex; atlas.region=Rect2(r[0],r[1],r[2],r[3])
		ground_anchor=Vector2(f.ground_anchor[0],f.ground_anchor[1])
		pixel_scale = 0.008 if kind not in ["archer","shield"] else (0.00688 if kind=="archer" else 0.00736)
		if f.has("pixel_scale"):pixel_scale=float(f.pixel_scale)
		if rise_atlas: pixel_scale=0.006208 if kind=="demon" else 0.00672
		if not human_path.is_empty():pixel_scale=float(human_path.pixel_scale)
		sprite.pixel_size=pixel_scale
		# Sprite3D geometry has a positive-up pixel offset. Anchor stays at root.
		sprite.offset=Vector2(float(r[2])*0.5-ground_anchor.x,ground_anchor.y-float(r[3])*0.5)
	var facing: float = a.dir.dot(camera_right)
	sprite.flip_h = facing < -0.08
	var current: Dictionary=frames[clampi(frame,0,frames.size()-1)]
	sprite.offset.x=(ground_anchor.x-float(current.source_rect[2])*0.5) if sprite.flip_h else (float(current.source_rect[2])*0.5-ground_anchor.x)
	position=Vector3(a.p.x,floor_y+0.035,a.p.y)
	var opacity: float = clampf(1.0-(a.death-0.36)/0.44,0.0,1.0) if a.death>=0 else 1.0
	sprite.modulate=Color(1.65,0.80,0.66,opacity) if a.hurt>0 else Color(1,1,1,opacity)
	shadow.visible=a.death<0 and a.rise<0
	var show_bar: bool = a.death<0 and a.rise<0 and (a.team=="ally" or (a.team=="enemy" and a.hp<a.max_hp))
	hp_back.visible=show_bar;hp_front.visible=show_bar
	var fraction:float=maxf(0.0,a.hp/a.max_hp)
	hp_front.scale.x=0.86*fraction
	hp_front.modulate=Color(0.45,0.85,0.61) if a.team=="ally" else Color(0.9,0.27,0.21)
