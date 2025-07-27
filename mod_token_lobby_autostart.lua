-- mod_lobby_autostart_password.lua

local util = module:require "util"
local random = require "util.random"
local timer = require "util.timer"

local is_healthcheck_room = util.is_healthcheck_room
local TAG = "[LOBBY_AUTOSTART] "
local this_module = module  -- сохранить module в замыкании для таймера

this_module:log("info", TAG .. "Loaded module: auto-lobby + random password")

this_module:hook("muc-room-pre-create", function (event)
    local room = event.room
    if not room then
        this_module:log("error", TAG .. "room is nil in muc-room-pre-create")
        return
    end

    local jid = room.jid
    if is_healthcheck_room(jid) then
        this_module:log("debug", TAG .. "Skipping healthcheck room: %s", jid)
        return
    end

    this_module:log("info", TAG .. "Creating room with lobby: %s", jid)

    prosody.events.fire_event("create-persistent-lobby-room", { room = room })

    -- Функция с повторной проверкой
    local attempts = 0
    local max_attempts = 50
    local delay = 0.2

    local function try_set_password()
        attempts = attempts + 1
        local lobby_jid = room._data and room._data.lobbyroom
        if not lobby_jid then
            this_module:log("debug", TAG .. "Attempt %d: lobbyroom still missing for %s", attempts, jid)
        else
            this_module:log("debug", TAG .. "Attempt %d: found lobbyroom %s", attempts, tostring(lobby_jid))

            local lobby_host = this_module:get_option_string("lobby_muc", "lobby.meet.jitsi")
            local lobby_module = this_module:get_host_module(lobby_host)
            if not lobby_module then
                this_module:log("error", TAG .. "Cannot get host module for %s", lobby_host)
                return
            end

            local lobby_service = lobby_module:get_module("muc")
            if not lobby_service then
                this_module:log("error", TAG .. "Cannot get muc module from %s", lobby_host)
                return
            end

            local lobby_room = lobby_service.get_room_from_jid(lobby_jid)
            if lobby_room then
                local password = random.hex(6)
                lobby_room:set_password(password)
                this_module:log("info", TAG .. "Set random password '%s' for lobby room: %s", password, lobby_jid)
                return
            else
                this_module:log("debug", TAG .. "Attempt %d: lobby room object not yet found: %s", attempts, tostring(lobby_jid))
            end
        end

        if attempts < max_attempts then
            return delay
        else
            this_module:log("error", TAG .. "Timeout waiting for lobby room for %s", jid)
        end
    end

    timer.add_task(delay, try_set_password)
end)
