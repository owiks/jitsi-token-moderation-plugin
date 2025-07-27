-- mod_lobby_autostart_password.lua

local util = module:require "util"
local random = require "util.random"
local timer = require "util.timer"

local is_healthcheck_room = util.is_healthcheck_room
local TAG = "[LOBBY_AUTOSTART] "

module:log("info", TAG .. "Loaded module: auto-lobby + random password")

module:hook("muc-room-pre-create", function (event)
    local room = event.room
    if not room then
        module:log("error", TAG .. "room is nil in muc-room-pre-create")
        return
    end

    local jid = room.jid
    if is_healthcheck_room(jid) then
        module:log("debug", TAG .. "Skipping healthcheck room: %s", jid)
        return
    end

    module:log("info", TAG .. "Creating room with lobby: %s", jid)

    prosody.events.fire_event("create-persistent-lobby-room", { room = room })

    -- Функция с повторной проверкой
    local attempts = 0
    local max_attempts = 50
    local delay = 0.2

    local function try_set_password()
        attempts = attempts + 1
        local lobby_jid = room._data and room._data.lobbyroom
        if not lobby_jid then
            module:log("debug", TAG .. "Attempt %d: lobbyroom still missing for %s", attempts, jid)
        else
            local lobby_host = module:get_option_string("lobby_muc")
            if not lobby_host then
                module:log("error", TAG .. "lobby_muc option not defined")
                return
            end

            local lobby_module = module:get_host_module(lobby_host)
            if not lobby_module then
                module:log("error", TAG .. "Cannot get host module for %s", lobby_host)
                return
            end

            local lobby_service = lobby_module:get_module("muc")
            if not lobby_service then
                module:log("error", TAG .. "Cannot get muc module for %s", lobby_host)
                return
            end

            local lobby_room = lobby_service.get_room_from_jid(lobby_jid)
            if lobby_room then
                local password = random.hex(6)
                lobby_room:set_password(password)
                module:log("info", TAG .. "Set random password '%s' for lobby room: %s", password, lobby_jid)
                return  -- успешно, выходим
            else
                module:log("debug", TAG .. "Attempt %d: lobby room object not yet found: %s", attempts, lobby_jid)
            end
        end

        if attempts < max_attempts then
            return delay  -- повторить через delay секунд
        else
            module:log("error", TAG .. "Timeout waiting for lobby room for %s", jid)
        end
    end

    timer.add_task(delay, try_set_password)
end)
