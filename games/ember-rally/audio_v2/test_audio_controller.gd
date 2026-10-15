extends SceneTree
## Standalone audio regression, no main.gd dependency.
## godot --headless --path . --script audio_v2/test_audio_controller.gd
const AudioController = preload("res://audio_controller.gd")
var controller
var passes := 0
var failed: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok:
		passes += 1
		print("PASS ", label)
	else:
		failed.append(label)
		push_error("FAIL " + label)

func reset_effects() -> void:
	controller.stop_effects()
	controller.set_paused(false)

func run() -> void:
	controller = AudioController.new()
	root.add_child(controller)
	await process_frame
	controller.set_process(false) # Explicit dt makes cooldown/duck tests repeatable.
	check(controller.voices.size() == 7, "Fixed pool contains seven effect players")
	check(controller.get_child_count() == 8, "Total node/voice budget includes music: eight")
	check(controller.music.playing, "Exploration battlefield music starts")
	check(controller.music.stream is AudioStreamOggVorbis, "Music is an Ogg Vorbis stream")
	check(controller.music.stream.loop and is_zero_approx(controller.music.stream.loop_offset), "Music uses native whole-file loop mode")
	check(absf(controller.music.stream.get_length() - 182.51755) < 0.03, "Full 182.52-second supplied exploration music is retained")
	for key in controller.EVENTS:
		check(controller.streams[key].size() == controller.EVENTS[key]["files"].size(), key + " loads every variant")
		for stream in controller.streams[key]:
			check(stream.get_length() >= 0.09 and stream.get_length() < 1.5, key + " has a bounded one-shot duration")
		reset_effects()
		check(controller.play_event(key), key + " plays")
		check(not controller.play_event(key), key + " rapid duplicate is rate-limited")
		controller._process(0.5)
		check(controller.play_event(key), key + " replays after cooldown")
	for alias in controller.ALIASES:
		reset_effects()
		check(controller.play_event(alias), "Compatibility alias " + alias)
	for bow_event in ["bow_draw", "bow_release", "arrow_flight", "arrow_hit"]:
		reset_effects()
		var event_cap: int = controller.EVENTS[bow_event]["max_voices"]
		for i in range(event_cap):
			controller.cooldowns.clear()
			check(controller.play_event(bow_event), bow_event + " allows voice within event cap")
		controller.cooldowns.clear()
		check(not controller.play_event(bow_event), bow_event + " rejects voice beyond per-event cap")
		check(controller.active_effect_count() == event_cap, bow_event + " keeps its bounded volley voice count")
	reset_effects()
	var shot_successes := 0
	for archer in range(3):
		if controller.play_event("bow_draw"): shot_successes += 1
	check(shot_successes == 1, "Simultaneous three-archer draw is coalesced")
	controller._process(.18)
	var release_successes := 0
	var flight_successes := 0
	for archer in range(3):
		if controller.play_event("bow_release"): release_successes += 1
		if controller.play_event("arrow_flight"): flight_successes += 1
	check(release_successes == 1 and flight_successes == 1, "Simultaneous volley emits one short release and one light flight")
	check(controller.active_effect_count() <= 7, "Bow volley stays inside shared voice budget")
	var hits_before := 0
	for voice in controller.voices:
		if voice.playing and voice.get_meta("event", "") == "arrow_hit": hits_before += 1
	check(hits_before == 0, "Release and flight never implicitly emit an impact")
	controller._process(.32)
	check(controller.play_event("arrow_hit"), "Independent impact can be emitted on later confirmed collision")
	reset_effects()
	check(not controller.play_event("not_a_sound"), "Unknown event is safely rejected")
	var previous := -1
	for i in range(20):
		controller._process(0.1)
		check(controller.play_event("sword_swing"), "Sword variant request %d plays" % i)
		var variant: int = controller.last_variant["sword_swing"]
		check(variant != previous, "Sword variants do not immediately repeat %d" % i)
		previous = variant
	reset_effects()
	# Fill the pool with priority 100 without waiting in real time.
	for i in range(7):
		controller.cooldowns.clear()
		check(controller.play_event("boss_charge"), "Fill high-priority pool slot %d" % i)
	check(controller.active_effect_count() == 7, "Pool reaches seven effect voices")
	check(not controller.play_event("sword_swing"), "Low-priority sword cannot steal a warning")
	controller.cooldowns.clear()
	check(controller.play_event("death"), "Equally high-priority event may replace oldest warning")
	check(controller.active_effect_count() == 7, "Stealing preserves total eight-voice budget")
	reset_effects()
	for i in range(7):
		controller.cooldowns.clear()
		controller.play_event("sword_swing")
	check(controller.play_event("boss_charge"), "Warning steals an expendable sword voice")
	check(controller.active_effect_count() == 7, "Priority steal does not allocate nodes")
	check(controller.get_child_count() == 8, "Node count remains constant during saturation")
	check(controller.duck_target_db == -7.0, "Warning asks for seven dB of music ducking")
	controller._process(.075)
	check(controller.duck_current_db < -6.0, "Music duck reaches useful attenuation quickly")
	check(controller.music.volume_db < controller.BASE_MUSIC_DB - 6.0, "Duck reaches actual music player gain")
	controller.set_paused(true)
	var frozen_clock: float = controller.audio_clock
	var frozen_duck: float = controller.duck_remaining
	controller._process(1.0)
	check(controller.audio_clock == frozen_clock, "Pause freezes audio clock")
	check(controller.duck_remaining == frozen_duck, "Pause freezes duck hold")
	check(controller.music.stream_paused, "Pause freezes music stream")
	for voice in controller.voices:
		check(voice.stream_paused, "Pause freezes " + voice.name)
	check(not controller.play_event("rescue"), "No new combat event plays during explicit pause")
	controller.set_paused(false)
	check(not controller.music.stream_paused, "Resume releases music")
	controller._process(1.0)
	controller._process(2.0)
	check(absf(controller.duck_current_db) < .02, "Duck releases back to normal music gain")
	controller.set_volume(0.0)
	var output_bus := AudioServer.get_bus_index(controller.OUTPUT_BUS)
	check(AudioServer.is_bus_mute(output_bus), "Zero volume really mutes the dedicated mix")
	controller.set_volume(0.5)
	check(not AudioServer.is_bus_mute(output_bus), "Restoring volume unmutes")
	check(absf(AudioServer.get_bus_volume_db(output_bus) - linear_to_db(.5)) < .01, "User volume affects music and effects together")
	controller.set_volume(2)
	check(controller.volume == 1, "Volume clamps upper bound")
	controller.set_volume(-2)
	check(controller.volume == 0, "Volume clamps lower bound")
	check(AudioServer.get_bus_effect_count(output_bus) == 1, "One dedicated output limiter is installed")
	var limiter = AudioServer.get_bus_effect(output_bus, 0)
	check(limiter is AudioEffectLimiter and limiter.ceiling_db == -1.0, "Limiter ceiling is minus one dBFS")
	check(AudioServer.get_bus_send(AudioServer.get_bus_index(controller.SFX_BUS)) == controller.OUTPUT_BUS, "Effects route through limiter")
	check(AudioServer.get_bus_send(AudioServer.get_bus_index(controller.MUSIC_BUS)) == controller.OUTPUT_BUS, "Music routes through limiter")
	controller.stop_effects()
	check(controller.active_effect_count() == 0, "Restart clears all effect tails")
	check(controller.cooldowns.is_empty(), "Restart clears all event cooldowns")
	check(controller.duck_current_db == 0.0, "Restart clears duck attenuation")
	check(controller.music.playing, "Restart preserves existing music loop")
	print("AUDIO_V2_RESULT ", JSON.stringify({"passed": passes, "failed": failed, "diagnostics": controller.diagnostics}))
	controller.music.stop()
	# Let the audio server retire stopped playbacks before destroying the tree.
	await create_timer(0.15).timeout
	controller.queue_free()
	await create_timer(0.15).timeout
	quit(0 if failed.is_empty() else 1)
