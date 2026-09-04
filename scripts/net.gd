extends Node
class_name Net

## WebSocket 클라이언트. 프로토콜은 docs/protocol.md.
##
## 서버가 없거나 끊겨도 게임은 계속 돌아간다(혼자 플레이). 연결되면 서버 상태가
## 우선이다 — 두 출처가 갈릴 때 어느 쪽이 이기는지 정해두지 않으면 진행도가
## 사라지는 사고가 난다(docs/protocol.md §4).

signal opened
signal closed(reason: String)
signal welcomed(you: Dictionary, world: Dictionary)
signal snapshot_received(players: Array, items: Array)
signal player_joined(player: Dictionary)
signal player_left(token: String)
signal moves_received(moves: Array)
signal chat_received(msg: Dictionary)
signal emote_received(msg: Dictionary)
signal item_added(item: Dictionary)
signal item_removed(id: String, by: String)
signal inventory_received(inventory: Dictionary)
signal server_error(code: String, message: String)
signal rename_received(token: String, name: String)

## 내 위치는 10Hz로만 보낸다(서버 레이트 리밋과 같은 간격).
const MOVE_SEND_INTERVAL := 0.1
## 재연결 대기 시간(초). 실패할수록 늘려서 서버가 죽어 있을 때 재시도로
## 브라우저를 태우지 않는다.
const RECONNECT_BACKOFF := [2.0, 4.0, 8.0, 15.0]
## 이만큼 움직이지 않았으면 위치를 보내지 않는다(월드 단위).
const MOVE_EPSILON := 0.02

var connected := false

var _peer := WebSocketPeer.new()
var _url := ""
var _token := ""
var _name := ""
var _preset := ""
var _want_connection := false
var _move_timer := 0.0
var _last_sent := Vector2(INF, INF)
var _last_dir := ""
var _reconnect_timer := 0.0
var _reconnect_index := 0
var _was_open := false

## 서버 주소를 정한다.
## - 웹: 페이지를 서빙한 그 호스트의 /ws (https면 wss). 배포 서버가 정적 파일과
##   WS를 같은 포트에서 서빙하므로 별도 설정이 필요 없다(docs/deploy.md).
## - 데스크톱(에디터/헤드리스): 환경변수 ANIMALS_FARM_WS, 없으면 localhost:3001.
static func default_url() -> String:
	if OS.has_feature("web"):
		var origin := String(JavaScriptBridge.eval("window.location.origin", true))
		if origin.begins_with("https://"):
			return origin.replace("https://", "wss://") + "/ws"
		if origin.begins_with("http://"):
			return origin.replace("http://", "ws://") + "/ws"
		push_warning("웹인데 origin을 읽지 못함(%s) — 로컬 주소로 대체" % origin)
	var env := OS.get_environment("ANIMALS_FARM_WS")
	return env if not env.is_empty() else "ws://127.0.0.1:3001/ws"

func start(token: String, name: String, preset: String, url: String = "") -> void:
	_token = token
	_name = name
	_preset = preset
	_url = url if not url.is_empty() else default_url()
	_want_connection = true
	_open()

func stop() -> void:
	_want_connection = false
	_peer.close()

func _open() -> void:
	var err := _peer.connect_to_url(_url)
	if err != OK:
		push_warning("WS 연결 시도 실패(%d): %s — 혼자 플레이로 계속" % [err, _url])
		_schedule_reconnect()

func _schedule_reconnect() -> void:
	var idx := mini(_reconnect_index, RECONNECT_BACKOFF.size() - 1)
	_reconnect_timer = RECONNECT_BACKOFF[idx]
	_reconnect_index += 1

func _process(delta: float) -> void:
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0 and _want_connection:
			_open()
		return

	_peer.poll()
	var state := _peer.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			connected = true
			_reconnect_index = 0
			_send({"t": "join", "token": _token, "name": _name, "preset": _preset})
			opened.emit()
		while _peer.get_available_packet_count() > 0:
			_handle_packet(_peer.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open:
			_was_open = false
			connected = false
			closed.emit("code=%d %s" % [_peer.get_close_code(), _peer.get_close_reason()])
		if _want_connection and _reconnect_timer <= 0.0:
			_schedule_reconnect()

	_move_timer += delta

func _handle_packet(bytes: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("서버 메시지 파싱 실패")
		return
	var msg := parsed as Dictionary
	match String(msg.get("t", "")):
		"welcome":
			welcomed.emit(msg.get("you", {}), msg.get("world", {}))
		"snapshot":
			snapshot_received.emit(msg.get("players", []), msg.get("items", []))
		"join":
			player_joined.emit(msg.get("player", {}))
		"leave":
			player_left.emit(String(msg.get("token", "")))
		"move":
			moves_received.emit(msg.get("moves", []))
		"chat":
			chat_received.emit(msg)
		"emote":
			emote_received.emit(msg)
		"item_add":
			item_added.emit(msg.get("item", {}))
		"item_remove":
			item_removed.emit(String(msg.get("id", "")), String(msg.get("by", "")))
		"inventory":
			inventory_received.emit(msg.get("inventory", {}))
		"rename":
			rename_received.emit(String(msg.get("token", "")), String(msg.get("name", "")))
		"error":
			server_error.emit(String(msg.get("code", "")), String(msg.get("message", "")))
		_:
			push_warning("알 수 없는 서버 메시지: %s" % String(msg.get("t", "")))

func _send(msg: Dictionary) -> void:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_peer.send_text(JSON.stringify(msg))

## 위치 전송 — 10Hz 간격이고, 실제로 움직였을 때만 보낸다.
func send_move(pos: Vector3, dir: String) -> void:
	if not connected or _move_timer < MOVE_SEND_INTERVAL:
		return
	var flat := Vector2(pos.x, pos.z)
	if flat.distance_to(_last_sent) < MOVE_EPSILON and dir == _last_dir:
		return
	_move_timer = 0.0
	_last_sent = flat
	_last_dir = dir
	_send({
		"t": "move",
		"x": snappedf(pos.x, 0.01),
		"z": snappedf(pos.z, 0.01),
		"dir": dir,
	})

func send_gather(item_id: String) -> void:
	_send({"t": "gather", "item": item_id})

func send_chat(text: String) -> void:
	_send({"t": "chat", "text": text})

func send_emote(emote_id: String) -> void:
	_send({"t": "emote", "emote": emote_id})

func send_drop(item_id: String, pos: Vector3) -> void:
	_send({"t": "drop", "item": item_id, "x": snappedf(pos.x, 0.01), "z": snappedf(pos.z, 0.01)})

func send_pickup(entity_id: String) -> void:
	_send({"t": "pickup", "id": entity_id})
