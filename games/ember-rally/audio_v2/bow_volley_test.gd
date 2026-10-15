extends Node
## Run: godot --headless --path . --max-fps 60 audio_v2/bow_volley_test.tscn
const Controller = preload("res://audio_controller.gd")
var controller
var frames := 0
var record: AudioEffectRecord
var peak_sfx := 0
var draw_requests := 0
var release_requests := 0
var flight_requests := 0
var hit_requests := 0

func _ready() -> void:
	controller = Controller.new()
	add_child(controller)
	controller.set_volume(1.0)
	record = AudioEffectRecord.new()
	record.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(0, record)
	record.set_recording_active(true)

func _process(_delta: float) -> void:
	frames += 1
	# Three archers at once. Last volley deliberately misses.
	if frames in [1, 49, 97]:
		for archer in range(3):
			controller.play_event("bow_draw")
			draw_requests += 1
	if frames in [12, 60, 108]:
		for archer in range(3):
			controller.play_event("bow_release")
			controller.play_event("arrow_flight")
			release_requests += 1
			flight_requests += 1
	if frames in [32, 80]:
		for archer in range(3):
			controller.play_event("arrow_hit")
			hit_requests += 1
	peak_sfx = maxi(peak_sfx, controller.active_effect_count())
	if frames == 150:
		controller.stop_effects()
		controller.music.stop()
	if frames == 165:
		record.set_recording_active(false)
		var recording := record.get_recording()
		var saved := recording.save_to_wav("res://audio_v2/bow_volley_capture.wav")
		var report := {"duration_s": recording.get_length(), "save_error": saved, "peak_sfx": peak_sfx, "peak_total": peak_sfx+1, "draw_requests":draw_requests, "release_requests":release_requests, "flight_requests":flight_requests, "actual_hit_requests":hit_requests, "miss_hit_requests":0, "diagnostics":controller.diagnostics}
		var file := FileAccess.open("res://audio_v2/bow_volley_result.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ")+"\n")
		print("BOW_VOLLEY_RESULT ", JSON.stringify(report))
		get_tree().quit()
