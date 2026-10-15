extends "res://actor_hd.gd"
## Source art and immutable per-pose anchors are shared with the preserved slice.
const ApprovedWalk=preload("res://large/approved_walk.gd")
var walk_elapsed:=0.0
var previous_walk_clock:=-1.0
var previous_walk_position:=Vector2.ZERO
var previous_walk_identity:=""
var approved_walk_frame:=-1

func update_actor(a: Dictionary, renderer: RefCounted, clock: float, floor_y: float, camera_right: Vector2):
	sprite.texture=atlas
	super.update_actor(a,renderer,clock,floor_y,camera_right)
	# Hero 308px * .008 = 2.464u; Boss 346px * .01068 = 3.695u.
	# This scales only the actual authored artwork, never collision or attacks.
	sprite.pixel_size = pixel_scale * (1.335 if a.kind == "boss" else 1.0)
	shadow.scale = Vector3.ONE * (1.85 if a.kind == "boss" else 1.0)
	if float(a.rise)>=0.0:
		# The exact same authored first frame has the same resting tint as its
		# ground batch. It brightens smoothly only as the body stands up.
		var standing:float=smoothstep(0.38,1.50,float(a.rise))
		sprite.modulate=sprite.modulate*Color(0.8,0.8,0.8,1.0).lerp(Color.WHITE,standing)
		shadow.visible=true
		shadow.scale=Vector3(lerpf(3.5,1.0,standing),1.0,1.1)
		shadow.material_override.albedo_color.a=lerpf(0.18,0.38,standing)
	else:
		shadow.material_override.albedo_color.a=0.38
	# The necromancer deliberately reuses the caster atlas, with a readable role tint.
	if bool(a.get("source",{}).get("necromancer",false)) and float(a.hurt)<=0 and float(a.death)<0:
		sprite.modulate *= Color(0.72,1.08,0.86,1.0)
	# Bars use camera-projected roots in the original concise 2D HUD.
	hp_back.visible = false
	hp_front.visible = false

	# Per-actor travel drives only playback rate; source art is never warped.
	var identity:String=String(a.get("view_id",""))
	var elapsed:float=maxf(0.0,clock-previous_walk_clock) if previous_walk_clock>=0.0 and identity==previous_walk_identity else 0.0
	var distance:float=Vector2(a.p).distance_to(previous_walk_position) if identity==previous_walk_identity else 0.0
	if identity!=previous_walk_identity:walk_elapsed=0.0
	previous_walk_identity=identity;previous_walk_clock=clock;previous_walk_position=a.p
	approved_walk_frame=-1
	var walking:bool=a.kind in ["hero","shield","archer"] and bool(a.moving) and float(a.death)<0 and float(a.rise)<0 and float(a.attack_age)<0 and float(a.hurt)<=0 and not bool(a.get("guard",false)) and float(a.get("block",0.0))<=0
	if walking:
		var rate:float=clampf(distance/maxf(elapsed,0.00001)/4.1,0.25,1.65) if elapsed>0 else 1.0
		walk_elapsed+=elapsed*rate
		var chosen:Dictionary=ApprovedWalk.packet(a.kind,walk_elapsed)
		if not chosen.is_empty():
			var f:Dictionary=chosen.frame
			approved_walk_frame=int(chosen.index)
			sprite.texture=f.texture
			pixel_scale=float(chosen.pixel_scale);sprite.pixel_size=pixel_scale
			ground_anchor=Vector2(f.anchor[0],f.anchor[1])
			sprite.offset=Vector2(ground_anchor.x-float(f.size[0])*0.5 if sprite.flip_h else float(f.size[0])*0.5-ground_anchor.x,ground_anchor.y-float(f.size[1])*0.5)
			# Force original atlas/root restoration on the next non-walk state.
			last_frame=-99
