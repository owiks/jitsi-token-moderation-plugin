local LOGLEVEL = "debug"
local util = module:require "util"
local is_admin = util.is_admin
local is_healthcheck_room = util.is_healthcheck_room

module:log("info", "mod_token_lobby_bypass_for_initiator loaded")

module:hook("muc-room-pre-create", function (event)
    local room = event.room

    if is_healthcheck_room(room.jid) then
        return
    end

    room._data.initiator_joined = false
    module:log(LOGLEVEL, "Room pre-create: %s, initiator_joined=false", tostring(room.jid))
end)

module:hook("muc-occupant-pre-join", function (event)
    local session, room, occupant = event.origin, event.room, event.occupant

    if not (session and room and occupant) then
        module:log("warn", "Missing session, room, or occupant")
        return
    end

    local jid = occupant.bare_jid
    module:log(LOGLEVEL, "Pre-join for %s in room %s", tostring(jid), tostring(room.jid))

    if is_admin(jid) or is_healthcheck_room(room.jid) then
        module:log(LOGLEVEL, "Skip admin or healthcheck user %s", tostring(jid))
        return
    end

    if room._data.initiator_joined then
        module:log(LOGLEVEL, "Initiator already joined for room %s", tostring(room.jid))
        return
    end

    if not room._data.lobbyroom then
        module:log(LOGLEVEL, "No active lobby for room %s", tostring(room.jid))
        return
    end

    if not session.auth_token then
        module:log(LOGLEVEL, "No token for %s", tostring(jid))
        return
    end

    local affiliation = "member"
    local context_user = session.jitsi_meet_context_user

    if context_user then
        local aff = context_user["affiliation"]
        local mod = context_user["moderator"]

        if aff == "owner" or aff == "moderator" or aff == "teacher" or mod == true or mod == "true" then
            affiliation = "owner"
        end
    end

    module:log(LOGLEVEL, "Calculated affiliation for %s = %s", tostring(jid), affiliation)

    if affiliation ~= "owner" then
        module:log(LOGLEVEL, "Bypass denied: not owner - %s", tostring(jid))
        return
    end

    occupant.role = 'participant'

    local ok, err = pcall(function()
        room:set_affiliation("token_plugin", jid, affiliation)
    end)

    if not ok then
        module:log("warn", "Failed to set affiliation for %s: %s", tostring(jid), tostring(err))
    else
        module:log(LOGLEVEL, "Bypassing lobby for room %s occupant %s", tostring(room.jid), tostring(jid))
    end

    room._data.initiator_joined = true
end, -3)
