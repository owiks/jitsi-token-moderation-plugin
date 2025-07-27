-- mod_lobby_autostart_password.lua

local util = module:require "util"
local random = require "util.random"
local timer = require "util.timer"
local serialize = require "util.serialization".serialize -- для логов

local is_healthcheck_room = util.is_healthcheck_room
local TAG = "[LOBBY_AUTOSTART] "
local this_module = module

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

    -- retry loop
    local attempts = 0
    local max_attempts = 50
    local delay = 0.2

    local function try_set_password()
        attempts = attempts + 1

        local lobby_jid = room._data and room._data.lobbyroom
        if not lobby_jid then
            this_module:log("debug", TAG .. "Attempt %d: lobbyroom still missing for %s", attempts, jid)
        else
            this_module:log("debug", TAG .. "Attempt %d: found lobbyroom JID: %s", attempts, tostring(lobby_jid))

            local lobby_host = this_module:get_option_string("lobby_muc", "lobby.meet.jitsi")
            if not lobby_host then
                this_module:log("error", TAG .. "lobby_muc option is not defined in config")
                return
            end

            local lobby_module = prosody.hosts[lobby_host] and prosody.hosts[lobby_host].modules
            if not lobby_module then
                this_module:log("error", TAG .. "Cannot access modules of host: %s", lobby_host)
                return
            end

            local muc_module = lobby_module.muc
            if not muc_module or not muc_module.get_room_from_jid then
                this_module:log("error", TAG .. "MUC module not found or invalid on %s", lobby_host)
                return
            end

            local lobby_room = muc_module.get_room_from_jid(lobby_jid)
            if lobby_room then
                local password = random.hex(6)
                lobby_room:set_password(password)
                this_module:log("info", TAG .. "Set random password '%s' for lobby room: %s", password, lobby_jid)
                this_module:log("debug", TAG .. "Lobby room object: %s", serialize(lobby_room))
                return
            else
                this_module:log("debug", TAG .. "Attempt %d: lobby room object not yet available: %s", attempts, tostring(lobby_jid))
            end
        end

        if attempts < max_attempts then
            return delay
        else
            this_module:log("error", TAG .. "Timeout waiting for lobby room to appear for: %s", jid)
        end
    end

    timer.add_task(delay, try_set_password)
end)
