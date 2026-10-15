extends Node
## Original v2 combat audio + exploration/boss BGM. One music voice + seven SFX.
## The eighth-voice budget includes music, so total playback never exceeds 8.
## Integration: add_child(controller), play_event("sword_swing"), set_volume(0.5).
## Pause with set_paused(true); call stop_effects() before restarting a match.

const MAX_CONCURRENT := 8
const MAX_SFX_VOICES := MAX_CONCURRENT - 1
const OUTPUT_BUS := "BattlefieldOutput"
const SFX_BUS := "BattlefieldSFX"
const MUSIC_BUS := "BattlefieldMusic"
# Uploaded tracks are normalized near -18 LUFS; leave headroom for combat SFX.
const BASE_MUSIC_DB := -3.0
const SETTINGS_PATH := "user://audio_settings.cfg"
const MUSIC_FADE_OUT_SECONDS := 0.20
const MUSIC_FADE_IN_SECONDS := 0.40
const MUSIC_TRACKS := [
	{"name": "Until the Iron Breaks", "path": "res://audio_bgm/track_a.ogg"},
	{"name": "Throne of Cold Steel", "path": "res://audio_bgm/track_b.ogg"},
]
const ALIASES := {"hit": "undead_hit", "block": "shield_block", "level": "level_up", "sword": "sword_swing", "bow": "bow_release", "bow_shot": "bow_release", "boss_warning": "boss_charge"}
const EVENTS := {
	"sword_swing": {"files": ["sword_swing_01", "sword_swing_02", "sword_swing_03"], "priority": 20, "gain_db": -10.0, "cooldown": 0.055, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.035},
	"undead_hit": {"files": ["undead_hit_01", "undead_hit_02", "undead_hit_03"], "priority": 40, "gain_db": -9.0, "cooldown": 0.040, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.040},
	"demon_hit": {"files": ["demon_hit_01", "demon_hit_02"], "priority": 55, "gain_db": -8.5, "cooldown": 0.060, "duck_db": -3.5, "duck_hold": 0.12, "pitch": 0.025},
	"shield_block": {"files": ["shield_block_01", "shield_block_02"], "priority": 70, "gain_db": -10.0, "cooldown": 0.075, "duck_db": -3.0, "duck_hold": 0.13, "pitch": 0.020},
	"bow_draw": {"files": ["bow_draw_01", "bow_draw_02"], "priority": 15, "gain_db": -14.0, "cooldown": 0.050, "max_voices": 2, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.020},
	"bow_release": {"files": ["bow_release_01", "bow_release_02"], "priority": 30, "gain_db": -8.0, "cooldown": 0.035, "max_voices": 3, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.025},
	"arrow_flight": {"files": ["arrow_flight_01", "arrow_flight_02"], "priority": 10, "gain_db": -15.0, "cooldown": 0.080, "max_voices": 2, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.025},
	"arrow_hit": {"files": ["arrow_hit_01", "arrow_hit_02"], "priority": 45, "gain_db": -9.0, "cooldown": 0.035, "max_voices": 3, "duck_db": 0.0, "duck_hold": 0.0, "pitch": 0.030},
	"rescue": {"files": ["rescue"], "priority": 90, "gain_db": -8.0, "cooldown": 0.30, "duck_db": -6.0, "duck_hold": 0.85, "pitch": 0.0},
	"boss_charge": {"files": ["boss_charge"], "priority": 100, "gain_db": -9.0, "cooldown": 0.35, "duck_db": -7.0, "duck_hold": 0.95, "pitch": 0.0},
	"level_up": {"files": ["level_up"], "priority": 80, "gain_db": -10.0, "cooldown": 0.30, "duck_db": -5.0, "duck_hold": 0.65, "pitch": 0.0},
	"death": {"files": ["death"], "priority": 100, "gain_db": -8.5, "cooldown": 0.30, "duck_db": -7.0, "duck_hold": 0.80, "pitch": 0.0},
}

var music: AudioStreamPlayer
var voices: Array[AudioStreamPlayer] = []
var streams: Dictionary = {}
var last_variant: Dictionary = {}
var cooldowns: Dictionary = {}
var volume: float = 0.5
var last_nonzero_volume: float = 0.5
var music_gain: float = 1.0
var selected_track: int = 0
var current_track: int = -1
var music_streams: Array[AudioStream] = []
var music_fade_state: String = "idle"
var music_fade_gain: float = 1.0
var music_fade_elapsed: float = 0.0
var music_fade_start: float = 1.0
# Tests may point this at an isolated user:// file before adding the controller.
var settings_path: String = SETTINGS_PATH
var settings_loaded: bool = false
var paused: bool = false
var duck_remaining: float = 0.0
var duck_target_db: float = 0.0
var duck_current_db: float = 0.0
var audio_clock: float = 0.0
var rng := RandomNumberGenerator.new()
var diagnostics := {"played": 0, "dropped_cooldown": 0, "dropped_priority": 0, "dropped_event_limit": 0, "dropped_paused": 0, "stolen": 0, "peak_sfx_voices": 0}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rng.randomize()
	_setup_buses()
	_load_settings()
	for event_name in EVENTS:
		var variants: Array[AudioStream] = []
		for filename in EVENTS[event_name]["files"]:
			var path := "res://audio_v2/%s.wav" % filename
			var stream = load(path) if ResourceLoader.exists(path) else null
			if stream is AudioStream:
				variants.append(stream)
			else:
				push_warning("Combat audio missing: " + path)
		streams[event_name] = variants
	for i in range(MAX_SFX_VOICES):
		var voice := AudioStreamPlayer.new()
		voice.name = "CombatVoice%d" % i
		voice.bus = SFX_BUS
		voice.max_polyphony = 1
		voice.set_meta("priority", -1)
		voice.set_meta("started_at", -1.0)
		add_child(voice)
		voices.append(voice)
	music = AudioStreamPlayer.new()
	music.name = "BattlefieldMusic"
	music.bus = MUSIC_BUS
	music.max_polyphony = 1
	music.volume_db = BASE_MUSIC_DB
	add_child(music)
	for track in MUSIC_TRACKS:
		var stream: AudioStream = null
		if ResourceLoader.exists(track.path):
			var resource = load(track.path)
			if resource is AudioStreamOggVorbis:
				stream = resource.duplicate()
				stream.loop = true
				stream.loop_offset = 0.0
			else:
				push_warning("BGM is not an Ogg Vorbis stream: " + track.path)
		else:
			push_warning("BGM missing: " + track.path)
		music_streams.append(stream)
	# Whole-file looping preserves the supplied compositions and encoded fades.
	# It is intentionally not described as a musically seamless loop.
	_replace_music_track(selected_track)
	_apply_master_volume()
	_apply_music_bus_gain()
	set_paused(paused)

func _load_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(settings_path) if not settings_path.is_empty() else ERR_FILE_NOT_FOUND
	if error == OK:
		volume = clampf(_config_number(config, "volume", volume), 0.0, 1.0)
		music_gain = clampf(_config_number(config, "music_gain", music_gain), 0.0, 1.0)
		last_nonzero_volume = clampf(_config_number(config, "last_nonzero_volume", 0.5), 0.01, 1.0)
		if not is_zero_approx(volume):
			last_nonzero_volume = volume
	elif error != ERR_FILE_NOT_FOUND:
		push_warning("Could not load audio preferences (%s); using defaults." % error_string(error))
	settings_loaded = true

func _config_number(config: ConfigFile, key: String, fallback: float) -> float:
	var value = config.get_value("audio", key, fallback)
	if typeof(value) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(value)):
		return fallback
	return float(value)

func _save_settings() -> void:
	if not settings_loaded or settings_path.is_empty():
		return
	var config := ConfigFile.new()
	config.set_value("audio", "volume", volume)
	config.set_value("audio", "last_nonzero_volume", last_nonzero_volume)
	config.set_value("audio", "music_gain", music_gain)
	var error := config.save(settings_path)
	if error != OK:
		push_warning("Could not save audio preferences: " + error_string(error))

func get_track_name() -> String:
	return MUSIC_TRACKS[selected_track].name

func set_track(index: int) -> bool:
	## Gameplay owns selection: A for exploration, B when the boss appears.
	if index < 0 or index >= MUSIC_TRACKS.size():
		return false
	if settings_loaded and (index >= music_streams.size() or music_streams[index] == null):
		return false
	if selected_track != index:
		selected_track = index
	# Do not touch playback or fade state here. The next unpaused process tick
	# resolves the latest selection, including rapid toggles and paused choices.
	return true

func _replace_music_track(index: int) -> bool:
	if index < 0 or index >= music_streams.size() or music_streams[index] == null:
		return false
	# Stop before replacing: the same single player never layers two tracks.
	music.stop()
	music.stream = music_streams[index]
	current_track = index
	_apply_music_player_gain()
	music.play()
	music.stream_paused = paused
	return true

func _start_music_fade(next_state: String) -> void:
	music_fade_state = next_state
	music_fade_elapsed = 0.0
	music_fade_start = music_fade_gain

func _advance_music_switch(delta: float) -> void:
	if selected_track != current_track and music_fade_state != "out":
		_start_music_fade("out")
	elif selected_track == current_track and music_fade_state == "out":
		# Selecting the still-playing track cancels the pending replacement.
		_start_music_fade("in")
	if music_fade_state == "idle":
		return
	var remaining := maxf(delta, 0.0)
	# At most an outgoing and incoming envelope. No tweens or callback queues.
	for stage in range(2):
		var duration := MUSIC_FADE_OUT_SECONDS if music_fade_state == "out" else MUSIC_FADE_IN_SECONDS
		var step := minf(remaining, maxf(0.0, duration - music_fade_elapsed))
		music_fade_elapsed += step
		remaining -= step
		var progress := clampf(music_fade_elapsed / duration, 0.0, 1.0)
		music_fade_gain = lerpf(music_fade_start, 0.0 if music_fade_state == "out" else 1.0, progress)
		if progress < 1.0:
			break
		if music_fade_state == "out":
			_replace_music_track(selected_track)
			_start_music_fade("in")
		else:
			music_fade_state = "idle"
			music_fade_gain = 1.0
			break
		if remaining <= 0.0:
			break

func _apply_music_player_gain() -> void:
	if music != null:
		# Linear envelope gives true silence at replacement, layered with the
		# existing warning/rescue duck. Music-only user gain lives on MUSIC_BUS.
		music.volume_linear = db_to_linear(BASE_MUSIC_DB + duck_current_db) * music_fade_gain

func set_music_gain(value: float) -> void:
	music_gain = clampf(value, 0.0, 1.0)
	if is_zero_approx(music_gain):
		music_gain = 0.0
	_apply_music_bus_gain()
	_save_settings()

func _apply_music_bus_gain() -> void:
	var bus := AudioServer.get_bus_index(MUSIC_BUS)
	if bus >= 0:
		AudioServer.set_bus_mute(bus, is_zero_approx(music_gain))
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(music_gain, 0.00001)))

func _setup_buses() -> void:
	for bus_name in [OUTPUT_BUS, SFX_BUS, MUSIC_BUS]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
	var output_index := AudioServer.get_bus_index(OUTPUT_BUS)
	AudioServer.set_bus_send(output_index, "Master")
	AudioServer.set_bus_send(AudioServer.get_bus_index(SFX_BUS), OUTPUT_BUS)
	AudioServer.set_bus_send(AudioServer.get_bus_index(MUSIC_BUS), OUTPUT_BUS)
	var has_limiter := false
	for i in range(AudioServer.get_bus_effect_count(output_index)):
		if AudioServer.get_bus_effect(output_index, i) is AudioEffectLimiter:
			has_limiter = true
	if not has_limiter:
		var limiter := AudioEffectLimiter.new()
		limiter.ceiling_db = -1.0
		limiter.threshold_db = -1.0
		limiter.soft_clip_db = 2.0
		limiter.soft_clip_ratio = 10.0
		AudioServer.add_bus_effect(output_index, limiter)

func play_event(event_name: String) -> bool:
	## Returns false when an unknown, paused, rapid-repeat, or low-priority event
	## is intentionally suppressed. Never allocates a new player during combat.
	var key: String = ALIASES.get(event_name, event_name)
	if not EVENTS.has(key) or not streams.has(key) or streams[key].is_empty():
		return false
	if paused:
		diagnostics["dropped_paused"] += 1
		return false
	if float(cooldowns.get(key, 0.0)) > 0.0:
		diagnostics["dropped_cooldown"] += 1
		return false
	var config: Dictionary = EVENTS[key]
	var event_limit: int = int(config.get("max_voices", MAX_SFX_VOICES))
	var matching_voices := 0
	for active in voices:
		if active.playing and active.get_meta("event", "") == key:
			matching_voices += 1
	if config.has("max_voices") and matching_voices >= event_limit:
		diagnostics["dropped_event_limit"] += 1
		return false
	var voice: AudioStreamPlayer = _claim_voice(int(config["priority"]))
	if voice == null:
		diagnostics["dropped_priority"] += 1
		return false
	var variants: Array = streams[key]
	var pick := rng.randi_range(0, variants.size() - 1)
	if variants.size() > 1 and pick == int(last_variant.get(key, -1)):
		pick = (pick + rng.randi_range(1, variants.size() - 1)) % variants.size()
	last_variant[key] = pick
	voice.stream = variants[pick]
	voice.pitch_scale = 1.0 + rng.randf_range(-float(config["pitch"]), float(config["pitch"]))
	voice.volume_db = float(config["gain_db"])
	voice.set_meta("priority", int(config["priority"]))
	voice.set_meta("started_at", audio_clock)
	voice.set_meta("event", key)
	voice.play()
	cooldowns[key] = float(config["cooldown"])
	if float(config["duck_db"]) < 0.0:
		duck_target_db = minf(duck_target_db, float(config["duck_db"]))
		duck_remaining = maxf(duck_remaining, float(config["duck_hold"]))
	diagnostics["played"] += 1
	diagnostics["peak_sfx_voices"] = maxi(int(diagnostics["peak_sfx_voices"]), active_effect_count())
	return true

func _claim_voice(priority: int) -> AudioStreamPlayer:
	var candidate: AudioStreamPlayer = null
	for voice in voices:
		if not voice.playing:
			return voice
		if candidate == null or int(voice.get_meta("priority")) < int(candidate.get_meta("priority")):
			candidate = voice
		elif int(voice.get_meta("priority")) == int(candidate.get_meta("priority")) and float(voice.get_meta("started_at")) < float(candidate.get_meta("started_at")):
			candidate = voice
	if candidate != null and priority >= int(candidate.get_meta("priority")):
		candidate.stop()
		diagnostics["stolen"] += 1
		return candidate
	return null

func set_volume(value: float) -> void:
	## Shared user volume, clamped 0..1. Zero truly mutes the dedicated mix bus.
	volume = clampf(value, 0.0, 1.0)
	if is_zero_approx(volume):
		volume = 0.0
	else:
		last_nonzero_volume = volume
	_apply_master_volume()
	_save_settings()

func toggle_mute() -> void:
	set_volume(last_nonzero_volume if is_zero_approx(volume) else 0.0)

func _apply_master_volume() -> void:
	var bus := AudioServer.get_bus_index(OUTPUT_BUS)
	if bus >= 0:
		AudioServer.set_bus_mute(bus, is_zero_approx(volume))
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.00001)))

func set_paused(value: bool) -> void:
	## Freezes one-shot positions, music position, cooldowns and duck envelopes.
	## Useful both with manual game states and SceneTree.paused.
	paused = value
	if music != null:
		music.stream_paused = value
	for voice in voices:
		voice.stream_paused = value

func stop_effects() -> void:
	## Restart-safe: no battle-ending tails or old cooldowns leak into a new run.
	for voice in voices:
		voice.stop()
	cooldowns.clear()
	duck_remaining = 0.0
	duck_target_db = 0.0
	duck_current_db = 0.0
	_apply_music_player_gain()

func active_effect_count() -> int:
	var count := 0
	for voice in voices:
		if voice.playing:
			count += 1
	return count

func _process(delta: float) -> void:
	if paused:
		return
	audio_clock += delta
	for key in cooldowns:
		cooldowns[key] = maxf(0.0, float(cooldowns[key]) - delta)
	duck_remaining = maxf(0.0, duck_remaining - delta)
	if duck_remaining <= 0.0:
		duck_target_db = 0.0
	# About 25 ms attack, 300 ms release, without per-hit tween accumulation.
	var seconds := 0.025 if duck_target_db < duck_current_db else 0.30
	duck_current_db = lerpf(duck_current_db, duck_target_db, 1.0 - exp(-delta / seconds))
	_advance_music_switch(delta)
	_apply_music_player_gain()
