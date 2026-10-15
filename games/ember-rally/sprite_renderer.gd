extends RefCounted
# Original pixel-style source atlases with immutable source pixels.
# Strict native64/limited-palette conformance is not asserted (see ART_COVERAGE.md).
var enabled=true
var textures:Dictionary={}
var frame_tables:Dictionary={}
var fallback:Texture2D
var fallback_rows={"hero":0,"archer":1,"shield":2,"undead":3}
var fallback_feet={"hero":[Vector2(159,302),Vector2(173,302),Vector2(167,302),Vector2(166,302)],"archer":[Vector2(172,301),Vector2(184,301),Vector2(179,299),Vector2(166,301)],"shield":[Vector2(159,279),Vector2(169,283),Vector2(170,283),Vector2(162,280)],"undead":[Vector2(167,283),Vector2(156,257),Vector2(176,273),Vector2(167,273)]}
var slash_texture:Texture2D
var corpse_rise_texture:Texture2D
var corpse_rise_frames:Array=[]
var ecology_animations:Dictionary={}
var ecology_animation_sets:Dictionary={}
var human_rise_texture:Texture2D
var human_rise_frames:Array=[]
var human_rise_paths:Dictionary={}
var human_rise_manifest:Dictionary={}
var corpse_source_texture:Texture2D
var corpse_source_frames:Array=[]
var corpse_source_manifest:Dictionary={}
var corpse_source_textures:Dictionary={}
var ecology_asset_issues:Array[String]=[]
const SLASH_DURATIONS=[0.05,0.07,0.045,0.045,0.04,0.04,0.03,0.03]
func _init():
	if ResourceLoader.exists("res://art_source/pixel_master_keyposes.png"): fallback=load("res://art_source/pixel_master_keyposes.png")
	for kind in ["hero","undead","archer","shield","demon","caster","boss"]:
		var path=_runtime_texture_path("res://art_source/"+kind+"_actions.png")
		if not ResourceLoader.exists(path): continue
		textures[kind]=load(path)
		var manifest="res://art_source/"+kind+"_actions_frames.json"
		if not FileAccess.file_exists(manifest):manifest="res://art_source/"+kind+"_actions_qa.json"
		if FileAccess.file_exists(manifest):
			var data=JSON.parse_string(FileAccess.get_file_as_string(manifest))
			frame_tables[kind]=data.frames
		else:
			# Only atlases explicitly generated as 4x3 use this temporary grid.
			var size:Vector2=textures[kind].get_size();var table=[]
			for i in range(12):
				var x0=int(i%4*size.x/4);var x1=int((i%4+1)*size.x/4);var y0=int(i/4*size.y/3);var y1=int((i/4+1)*size.y/3)
				table.append({"source_rect":[x0,y0,x1-x0,y1-y0],"ground_anchor":[(x1-x0)*0.5,(y1-y0)*0.92]})
			frame_tables[kind]=table
	if ResourceLoader.exists(_runtime_texture_path("res://assets/vfx/sword_slash_atlas.png")):slash_texture=load(_runtime_texture_path("res://assets/vfx/sword_slash_atlas.png"))
	if ResourceLoader.exists(_runtime_texture_path("res://art_source/corpse_rising_v1.png")):
		corpse_rise_texture=load(_runtime_texture_path("res://art_source/corpse_rising_v1.png"))
		var rise_data=JSON.parse_string(FileAccess.get_file_as_string("res://art_source/CORPSE_RISING_MANIFEST.json"))
		corpse_rise_frames=rise_data.frames
	_load_corpse_ecology()
	_load_human_rise_paths()

func _load_corpse_ecology():
	# Separate authored zombie art; never substitute a recoloured skeleton.
	var zombie_path="res://assets/corpse_ecology/zombie_actions.png"
	var zombie_manifest="res://assets/corpse_ecology/zombie_actions_frames.json"
	if ResourceLoader.exists(zombie_path) and FileAccess.file_exists(zombie_manifest):
		var data=JSON.parse_string(FileAccess.get_file_as_string(zombie_manifest))
		if data is Dictionary and data.get("frames",[]) is Array and not data.get("frames",[]).is_empty():
			textures.zombie=load(zombie_path)
			frame_tables.zombie=data.frames
			ecology_animations=data.get("animations",{})
			ecology_animation_sets.zombie=ecology_animations
			var fixed_scale:float=float(data.get("pixel_scale",0.008))
			for f in frame_tables.zombie:
				# One role scale, not per-pose bbox normalization.
				f["pixel_scale"]=fixed_scale
		else:ecology_asset_issues.append("Invalid zombie_actions_frames.json")
	# The bald candidate is optional; the production headgear variants are enough.
	var source_path=_runtime_texture_path("res://assets/corpse_ecology/corpse_sources.png")
	var source_manifest="res://assets/corpse_ecology/corpse_sources_frames.json"
	if ResourceLoader.exists(source_path) and FileAccess.file_exists(source_manifest):
		var data=JSON.parse_string(FileAccess.get_file_as_string(source_manifest))
		if data is Dictionary and data.get("frames",[]) is Array:
			corpse_source_texture=load(source_path)
			corpse_source_frames=data.frames
			corpse_source_manifest=data
			for f in corpse_source_frames:
				var alternate:String=String(f.get("texture",f.get("asset","")))
				if alternate!="":
					alternate=_asset_path(alternate)
					if ResourceLoader.exists(alternate):corpse_source_textures[alternate]=load(alternate)
		else:ecology_asset_issues.append("Invalid corpse_sources_frames.json")
	elif not FileAccess.file_exists("res://assets/corpse_ecology/helmet_rise_paths_frames.json"):
		ecology_asset_issues.append("Authored corpse rise atlas is not installed")
	# A retained helmet must stay on in every later action, using authored art.
	# The bald candidate is available only as an explicitly recorded QA fallback.
	for key in ["zombie_retained","zombie_fallen","undead_human"]:
		var tex_path:String=_runtime_texture_path("res://assets/corpse_ecology/"+key+"_actions.png")
		var frames_path:String="res://assets/corpse_ecology/"+key+"_actions_frames.json"
		if not ResourceLoader.exists(tex_path) or not FileAccess.file_exists(frames_path):continue
		var data=JSON.parse_string(FileAccess.get_file_as_string(frames_path))
		if not data is Dictionary or data.get("frames",[]).is_empty():continue
		textures[key]=load(tex_path);frame_tables[key]=data.frames
		ecology_animation_sets[key]=data.get("animations",{})
		for f in frame_tables[key]:f["pixel_scale"]=float(data.get("pixel_scale",0.007))
	if not textures.has("zombie") and not (textures.has("zombie_retained") and textures.has("zombie_fallen")):
		ecology_asset_issues.append("Authored zombie action variants are not installed")

func _load_human_rise_paths():
	var tex_path="res://assets/corpse_ecology/helmet_rise_paths_v1.png"
	var manifest_path="res://assets/corpse_ecology/helmet_rise_paths_frames.json"
	if not FileAccess.file_exists(manifest_path):return
	var data=JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not data is Dictionary or data.get("frames",[]).is_empty():return
	tex_path=_asset_path(String(data.get("texture",data.get("asset",tex_path))))
	if not ResourceLoader.exists(tex_path):return
	human_rise_texture=load(tex_path);human_rise_manifest=data
	human_rise_frames=data.frames
	human_rise_paths=data.get("paths",data.get("animations",{}))

func _asset_path(value:String)->String:
	return _runtime_texture_path(value if value.begins_with("res://") else "res://"+value)

func actor_art_kind(a:Dictionary)->String:
	var kind:String=a.kind
	if kind=="undead" and textures.has("undead_human") and (a.get("rise_path","")=="skeleton_transform" or not textures.has("undead")):return "undead_human"
	if kind=="zombie":
		var variant:String="zombie_"+String(a.get("headgear_variant","fallen"))
		if textures.has(variant):return variant
	return kind

func human_rise_path(a:Dictionary)->String:
	if a.get("rise_path","")!="":return String(a.rise_path)
	if a.kind=="undead":return "skeleton_transform"
	if a.kind=="zombie":return "zombie_"+String(a.get("headgear_variant","fallen"))
	return ""

func human_rise_packet(a:Dictionary)->Dictionary:
	if float(a.get("rise",-1.0))<0.0 or human_rise_texture==null:return {}
	var path:String=human_rise_path(a)
	if not human_rise_paths.has(path):return {}
	var frame:int=_sample_animation(human_rise_paths[path],float(a.rise),false,1.5)
	var scales:Dictionary=human_rise_manifest.get("pixel_scale_by_path",{})
	return {"texture":human_rise_texture,"frames":human_rise_frames,"index":frame,"path":path,"pixel_scale":float(scales.get(path,human_rise_manifest.get("pixel_scale",0.007)))}

func settled_prop_for(slot:Dictionary)->Dictionary:
	# Only an independently drawn, separated ground prop may be referenced here.
	# Its original pixels stay untouched; an outside-rect root is intentional.
	if human_rise_texture==null:return {}
	var path:String=String(slot.get("rise_path",""))
	var props=human_rise_manifest.get("settled_props",{})
	var prop:Dictionary={}
	if props is Dictionary:prop=props.get(path,{})
	if props is Array:
		for entry in props:
			if entry.get("path","")==path:prop=entry;break
	if prop.is_empty() and path=="zombie_fallen":prop=human_rise_manifest.get("helmet_rest",{})
	if prop.is_empty() or not prop.has("source_rect"):return {}
	prop=prop.duplicate(true)
	var frame_index:int=int(prop.get("body_frame",prop.get("source_frame",-1)))
	if not prop.has("ground_anchor") and frame_index>=0 and frame_index<human_rise_frames.size():
		var body:Dictionary=human_rise_frames[frame_index]
		var rect:Array=prop.source_rect
		prop["ground_anchor"]=[float(body.source_rect[0])+float(body.ground_anchor[0])-float(rect[0]),float(body.source_rect[1])+float(body.ground_anchor[1])-float(rect[1])]
	if not prop.has("ground_anchor"):return {}
	var scales:Dictionary=human_rise_manifest.get("pixel_scale_by_path",{})
	prop["pixel_scale"]=float(prop.get("pixel_scale",scales.get(path,human_rise_manifest.get("pixel_scale",0.007))))
	return {"texture":human_rise_texture,"frame":prop,"path":path,"appear_at":float(prop.get("appear_at",1.5))}

func corpse_source_for(source_type:String,variant:int=0)->Dictionary:
	if corpse_source_texture==null:return {}
	var matching:Array=[]
	for index in range(corpse_source_frames.size()):
		var f:Dictionary=corpse_source_frames[index]
		if f.get("source_type",f.get("kind",""))==source_type:
			matching.append(index)
	if matching.is_empty():return {}
	var frame_index:int=matching[posmod(variant,matching.size())]
	var selected:Dictionary=corpse_source_frames[frame_index]
	var alternate:String=String(selected.get("texture",selected.get("asset","")))
	var texture:Texture2D=corpse_source_texture if alternate=="" else corpse_source_textures.get(_asset_path(alternate),corpse_source_texture)
	return {"texture":texture,"frame":selected,"index":frame_index}

func corpse_source_for_slot(slot:Dictionary)->Dictionary:
	var path:String=String(slot.get("rise_path",""))
	if slot.get("source_type","")=="human" and human_rise_texture!=null and human_rise_paths.has(path):
		var spec=human_rise_paths[path]
		var sequence:Array=spec if spec is Array else spec.get("frames",[])
		if not sequence.is_empty():
			var index:int=int(sequence[0])
			var frame:Dictionary=human_rise_frames[index].duplicate(true)
			var scales:Dictionary=human_rise_manifest.get("pixel_scale_by_path",{})
			frame["pixel_scale"]=float(scales.get(path,human_rise_manifest.get("pixel_scale",0.0073)))
			return {"texture":human_rise_texture,"frame":frame,"index":index,"path":path}
	return corpse_source_for(String(slot.get("source_type","human")),int(slot.get("variant",0)))

func _ecology_frame(action:String,elapsed:float,loop:bool=false,play_seconds:float=-1,kind:String="zombie")->int:
	return _sample_animation(ecology_animation_sets.get(kind,ecology_animations).get(action,{}),elapsed,loop,play_seconds)

func _sample_animation(animation,elapsed:float,loop:bool=false,play_seconds:float=-1)->int:
	if animation is Array:animation={"frames":animation}
	var sequence:Array=animation.get("frames",[])
	if sequence.is_empty():return 0
	var durations:Array=animation.get("durations",[])
	if durations.size()!=sequence.size():
		durations=[]
		for _i in sequence:durations.append(1.0/float(animation.get("fps",8.0)))
	var total:float=0.0
	for value in durations:total+=maxf(float(value),0.0001)
	var time:float=maxf(elapsed,0.0)
	if play_seconds>0.0:time*=total/play_seconds
	if loop:time=fposmod(time,total)
	for index in range(sequence.size()):
		if time<float(durations[index]):return int(sequence[index])
		time-=float(durations[index])
	return int(sequence.back())

func can_draw(kind:String)->bool:
	if not enabled:return false
	if kind=="zombie" and textures.has("zombie_retained") and textures.has("zombie_fallen"):return true
	if kind=="undead" and textures.has("undead_human"):return true
	return textures.has(kind) or (fallback!=null and fallback_rows.has(kind))
func frame_for(kind:String,moving:bool,clock:float,attack_age:float=-1,hurt:float=0,death_age:float=-1,rise_elapsed:float=-1,block:float=0,guard:bool=false)->int:
	if kind=="zombie" and not textures.has(kind):kind="zombie_fallen" if textures.has("zombie_fallen") else "zombie_retained"
	if kind=="undead" and not textures.has(kind) and textures.has("undead_human"):kind="undead_human"
	if kind.begins_with("zombie") or ecology_animation_sets.has(kind):
		if not textures.has(kind):return -1
		if death_age>=0:return _ecology_frame("death",death_age,false,0.48,kind)
		if rise_elapsed>=0:return _ecology_frame("rise",rise_elapsed,false,1.5,kind)
		if hurt>0:return _ecology_frame("hurt",maxf(0.0,0.19-hurt),false,0.19,kind)
		if attack_age>=0:return _ecology_frame("attack",attack_age,false,0.36,kind)
		return _ecology_frame("walk" if moving else "idle",clock,true,-1,kind)
	if not textures.has(kind):
		if kind=="undead":return clampi(int(rise_elapsed/0.5),0,2) if rise_elapsed>=0 else 3
		return 3 if attack_age>=0 or block>0 else (1+int(clock/0.18)%2 if moving else 0)
	if kind=="hero":
		if death_age>=0:return [12,13,14][mini(2,int(death_age/0.16))]
		if attack_age>=0:
			if attack_age<0.06:return 5
			if attack_age<0.12:return 6
			if attack_age<0.21:return 7
			if attack_age<0.28:return 8
			return 9
		if hurt>0.5:return 10
		if hurt>0.38:return 11
		return [1,2,3,4][int(clock/0.12)%4] if moving else (0 if int(clock)%3 else 15)
	if kind=="undead":
		if death_age>=0:return [13,14,15][mini(2,int(death_age/0.16))]
		if rise_elapsed>=0:return [0,1,2,3][mini(3,int(rise_elapsed/0.375))]
		if attack_age>=0:return 9 if attack_age<0.16 else (10 if attack_age<0.3 else 11)
		if hurt>0:return 12
		# Generated walk sequence remains a drag/shuffle, not certified alternating gait.
		return [5,6,7,8][int(clock/0.15)%4] if moving else 4
	if death_age>=0:return 10 if death_age<0.22 else 11
	if kind=="shield" and block>0:return 6
	if kind=="shield" and guard:return 5
	if attack_age>=0:
		if kind=="shield":return 7 if attack_age>=0.12 and attack_age<0.28 else 8
		if attack_age<0.08:return 5
		if attack_age<0.18:return 6
		if attack_age<0.29:return 7
		return 8
	if hurt>0:return 9
	return [1,2,3,4][int(clock/0.13)%4] if moving else 0
func draw_keypose(owner:Node2D,p:Vector2,kind:String,dir:Vector2,pose:int=0,flash:float=0,opacity:float=1):
	if not can_draw(kind):return
	var tex:Texture2D
	var source:Rect2
	var anchor:Vector2
	if textures.has(kind):
		tex=textures[kind];pose=clampi(pose,0,frame_tables[kind].size()-1)
		var f=frame_tables[kind][pose];var r=f.source_rect
		source=Rect2(r[0],r[1],r[2],r[3]);anchor=Vector2(f.ground_anchor[0],f.ground_anchor[1])
	else:
		tex=fallback;pose=clampi(pose,0,3);var row:int=fallback_rows[kind]
		var x0=int(pose*1254.0/4);var x1=int((pose+1)*1254.0/4);var y0=int(row*1254.0/4);var y1=int((row+1)*1254.0/4)
		source=Rect2(x0,y0,x1-x0,y1-y0);anchor=fallback_feet[kind][pose]
	var scale_factor=0.215 if kind=="archer" else (0.23 if kind=="shield" else 0.25)
	if kind=="boss":scale_factor*=1.5
	var tint=Color(1.2,1.08,1.08,opacity) if flash>0 else Color(1,1,1,opacity)
	owner.draw_set_transform(p.round(),0,Vector2(-1 if dir.x<0 else 1,1))
	owner.draw_texture_rect_region(tex,Rect2(-(anchor*scale_factor).round(),source.size*scale_factor),source,tint)
	owner.draw_set_transform(Vector2.ZERO)
func draw_slash(owner:Node2D,p:Vector2,dir:Vector2,age:float,reach:float):
	if slash_texture==null or age<0 or age>=0.35:return
	var elapsed=age;var frame=0
	while frame<7 and elapsed>=SLASH_DURATIONS[frame]:elapsed-=SLASH_DURATIONS[frame];frame+=1
	var scale_value=reach/225.0
	owner.draw_set_transform(p.round(),dir.angle(),Vector2.ONE*scale_value)
	owner.draw_texture_rect_region(slash_texture,Rect2(-256,-256,512,512),Rect2(frame%4*512,frame/4*512,512,512))
	owner.draw_set_transform(Vector2.ZERO)

func draw_corpse_rise(owner:Node2D,p:Vector2,kind:String,dir:Vector2,elapsed:float=0,opacity:float=1.0)->bool:
	# Four independent authored poses; the simulation owns the harmless 1.5s clock.
	if not enabled or corpse_rise_texture==null or kind not in ["demon","caster"] or corpse_rise_frames.size()!=8:return false
	var index=(0 if kind=="demon" else 4)+clampi(int(elapsed/0.375),0,3)
	var f=corpse_rise_frames[index];var r=f.source_rect
	var anchor=Vector2(f.ground_anchor[0],f.ground_anchor[1])
	var scale_factor=0.194 if kind=="demon" else 0.210
	owner.draw_set_transform(p.round(),0,Vector2(-1 if dir.x<0 else 1,1))
	owner.draw_texture_rect_region(corpse_rise_texture,Rect2(-(anchor*scale_factor).round(),Vector2(r[2],r[3])*scale_factor),Rect2(r[0],r[1],r[2],r[3]),Color(1,1,1,opacity))
	owner.draw_set_transform(Vector2.ZERO)
	return true

# Container-only lossless encoding: every RGBA byte equals the original PNG.
# Originals remain in the source archive; the runtime package carries WebP.
func _runtime_texture_path(p:String)->String:
	var compact:String=p.get_basename()+".webp"
	return compact if ResourceLoader.exists(compact) else p
