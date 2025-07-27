local random = require "util.random";

module:hook("create-persistent-lobby-room", function(event)
    local TAG = "[LOBBY_AUTOSTART] ";
    local main_room = event.room;

    if not main_room then
        module:log("error", TAG .. "main_room is nil in create-persistent-lobby-room event");
        return;
    end

    module:log("info", TAG .. "Triggered for room: %s", tostring(main_room.jid));

    if not main_room._data then
        module:log("error", TAG .. "main_room._data is nil");
        return;
    end

    if not main_room._data.lobbyroom then
        module:log("warn", TAG .. "main_room._data.lobbyroom is nil — lobby might not be attached yet");
        return;
    end

    local lobby_jid = main_room._data.lobbyroom;
    module:log("info", TAG .. "Detected lobby JID: %s", tostring(lobby_jid));

    local lobby_muc_host = module:get_option_string("lobby_muc");
    if not lobby_muc_host then
        module:log("error", TAG .. "lobby_muc config not set");
        return;
    end

    local lobby_module = module:get_host_module(lobby_muc_host);
    if not lobby_module then
        module:log("error", TAG .. "Cannot get host module for lobby_muc: %s", lobby_muc_host);
        return;
    end

    local lobby_service = lobby_module:get_module("muc");
    if not lobby_service then
        module:log("error", TAG .. "Cannot get muc module from lobby host: %s", lobby_muc_host);
        return;
    end

    local lobby_room = lobby_service.get_room_from_jid(lobby_jid);
    if not lobby_room then
        module:log("error", TAG .. "Lobby room object not found by JID: %s", tostring(lobby_jid));
        return;
    end

    module:log("info", TAG .. "Lobby room found: %s", lobby_jid);

    local password = random.hex(6);
    lobby_room:set_password(password);

    module:log("info", TAG .. "Random password '%s' set for lobby room: %s", password, lobby_jid);
end);
