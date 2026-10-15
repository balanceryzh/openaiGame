extends SceneTree
## Read-only headless integration checks; does not rewrite production art or manifests.
## Run from project: godot --headless --path . --script res://large/qa/test_approved_walk12.gd
const Walk = preload("res://large/approved_walk.gd")
const ActorView = preload("res://large/actor_view.gd")
const Renderer = preload("res://large/visuals_renderer.gd")
const SOURCE_ORDER = [14,16,18,20,22,25,28,30,32,34,36,38]
const HOLDS = [2,2,2,2,3,3,2,2,2,2,2,2]
var passes := 0
var failures: Array[String] = []
var source_crosschecks_skipped: Array[String] = []
var embedded_hash_checks := 0
var external_source_checks := 0
var metrics: Dictionary = {}
var manifest: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok:
		passes += 1
	else:
		failures.append(label)
		push_error("APPROVED_WALK12 FAIL: " + label)

func expected_index(elapsed: float) -> int:
	var tick := fposmod(elapsed * 24.0, 26.0)
	var edge := 0.0
	for i in HOLDS.size():
		edge += float(HOLDS[i])
		if tick < edge:
			return i
	return -1

func authored_source(kind: String, frame: Dictionary) -> String:
	var project_parent := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	if kind == "hero":
		if int(frame.source_n) == 25:
			return project_parent.path_join("hero-legfix-v2/n025_corrected.png")
		return project_parent.path_join("human-unit-walk-template/assets/textures/" + String(frame.file).get_file())
	if kind == "shield":
		return project_parent.path_join("shield-walk12-direct/" + String(frame.file).get_file())
	return project_parent.path_join("archer-walk12-direct/" + String(frame.file).get_file())

func check_assets_and_packet() -> void:
	check(int(manifest.cycle_ticks) == 26 and int(manifest.fps) == 24, "manifest cycle is 26 ticks at 24 fps")
	check(manifest.units.size() == 3, "three approved unit kinds")
	for kind in ["hero", "shield", "archer"]:
		var unit: Dictionary = manifest.units[kind]
		check(unit.frames.size() == 12, kind + " has all 12 authored frames")
		var cumulative := 0.0
		var raw_hashes: Array[String] = []
		for i in unit.frames.size():
			var frame: Dictionary = unit.frames[i]
			var label: String = kind + "/n" + str(frame.source_n)
			check(int(frame.source_n) == int(SOURCE_ORDER[i]), label + " source order")
			check(int(frame.ticks) == int(HOLDS[i]), label + " original hold duration")
			check(FileAccess.file_exists(frame.file), label + " runtime raw PNG exists")
			var raw_hash := FileAccess.get_sha256(frame.file)
			raw_hashes.append(raw_hash)
			embedded_hash_checks += 1
			check(raw_hash == String(frame.sha256), label + " raw SHA256 matches manifest")
			var original := authored_source(kind, frame)
			if FileAccess.file_exists(original):
				check(true, label + " approved original source exists")
				external_source_checks += 1
				check(raw_hash == FileAccess.get_sha256(original), label + " runtime PNG is byte-identical to approved original")
			else:
				# A portable game ZIP intentionally omits the external art workspace.
				# Embedded approved-manifest hashes remain mandatory above.
				source_crosschecks_skipped.append(label + ": external approved original absent; embedded manifest SHA256 still verified")
			var midpoint := (cumulative + float(frame.ticks) * 0.5) / 24.0
			var packet: Dictionary = Walk.packet(kind, midpoint)
			check(not packet.is_empty() and int(packet.index) == i, label + " midpoint selection")
			if not packet.is_empty():
				check(packet.frame.texture != null, label + " texture imported and loaded")
				check(packet.frame.texture.get_size() == Vector2(frame.size[0], frame.size[1]), label + " full raw canvas retained")
				check(is_equal_approx(float(packet.pixel_scale), float(unit.pixel_scale)), label + " shared role scale, no per-frame normalization")
				check(packet.frame.texture == Walk.packet(kind, midpoint).frame.texture, label + " cached texture object reused")
			check(int(Walk.packet(kind, (cumulative + 0.0001) / 24.0).index) == i, label + " start boundary")
			check(int(Walk.packet(kind, (cumulative + float(frame.ticks) - 0.0001) / 24.0).index) == i, label + " end boundary")
			cumulative += float(frame.ticks)
		check(is_equal_approx(cumulative, 26.0), kind + " exact complete cycle duration")
		for tick in range(26):
			check(int(Walk.packet(kind, (float(tick) + 0.5) / 24.0).index) == expected_index((float(tick) + 0.5) / 24.0), kind + " tick " + str(tick))
		check(int(Walk.packet(kind, 26.0 / 24.0).index) == 0, kind + " cycle wrap returns first frame")
		check(int(Walk.packet(kind, (26.0 - 0.0001) / 24.0).index) == 11, kind + " final frame retained before wrap")
		metrics[kind + "_raw_sha256"] = raw_hashes
	check(Walk.packet("boss", 0.2).is_empty(), "unsupported kinds do not substitute human walk")

func actor(kind: String, identity: String) -> Dictionary:
	return {"view_id":identity,"kind":kind,"team":"ally","p":Vector2.ZERO,"hp":100.0,"max_hp":100.0,"dir":Vector2.RIGHT,"moving":true,"hurt":0.0,"death":-1.0,"rise":-1.0,"attack_age":-1.0,"block":0.0,"guard":false,"source":{}}

func verify_walk_frame(view: Node3D, kind: String, label: String) -> void:
	var packet: Dictionary = Walk.packet(kind, view.walk_elapsed)
	check(view.approved_walk_frame == int(packet.index), label + " selected frame")
	check(view.sprite.texture == packet.frame.texture, label + " exact cached walk texture")
	var anchor := Vector2(packet.frame.anchor[0], packet.frame.anchor[1])
	var size := Vector2(packet.frame.size[0], packet.frame.size[1])
	var expected_offset := Vector2(anchor.x - size.x * 0.5 if view.sprite.flip_h else size.x * 0.5 - anchor.x, anchor.y - size.y * 0.5)
	check(view.ground_anchor == anchor, label + " immutable frame anchor")
	check(view.sprite.offset.is_equal_approx(expected_offset), label + " foot root offset including facing")
	check(is_equal_approx(view.sprite.pixel_size, float(manifest.units[kind].pixel_scale)), label + " fixed kind scale")
	check(view.last_frame == -99, label + " legacy cache invalidated for restoration")

func run_motion_case(renderer: RefCounted, kind: String, speed_px: float) -> void:
	var view: Node3D = ActorView.new()
	root.add_child(view)
	var a := actor(kind, kind + "_" + str(speed_px))
	view.update_actor(a, renderer, 0.0, 0.75, Vector2.RIGHT)
	var sequence: Array[int] = [view.approved_walk_frame]
	var seen: Dictionary = {view.approved_walk_frame:true}
	var previous_index: int = view.approved_walk_frame
	var rate := speed_px / 205.0
	var max_phase_error := 0.0
	for step in range(1, 271):
		var clock := float(step) / 120.0
		a.p = Vector2(speed_px / 50.0 * clock, 0.0)
		view.update_actor(a, renderer, clock, 0.75, Vector2.RIGHT)
		max_phase_error = maxf(max_phase_error, absf(view.walk_elapsed - clock * rate))
		verify_walk_frame(view, kind, kind + " speed=" + str(speed_px) + " step=" + str(step))
		check(view.position.is_equal_approx(Vector3(a.p.x, 0.785, a.p.y)), kind + " root follows unchanged actor world position")
		if view.approved_walk_frame != previous_index:
			check(view.approved_walk_frame == (previous_index + 1) % 12, kind + " sequential frames at speed " + str(speed_px))
			sequence.append(view.approved_walk_frame)
			previous_index = view.approved_walk_frame
		seen[view.approved_walk_frame] = true
	check(seen.size() == 12, kind + " all 12 appear at " + str(speed_px) + " px/s")
	check(max_phase_error < 0.0001, kind + " travel playback rate " + str(speed_px))
	var saved_phase: float = view.walk_elapsed
	var saved_index: int = view.approved_walk_frame
	var saved_texture: Texture2D = view.sprite.texture
	var saved_offset: Vector2 = view.sprite.offset
	var saved_anchor: Vector2 = view.ground_anchor
	for repeat in range(60):
		view.update_actor(a, renderer, 2.25, 0.75, Vector2.RIGHT)
		check(view.walk_elapsed == saved_phase and view.approved_walk_frame == saved_index, kind + " same-clock pause freezes phase/index")
		check(view.sprite.texture == saved_texture and view.sprite.offset == saved_offset and view.ground_anchor == saved_anchor, kind + " same-clock pause retains texture and anchor")
	a.dir = Vector2.LEFT
	view.update_actor(a, renderer, 2.25, 0.75, Vector2.RIGHT)
	verify_walk_frame(view, kind, kind + " paused facing-left")
	check(view.sprite.flip_h, kind + " normal engine facing convention retained")
	# Pool reuse must start the new actor at its first authored frame.
	a.view_id = a.view_id + "_replacement"
	a.p = Vector2(90.0, 12.0)
	view.update_actor(a, renderer, 100.0, 0.75, Vector2.RIGHT)
	check(view.walk_elapsed == 0.0 and view.approved_walk_frame == 0, kind + " pooled identity resets phase without teleport advance")
	metrics[kind + "_speed_" + str(speed_px)] = {"playback_rate":rate,"max_phase_error":max_phase_error,"frame_sequence":sequence,"same_clock_pause_updates":60}
	view.free()

func compare_legacy(view: Node3D, control: Node3D, label: String) -> void:
	check(view.approved_walk_frame == -1, label + " walk override disabled")
	check(view.sprite.texture == view.atlas, label + " original atlas texture restored")
	check(view.atlas.atlas == control.atlas.atlas and view.atlas.region == control.atlas.region, label + " original atlas/region matches clean actor")
	check(view.ground_anchor == control.ground_anchor and view.sprite.offset == control.sprite.offset, label + " original foot anchor/offset restored")
	check(is_equal_approx(view.pixel_scale, control.pixel_scale) and is_equal_approx(view.sprite.pixel_size, control.sprite.pixel_size), label + " original scale restored")
	check(view.source_frame == control.source_frame and view.last_frame == control.last_frame, label + " original frame cache restored")
	check(view.sprite.flip_h == control.sprite.flip_h, label + " original facing restored")
	check(view.position == control.position, label + " world root unchanged")

func run_restoration_cases(renderer: RefCounted, kind: String) -> void:
	for direction in [Vector2.RIGHT, Vector2.LEFT]:
		for state in ["idle", "attack", "hurt", "guard", "block", "death", "rise"]:
			var view: Node3D = ActorView.new()
			var control: Node3D = ActorView.new()
			root.add_child(view)
			root.add_child(control)
			var a := actor(kind, kind + "_restore_" + state)
			a.dir = direction
			view.update_actor(a, renderer, 0.0, 0.0, Vector2.RIGHT)
			a.p = Vector2(4.1 * 0.4, 0.0)
			view.update_actor(a, renderer, 0.4, 0.0, Vector2.RIGHT)
			verify_walk_frame(view, kind, kind + " before " + state)
			match state:
				"idle": a.moving = false
				"attack": a.attack_age = 0.14
				"hurt": a.hurt = 0.2
				"guard": a.guard = true
				"block": a.block = 0.2
				"death": a.death = 0.1
				"rise": a.rise = 0.1
			for repeat in range(3):
				var clock := 0.4 + float(repeat) * 0.001
				view.update_actor(a, renderer, clock, 0.0, Vector2.RIGHT)
				control.update_actor(a, renderer, clock, 0.0, Vector2.RIGHT)
				compare_legacy(view, control, kind + " walk→" + state + " repeat=" + str(repeat) + " facing=" + str(direction))
			var retained_phase: float = view.walk_elapsed
			a.moving = true
			a.attack_age = -1.0
			a.hurt = 0.0
			a.guard = false
			a.block = 0.0
			a.death = -1.0
			a.rise = -1.0
			a.p += Vector2(4.1 * 0.1, 0.0)
			view.update_actor(a, renderer, 0.502, 0.0, Vector2.RIGHT)
			check(absf(view.walk_elapsed - retained_phase - 0.1) < 0.00001, kind + " resume after " + state + " advances only current movement")
			verify_walk_frame(view, kind, kind + " resumed after " + state)
			view.free()
			control.free()

func run() -> void:
	manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/approved_walk12/manifest.json"))
	check_assets_and_packet()
	var renderer: RefCounted = Renderer.new()
	for kind in ["hero", "shield", "archer"]:
		check(renderer.frame_tables.has(kind) and renderer.textures.has(kind), kind + " actual renderer legacy art available")
		run_motion_case(renderer, kind, 205.0)
		run_motion_case(renderer, kind, 320.0)
		run_restoration_cases(renderer, kind)
	check(embedded_hash_checks == 36, "all 36 embedded approved-manifest hashes checked")
	var summary := {"passes":passes,"failures":failures,"embedded_manifest_hash_checks":embedded_hash_checks,"external_source_hash_crosschecks":external_source_checks,"skipped_external_source_crosschecks":source_crosschecks_skipped,"metrics":metrics,"scope":"Actual Godot actor/renderer objects under headless mode; all 36 embedded PNGs must match approved manifest hashes. External authoring-source hashes are additionally checked when available and explicitly skipped in portable packages. Complete 12-frame holds/order, 205/320 px/s movement, same-clock pause, identity reuse, immutable anchors, walk-to-idle/attack/state restoration. Does not assert rendered appearance, perceived gait, GPU performance, or native input gameplay."}
	print("APPROVED_WALK12_JSON=" + JSON.stringify(summary))
	print("APPROVED_WALK12: ", passes, " passed; ", failures.size(), " failed")
	quit(0 if failures.is_empty() else 1)
