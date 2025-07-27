local random = require "util.random";

module:hook("create-persistent-lobby-room", function(event)
    local main_room = event.room;
    if not main_room then return end

    -- Проверка: лобби уже создано
    if not main_room._data.lobbyroom then return end

    local lobby_jid = main_room._data.lobbyroom;
    local lobby_service = module:get_host_module(module:get_option_string("lobby_muc")):get_module("muc");
    if not lobby_service then
        module:log("error", "Cannot find lobby muc service");
        return;
    end

    local lobby_room = lobby_service.get_room_from_jid(lobby_jid);
    if not lobby_room then
        module:log("warn", "Lobby room not found for %s", tostring(lobby_jid));
        return;
    end

    -- Генерируем случайный пароль и применяем
    local password = random.hex(6);  -- длина 6 символов (можно изменить)
    lobby_room:set_password(password);

    module:log("info", "[LOBBY_AUTOSTART] Set random password '%s' for lobby room %s", password, lobby_jid);
end);
