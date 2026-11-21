@tool
class_name GSVoiceManager
extends Node

## The node a game adds: captures, encodes, sends, receives, decodes and plays (usage in docs/design.md).
##
## Nothing opens a microphone on its own: the host calls [method start_capture] after the player agrees, and it returns a failure the host can show. Capture is polled from [code]_process[/code], not a thread: the browser has none, and it is one codec call per frame.

const CHANNEL := "voice"
const SERVICE := &"gs_voice_manager"

## Registry name of the manager that is this process's own player's voice, for a settings menu's voice rows.
## Not [constant SERVICE]: a suite with a server and two clients holds several managers. Published with [method publish_as_client].
const CLIENT_SERVICE := &"gs_voice_client"

## The InputMap action held to talk. GameSpice Menu's key table stores it as `bind_voice_talk`;
## [method ensure_talk_action] creates it on [constant DEFAULT_TALK_KEY] when nothing has.
const TALK_ACTION := &"gs_voice_talk"

## The key the talk action is created on: V, the genre's, by physical position.
const DEFAULT_TALK_KEY := KEY_V

## The bus voices play on when the project has one: GameSpice Audio's mixer creates it and
## GameSpice Menu's `voice_volume` sets it.
const VOICE_BUS := &"Voice"

## The gate opened or closed. For a microphone icon.
signal talking_changed(talking: bool)

## A frame was captured and encoded. [param bytes] is what went to [member send_fn].
signal frame_sent(bytes: int)

## A speaker started or stopped being heard. For a "who is talking" list.
signal speaker_changed(speaker: int, speaking: bool)

## Capture could not be started or had to stop.
signal capture_failed(error: GSError)

## The server turned voice on or off ([method set_server_enabled]). A HUD hides its
## microphone and a menu its voice rows on false.
signal server_enabled_changed(enabled: bool)

@export_group("Configuration")

## Voice settings. A default [GSVoiceConfig] is created if unset.
@export var config: GSVoiceConfig = null

## Path to a JSON config file layered over [member config]'s defaults.
@export var config_file: String = "user://gs_voice.json"

@export_group("Service")

## Publish this manager in [GSRegistry] so a HUD can find it without a scene path.
@export var register_service: bool = true

## Suffix for the registry name, so a listen server running both halves in one process
## does not have the second displace the first.
@export var service_scope: StringName = &""

@export_group("Playback")

## Where per-speaker playback nodes are added. Defaults to a child of this node.
@export var playback_root_ref: GSNodeRef = null

## Play voices positioned in the world rather than flat.
@export var positional_playback: bool = false

## Sends one encoded packet to the server. Set by the host.
var send_fn: Callable = Callable()

## Where captured samples come from. Defaults to a real microphone on [method start_capture].
##
## Assign a [GSVoiceSourceBuffer] for a bot, a test, or playing a recording in.
var source: GSVoiceSource = null

## Builds the sink for a speaker; defaults to a [GSVoiceSinkPlayer].
## Assign to route audio elsewhere (a recorder, a game mixer, a [GSVoiceSinkBuffer] in a test).
var sink_factory: Callable = Callable()

## Where a speaker is, for [member positional_playback]: [code]func(speaker: int) -> Variant[/code], a Vector3 or null.
##
## Positional playback is used only when this is set; with no position a voice sits at the origin and is heard from the wrong side or not at all.
var speaker_position_fn: Callable = Callable()

## Whether the server lets anybody talk. Off: nothing is captured or sent, what arrives is
## dropped, and [signal server_enabled_changed] tells a HUD to hide its key. The router
## enforces it regardless ([member GSVoiceRouter.enabled]); this is the client's half.
var server_enabled: bool = true

## Open microphone instead of push to talk: the gate opens on loudness. The player's
## choice ([method set_open_mic]).
var open_mic: bool = false

## The bus voices play on, if the project has it. See [constant VOICE_BUS].
var playback_bus: StringName = VOICE_BUS

## Speakers this client has chosen not to hear.
##
## A preference applied on the listener's machine; a moderator's mute is [GSVoiceRouter]'s, because a client-applied mute can simply not be applied.
var local_mutes: Dictionary = {}

## Speakers this client has gagged: it stops hearing them, and nothing else changes.
## Separate from [member local_mutes] so a gag toggled by looking cannot undo a mute the
## player made with `sm`, and the reverse. See [GSVoiceLookMute].
var gagged: Dictionary = {}

## Every speaker starts gagged until the listener un-gags them. The server's
## `sv_voice_gag_default`; a listener's own un-gag is remembered in [member ungagged].
var gag_default: bool = false
var ungagged: Dictionary = {}

## The gate. Exposed so a HUD can read its level for a meter.
var gate: GSVoiceGate = null

## Diagnostics.
var frames_captured: int = 0
var frames_sent: int = 0
var frames_received: int = 0
var bytes_sent: int = 0
var bytes_received: int = 0

var _capturing: bool = false
var _capture_refused: bool = false
var _client_published: bool = false
var _encoder: GSVoiceCodec = null
var _sequence: int = 0
var _playback_root: Node = null
var _registered_name: StringName = &""
## speaker -> {jitter: GSVoiceJitter, sink: GSVoiceSink, speaking: bool, quiet_ms: float}
var _speakers: Dictionary = {}
var _accumulated_ms: float = 0.0
## Channel outgoing speech is sent on.
var channel: int = GSVoiceRouter.Channel.ALL


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if config == null:
		config = GSVoiceConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		GSLog.result(CHANNEL, "loading the voice config", loaded)

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		GSLog.error(CHANNEL, "the voice config is not usable", {
			"why": valid.error.message
		})
		return

	gate = GSVoiceGate.new()
	open_mic = open_mic or not config.push_to_talk
	gate.push_to_talk = not open_mic
	gate.activation_rms = config.activation_rms
	gate.release_ratio = config.release_ratio
	gate.hangover_ms = config.hangover_ms

	if playback_root_ref == null:
		playback_root_ref = GSNodeRef.of_created(&"Voices", Node)
	_playback_root = playback_root_ref.resolve_or_null(self, CHANNEL)

	if register_service:
		_registered_name = (
			GSRegistry.scoped_name(SERVICE, service_scope) if service_scope != &""
			else SERVICE
		)
		GSRegistry.register(_registered_name, self)

	set_process(true)


func _exit_tree() -> void:
	stop_capture()
	for speaker in _speakers.keys():
		_destroy_speaker(int(speaker))
	if _registered_name != &"":
		GSRegistry.unregister_instance(_registered_name, self)
	if _client_published:
		GSRegistry.unregister_instance(CLIENT_SERVICE, self)
		_client_published = false
	if GSRegistry.signals().service_registered.is_connected(_on_service_registered):
		GSRegistry.signals().service_registered.disconnect(_on_service_registered)



## Opens the microphone. Call this when the player has agreed, and not before.
##
## Returns a failure the host should show rather than swallow (e.g. audio input disabled in project settings).
func start_capture() -> GSResult:
	if _capturing:
		return GSResult.success(true)

	if source == null:
		var mic := GSVoiceSourceMicrophone.new(self, config.sample_rate)
		mic.gain = config.input_gain
		source = mic

	source.sample_rate = config.sample_rate

	var started := source.start()

	if not started.ok:
		capture_failed.emit(started.error)
		return started

	_encoder = GSVoiceCodec.instance_for(config.codec_id)

	if _encoder == null:
		source.stop()
		var error := GSError.make(
			GSError.CODE_INVALID, "No codec with id '%s'." % config.codec_id
		)
		capture_failed.emit(error)
		return GSResult.failure(error)

	_capturing = true
	GSLog.info(CHANNEL, "capture started", config.describe())

	return GSResult.success(true)


func stop_capture() -> void:
	if not _capturing:
		return

	_capturing = false

	if source != null:
		source.stop()

	if gate != null and gate.is_open():
		gate.reset()
		talking_changed.emit(false)

	GSLog.info(CHANNEL, "capture stopped")


func is_capturing() -> bool:
	return _capturing


## Sets the push-to-talk key state.
func set_talking(pressed: bool) -> void:
	if gate != null:
		gate.set_pressed(pressed and server_enabled)


## The talk key, held or not, once a frame: what a client calls instead of [method set_talking] and [method start_capture].
##
## The first press is the consent and opens the microphone (also the user gesture a browser wants; in open-mic mode it stays open). Returns the failure to start, once, for the host to show.
func update_talk(held: bool) -> GSResult:
	if not server_enabled:
		if is_talking():
			set_talking(false)
		return GSResult.success(false)

	if held and not _capturing and not _capture_refused:
		var started := start_capture()
		if not started.ok:
			# Once per press, not once per frame: a machine with no microphone holding V
			# would otherwise log fifty lines a second.
			_capture_refused = true
			return started

	if not held:
		_capture_refused = false

	set_talking(held)
	return GSResult.success(held)


## Switches between push to talk and an open microphone. The microphone itself still opens
## on the first press of the talk key ([method update_talk]).
func set_open_mic(on: bool) -> void:
	open_mic = on
	if config != null:
		config.push_to_talk = not on
	if gate != null:
		gate.push_to_talk = not on
		gate.reset()


## Which input device the engine captures from: a name from [method input_devices], or
## "Default". Unknown names are refused rather than passed on, because the engine falls
## back to the default with nothing more than an error in the console.
func set_input_device(device: String) -> bool:
	if device == "" or not input_devices().has(device):
		return false
	if AudioServer.input_device != device:
		AudioServer.input_device = device
		GSLog.info(CHANNEL, "input device set", {"device": device})
	return true


## The engine's input devices; "Default" is always first.
static func input_devices() -> PackedStringArray:
	return AudioServer.get_input_device_list()


## How loud other players are, 0..1. On the voice bus when there is one (where GameSpice Menu's
## `voice_volume` and GameSpice Audio's mixer already put it), otherwise on every speaker's player.
func set_volume(linear: float) -> void:
	var v := clampf(linear, 0.0, 4.0)
	var bus := AudioServer.get_bus_index(playback_bus)
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(v) if v > 0.0 else -80.0)
		return
	if config != null:
		config.output_gain = v
	for key in _speakers.keys():
		var sink: Variant = _speakers[key]["sink"]
		if sink is GSVoiceSinkPlayer:
			(sink as GSVoiceSinkPlayer).gain = v


## Turns voice on or off on the server's word: stops capture and playback when off.
func set_server_enabled(on: bool) -> void:
	if on == server_enabled:
		return
	server_enabled = on
	if not on:
		stop_capture()
		for speaker in _speakers.keys():
			_destroy_speaker(int(speaker))
	GSLog.info(CHANNEL, "the server turned voice chat %s" % ("on" if on else "off"))
	server_enabled_changed.emit(on)


## Keeps [member server_enabled] on the server's [code]sv_voice_enable[/code] as [param source] reports it: gs-server's [code]GSClientLink[/code] or anything with [code]replicated_cvar(name, fallback)[/code] and a [code]replicated_cvar_changed[/code] signal. True when following.
##
## A null source waits for the shell's link ([code]gs_client_link[/code] in the registry) and follows it once registered; returns false then.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		var bus := GSRegistry.signals()
		if not bus.service_registered.is_connected(_on_service_registered):
			bus.service_registered.connect(_on_service_registered)
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false

	var held := String(source.call(&"replicated_cvar", GSVoiceRouter.CVAR_ENABLE, ""))
	if held != "":
		_on_replicated_cvar(GSVoiceRouter.CVAR_ENABLE, held)

	if not source.is_connected(&"replicated_cvar_changed", _on_replicated_cvar):
		source.connect(&"replicated_cvar_changed", _on_replicated_cvar)
	return true


## Registry name of the shell's client link, which carries the server's replicated cvars.
const LINK_SERVICE := &"gs_client_link"


func _on_service_registered(service: StringName, instance: Object) -> void:
	if service != LINK_SERVICE or instance == null:
		return
	GSRegistry.signals().service_registered.disconnect(_on_service_registered)
	var _following := follow_cvars(instance)


func _on_replicated_cvar(cvar_name: String, value: String) -> void:
	if cvar_name != GSVoiceRouter.CVAR_ENABLE:
		return
	var text := value.strip_edges()
	if text.is_valid_float():
		set_server_enabled(text.to_float() != 0.0)


## Publishes this manager as the process's own player's voice ([constant CLIENT_SERVICE]),
## for a settings menu to bind. Unpublished when it leaves the tree.
func publish_as_client() -> void:
	GSRegistry.register(CLIENT_SERVICE, self)
	_client_published = true


## Creates [constant TALK_ACTION] on [constant DEFAULT_TALK_KEY] if nothing has. A key table
## that binds it first (GameSpice Menu's) wins, because this only fills a gap.
static func ensure_talk_action() -> void:
	if InputMap.has_action(TALK_ACTION):
		return
	InputMap.add_action(TALK_ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = DEFAULT_TALK_KEY
	InputMap.action_add_event(TALK_ACTION, key)


## Whether the talk key is held right now. The action when it exists, else V.
static func is_talk_held() -> bool:
	if InputMap.has_action(TALK_ACTION):
		return Input.is_action_pressed(TALK_ACTION)
	return Input.is_physical_key_pressed(DEFAULT_TALK_KEY)


func is_talking() -> bool:
	return gate != null and gate.is_open()


## Current input level, 0..1, for a microphone meter.
func input_level() -> float:
	return gate.last_rms if gate != null else 0.0


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_pump_capture(delta)
	_pump_playback(delta)


## Reads whole frames out of the source and sends the ones the gate lets through.
##
## A loop, not one frame a tick: a hitch leaves several waiting and dropping them is an audible gap.
func _pump_capture(_delta: float) -> void:
	if not _capturing or source == null or not source.is_running():
		return

	var frame_samples := config.frame_samples()
	var guard := 0

	while source.has_frame(frame_samples) and guard < 16:
		guard += 1

		var samples := source.read_frame(frame_samples)
		if samples.size() < frame_samples:
			break

		frames_captured += 1

		var was_open := gate.is_open()
		var open := gate.evaluate(samples, config.frame_ms)

		if open != was_open:
			talking_changed.emit(open)

		if not open:
			# The encoder's state is reset between spurts so the next one starts from
			# silence rather than from wherever the last word left the predictor. A
			# stateful codec resumed mid-stream after a pause opens with a burst.
			if was_open and _encoder != null:
				_encoder.reset()
			continue

		var packet := GSVoicePacket.new()
		packet.speaker = 0
		packet.sequence = _sequence
		packet.sample_count = frame_samples
		packet.channel = channel
		packet.codec_id = config.codec_id
		packet.starts_talk_spurt = gate.is_spurt_start()
		packet.payload = _encoder.encode(samples)

		_sequence = (_sequence + 1) & 0xFFFF

		var bytes := packet.to_bytes()

		if send_fn.is_valid():
			send_fn.call(bytes)

		frames_sent += 1
		bytes_sent += bytes.size()
		frame_sent.emit(bytes.size())



## Takes one packet from the server; returns whether it was accepted, so a host on a shared channel knows whether to keep looking for a handler.
func receive(bytes: PackedByteArray) -> bool:
	var parsed := GSVoicePacket.from_bytes(bytes, config.frame_samples() * 4)

	if not parsed.ok:
		GSLog.debug(CHANNEL, "dropping a malformed voice packet", {
			"why": parsed.error.message
		})
		return false

	var packet: GSVoicePacket = parsed.value

	frames_received += 1
	bytes_received += bytes.size()

	if not server_enabled:
		return true

	# The listener's own preference, applied before any work is done. Decoding audio
	# nobody will hear is the one cost a local mute exists to avoid.
	if local_mutes.has(packet.speaker) or is_gagged(packet.speaker):
		return true

	var speaker := _ensure_speaker(packet.speaker, packet.codec_id)

	if speaker.is_empty():
		return false

	# The server's loudness for this listener. Held per speaker and applied when the frame
	# plays, so frames already queued in the jitter buffer keep playing at the gain they
	# were sent with rather than the one of the latest packet; one frame of lag at 20 ms.
	speaker["gain"] = packet.gain

	(speaker["jitter"] as GSVoiceJitter).push(packet)
	return true


## Stops playing a speaker on this machine only.
func set_local_mute(speaker: int, muted: bool) -> void:
	if muted:
		local_mutes[speaker] = true
		# Dropped rather than left to drain, so a mute takes effect on the word being
		# spoken rather than a jitter buffer later.
		if _speakers.has(speaker):
			(_speakers[speaker]["jitter"] as GSVoiceJitter).reset()
	else:
		local_mutes.erase(speaker)


## Stops (or resumes) hearing a speaker, on this machine only. See [member gagged].
func set_gag(speaker: int, on: bool) -> void:
	if on:
		gagged[speaker] = true
		ungagged.erase(speaker)
		if _speakers.has(speaker):
			(_speakers[speaker]["jitter"] as GSVoiceJitter).reset()
	else:
		gagged.erase(speaker)
		ungagged[speaker] = true


func is_gagged(speaker: int) -> bool:
	return gagged.has(speaker) or (gag_default and not ungagged.has(speaker))


func is_locally_muted(speaker: int) -> bool:
	return local_mutes.has(speaker)


## Moves a positional speaker to where that player is.
func set_speaker_position(speaker: int, position: Vector3) -> void:
	if not _speakers.has(speaker):
		return
	var sink: GSVoiceSink = _speakers[speaker]["sink"]
	if sink is GSVoiceSinkPlayer:
		(sink as GSVoiceSinkPlayer).set_position(position)


## Speakers currently making sound.
func active_speakers() -> PackedInt64Array:
	var out := PackedInt64Array()
	for key in _speakers.keys():
		if bool(_speakers[key]["speaking"]):
			out.append(int(key))
	return out


func forget_speaker(speaker: int) -> void:
	_destroy_speaker(speaker)


func _ensure_speaker(speaker: int, codec_id: StringName) -> Dictionary:
	if _speakers.has(speaker):
		return _speakers[speaker]

	# A codec instance of this speaker's own. Two speakers sharing one stateful decoder
	# interleave their predictors and both come out as noise.
	var codec := GSVoiceCodec.instance_for(codec_id)

	if codec == null:
		GSLog.warn(CHANNEL, "a speaker is using a codec this build does not have", {
			"speaker": speaker, "codec": String(codec_id)
		})
		return {}

	var jitter := GSVoiceJitter.new(config.frame_samples(), codec)
	jitter.target_frames = maxi(1, int(config.jitter_ms / config.frame_ms))
	jitter.max_frames = maxi(
		jitter.target_frames + 1, int(config.jitter_max_ms / config.frame_ms)
	)

	var sink: GSVoiceSink = null

	if sink_factory.is_valid():
		sink = sink_factory.call(speaker) as GSVoiceSink
	else:
		if _playback_root == null:
			_playback_root = playback_root_ref.resolve_or_null(self, CHANNEL)
		var player := GSVoiceSinkPlayer.new(_playback_root, config.sample_rate)
		player.positional = positional_playback and speaker_position_fn.is_valid()
		player.bus = playback_bus
		player.max_distance = config.proximity_range
		player.gain = config.output_gain
		sink = player

	if sink == null:
		return {}

	var started := sink.start()
	if not started.ok:
		GSLog.warn(CHANNEL, "could not start playback for a speaker", {
			"speaker": speaker, "why": started.error.message
		})
		return {}

	_speakers[speaker] = {
		"jitter": jitter, "sink": sink, "speaking": false, "quiet_ms": 0.0
	}

	return _speakers[speaker]


static func _scaled(frame: PackedFloat32Array, gain: float) -> PackedFloat32Array:
	var out := frame.duplicate()
	for i in range(out.size()):
		out[i] *= gain
	return out


func _destroy_speaker(speaker: int) -> void:
	if not _speakers.has(speaker):
		return

	var entry: Dictionary = _speakers[speaker]
	(entry["sink"] as GSVoiceSink).stop()

	if bool(entry["speaking"]):
		speaker_changed.emit(speaker, false)

	_speakers.erase(speaker)


## Hands one frame per speaker to their sink, at the rate the frames represent.
##
## Driven by an accumulator, not the frame rate: a 144 Hz client would drain a 50 frames-a-second stream three times too fast and stutter.
func _pump_playback(delta: float) -> void:
	if _speakers.is_empty():
		return

	if positional_playback and speaker_position_fn.is_valid():
		for key in _speakers.keys():
			var at: Variant = speaker_position_fn.call(int(key))
			if at is Vector3:
				set_speaker_position(int(key), at)

	_accumulated_ms += delta * 1000.0

	var guard := 0

	while _accumulated_ms >= config.frame_ms and guard < 8:
		_accumulated_ms -= config.frame_ms
		guard += 1

		for key in _speakers.keys():
			var speaker := int(key)
			var entry: Dictionary = _speakers[speaker]
			var jitter: GSVoiceJitter = entry["jitter"]
			var sink: GSVoiceSink = entry["sink"]

			var frame := jitter.pop()

			if frame.is_empty():
				if bool(entry["speaking"]):
					entry["quiet_ms"] = float(entry["quiet_ms"]) + config.frame_ms
					# A short gap is a lost packet, not a speaker who stopped. Reporting
					# a stop on the first one makes a talking indicator flicker on every
					# dropped frame.
					if float(entry["quiet_ms"]) >= 200.0:
						entry["speaking"] = false
						speaker_changed.emit(speaker, false)
				continue

			entry["quiet_ms"] = 0.0

			if not bool(entry["speaking"]):
				entry["speaking"] = true
				speaker_changed.emit(speaker, true)

			sink.write_frame(frame if is_equal_approx(float(entry.get("gain", 1.0)), 1.0) \
				else _scaled(frame, float(entry["gain"])))

	# A client that stalled for a second should not then play a second of audio as fast
	# as it can. Anything beyond the guard is time nobody gets back.
	if _accumulated_ms > config.frame_ms * 8.0:
		_accumulated_ms = 0.0


func describe() -> Dictionary:
	return {
		"server_enabled": server_enabled,
		"open_mic": open_mic,
		"capturing": _capturing,
		"talking": is_talking(),
		"speakers": _speakers.size(),
		"frames_sent": frames_sent,
		"frames_received": frames_received,
		"bytes_sent": bytes_sent,
		"bytes_received": bytes_received,
		"local_mutes": local_mutes.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if not server_enabled:
		out.append("voice     off on this server")
	out.append("capture   %s%s" % [
		"on" if _capturing else "off",
		", talking" if is_talking() else ""
	])
	out.append("sent      %d frames, %s" % [
		frames_sent, GSPaths.format_bytes(bytes_sent)
	])
	out.append("received  %d frames, %s" % [
		frames_received, GSPaths.format_bytes(bytes_received)
	])

	for key in _speakers.keys():
		var entry: Dictionary = _speakers[key]
		var jitter: GSVoiceJitter = entry["jitter"]
		out.append("  speaker %-6d %s buffered=%d late=%d lost=%d" % [
			int(key),
			"talking" if bool(entry["speaking"]) else "quiet ",
			jitter.buffered_frames(), jitter.dropped_late, jitter.concealed
		])

	return out
