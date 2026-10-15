extends Node3D
## Visual/audio follows the authoritative logic progress; no wall-clock tween.
const AudioController := preload("res://audio_controller.gd")
var terrain: RefCounted
var pivot: Node3D
var chains: Array[MeshInstance3D] = []
var creak: AudioStreamPlayer
var impact: AudioStreamPlayer
var last_clock := -1.0
var last_progress := 0.0
var deck_length := 7.2
var half_width := 5.4

func setup(source: RefCounted, materials: Dictionary) -> void:
	terrain = source
	name = "MainDrawbridge"
	position = Vector3(163.6,0.0,54.8)
	pivot = Node3D.new()
	pivot.name = "HingedDeck"
	add_child(pivot)
	_box(pivot,Vector3(-deck_length*0.5,-0.10,0),Vector3(deck_length,0.12,half_width*2),materials.camp_wood)
	for i in range(24):
		_box(pivot,Vector3(-deck_length+(i+0.5)*0.3,-0.02,0),Vector3(0.285,0.04,half_width*2),materials.camp_wood_light)
	for z in [-half_width+0.20,half_width-0.20]:
		_box(pivot,Vector3(-deck_length*0.5,-0.36,z),Vector3(deck_length,0.42,0.20),materials.camp_wood)
	for z in [-half_width-0.40,half_width+0.40]:
		_box(self,Vector3(-0.35,3.9,z),Vector3(0.48,7.8,0.45),materials.camp_wood)
		var chain := _box(self,Vector3.ZERO,Vector3.ONE,materials.iron)
		chains.append(chain)
	_box(self,Vector3(-0.35,7.65,0),Vector3(0.35,0.32,half_width*2+1.3),materials.camp_wood_light)
	creak = AudioStreamPlayer.new()
	creak.stream = _sound(false)
	add_child(creak)
	impact = AudioStreamPlayer.new()
	impact.stream = _sound(true)
	add_child(impact)
	_bind_audio_bus()
	_apply_pose(terrain.bridge_progress)

func _bind_audio_bus() -> bool:
	# Reuse the existing SFX -> BattlefieldOutput mix. Never leak to Master
	# if a terrain-only preview is created before the audio controller.
	if AudioServer.get_bus_index(AudioController.SFX_BUS) < 0:
		creak.stop()
		impact.stop()
		return false
	creak.bus = AudioController.SFX_BUS
	impact.bus = AudioController.SFX_BUS
	return true

func sync_state(elapsed: float, hero_px: Vector2) -> void:
	var audio_ready := _bind_audio_bus()
	var progress: float = terrain.bridge_progress
	var advanced := elapsed > last_clock and last_clock >= 0.0
	var lowering := progress > 0.0 and progress < 1.0
	var proximity := clampf(1.0-hero_px.distance_to(Vector2(8000,2740))/2200.0,0.0,1.0)
	creak.volume_db = linear_to_db(maxf(0.001,proximity*0.35))
	impact.volume_db = linear_to_db(maxf(0.001,proximity*0.65))
	if audio_ready and lowering and not creak.playing: creak.play()
	creak.stream_paused = not advanced
	impact.stream_paused = not advanced
	if not lowering: creak.stop()
	if audio_ready and progress >= 1.0 and last_progress < 1.0 and advanced: impact.play()
	if elapsed < last_clock or progress < last_progress: impact.stop()
	_apply_pose(progress)
	last_clock = elapsed
	last_progress = progress

func _apply_pose(progress: float) -> void:
	# Cubic easing slows the heavy deck at both ends. Top lands exactly at y=0.
	var eased := smoothstep(0.0,1.0,clampf(progress,0.0,1.0))
	pivot.rotation.z = lerpf(-PI*0.5,0.0,eased)
	for i in range(chains.size()):
		var z := (-1.0 if i==0 else 1.0)*(half_width+0.40)
		var a := Vector3(-0.35,7.5,z)
		var b := pivot.transform*Vector3(-deck_length+0.45,0.02,z)
		var direction := (b-a).normalized()
		var up := Vector3.UP if absf(direction.dot(Vector3.UP))<0.95 else Vector3.RIGHT
		chains[i].transform = Transform3D(Basis.looking_at(direction,up).scaled_local(Vector3(0.085,0.085,a.distance_to(b))),(a+b)*0.5)
	set_meta("progress",progress)
	set_meta("passable",terrain.bridge_open)

func _box(parent: Node3D, at: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material
	node.position = at
	parent.add_child(node)
	return node

func _sound(thump: bool) -> AudioStreamWAV:
	# Original procedural chain/grinding and landing sound, no external assets.
	var rate := 22050
	var duration := 0.65 if thump else 1.0
	var samples := int(rate*duration)
	var bytes := PackedByteArray()
	bytes.resize(samples*2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9031 if thump else 1138
	for i in range(samples):
		var t := float(i)/rate
		var noise := rng.randf_range(-1.0,1.0)
		var value := 0.0
		if thump:
			value = (sin(TAU*58.0*t)*0.55+noise*0.30)*exp(-t*8.0)*minf(t*180.0,1.0)
		else:
			var pulse := pow(0.5+0.5*sin(TAU*7.0*t),8.0)
			value = (sin(TAU*(83.0*t+3.0*sin(TAU*t)))*0.16+noise*pulse*0.28)*minf(t*60.0,1.0)*minf((duration-t)*60.0,1.0)
		bytes.encode_s16(i*2,int(clampf(value,-1.0,1.0)*32760.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = bytes
	if not thump:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = samples
	return stream
