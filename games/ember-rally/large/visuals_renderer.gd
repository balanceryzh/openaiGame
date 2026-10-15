extends "res://sprite_renderer.gd"
## The complete level uses the exact first authored rise frame for every source.
## Human paths already carry this contract in v4; demonic origins use their own
## rising atlas rather than switching between unrelated corpse illustrations.
func corpse_source_for_slot(slot:Dictionary) -> Dictionary:
	if String(slot.get("source_type",slot.get("body_kind","human")))=="demon" and corpse_rise_texture!=null and corpse_rise_frames.size()==8:
		var kind:String=String(slot.get("spawn_kind",slot.get("actor_kind","demon")))
		var index:int=4 if kind=="caster" else 0
		var frame:Dictionary=corpse_rise_frames[index].duplicate(true)
		frame["pixel_scale"]=0.00672 if kind=="caster" else 0.006208
		return {"texture":corpse_rise_texture,"frame":frame,"index":index,"path":"demon_rise" if kind=="demon" else "caster_rise"}
	return super.corpse_source_for_slot(slot)

func _init():
	super()
	var manifest:="res://assets/earth_summon/earth_summon_frames.json"
	if FileAccess.file_exists(manifest):
		var data=JSON.parse_string(FileAccess.get_file_as_string(manifest))
		if data is Dictionary and ResourceLoader.exists(String(data.atlas)):
			textures["earth"]=load(String(data.atlas))
			frame_tables["earth"]=data.frames
			for f in frame_tables.earth:f["pixel_scale"]=float(data.get("pixel_scale",0.0075))

func frame_for(kind:String,moving:bool,clock:float,attack_age:float=-1,hurt:float=0,death_age:float=-1,rise_elapsed:float=-1,block:float=0,guard:bool=false)->int:
	if kind=="earth":
		if rise_elapsed>=0:return mini(3,int(rise_elapsed/0.375))
		if hurt>0:return 8 if hurt>0.095 else 9
		# Body-contact damage uses the same authored lurch; no invented weapon swing.
		if moving or attack_age>=0:return 4+int(clock/0.15)%4
		return 10
	return super.frame_for(kind,moving,clock,attack_age,hurt,death_age,rise_elapsed,block,guard)
