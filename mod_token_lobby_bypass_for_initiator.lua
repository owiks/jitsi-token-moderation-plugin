--- Plugin to allow the initiator to bypass the lobby. The initiator is the
--- first user joining the room with moderator/owner right.
---
--- This module should be added to the main muc component.
---

local LOGLEVEL = "debug"

local util = module:require "util"
local is_admin = util.is_admin
local is_healthcheck_room = util.is_healthcheck_room
local jid = require "util.jid"
local serialize = require "util.serialization".serialize
local muc_util = module:require "muc/util";
local valid_affiliations = muc_util.valid_affiliations;
local is_healthcheck_room = util.is_healthcheck_room;

module:log("info", "[LOBBY_BYPASS] Module loaded")

module:hook("muc-room-pre-create", function (event)
    local room = event.room

    if not room then
        module:log("error", "[LOBBY_BYPASS] muc-room-pre-create: room is nil")
        return
    end

    if is_healthcheck_room(room.jid) then
        return
    end

    module:log(LOGLEVEL, "[LOBBY_BYPASS] muc-room-pre-create for room: %s", tostring(room.jid))
    room._data.initiator_joined = false
end)

module:hook("muc-occupant-pre-join", function (event)
    local session, room, occupant = event.origin, event.room, event.occupant

    if not (session and room and occupant) then
        module:log("warn", "[LOBBY_BYPASS] missing session/room/occupant in pre-join")
        return
    end

    module:log(LOGLEVEL, "[LOBBY_BYPASS] occupant.nick: %s", tostring(occupant.nick))
    module:log(LOGLEVEL, "[LOBBY_BYPASS] occupant.bare_jid: %s", tostring(occupant.bare_jid))
    module:log(LOGLEVEL, "[LOBBY_BYPASS] room.jid: %s", tostring(room.jid))

    if is_healthcheck_room(room.jid) then
        return
    end

    local is_admin_user = is_admin(occupant.bare_jid)

    if is_admin_user then
        module:log(LOGLEVEL, "[LOBBY_BYPASS] occupant is admin: %s", occupant.bare_jid)
    end

    if room._data.initiator_joined then
        module:log(LOGLEVEL, "[LOBBY_BYPASS] Initiator already joined: %s", tostring(room.jid))
        return
    end

    if not room._data.lobbyroom then
        module:log(LOGLEVEL, "[LOBBY_BYPASS] Room has no active lobby: %s", tostring(room.jid))
        return
    end

    if not session.auth_token then
        module:log(LOGLEVEL, "[LOBBY_BYPASS] Skipping user with no token: %s", tostring(occupant.bare_jid))
        return
    end

    local context_user = session.jitsi_meet_context_user or {}
    module:log(LOGLEVEL, "[LOBBY_BYPASS] context_user: %s", serialize(context_user))

    local is_moderator = false

    if context_user["moderator"] == true or context_user["moderator"] == "true" then
        is_moderator = true
    end

    if context_user["affiliation"] == "owner" or context_user["affiliation"] == "moderator" or context_user["affiliation"] == "teacher" then
        is_moderator = true
    end

    if not is_moderator then
        module:log(LOGLEVEL, "[LOBBY_BYPASS] User not moderator: %s", tostring(occupant.bare_jid))
        return
    end

    module:log(LOGLEVEL, "[LOBBY_BYPASS] Moderator identified, setting affiliation and role")
    module:log(LOGLEVEL, "Bypassing lobby for room %s occupant %s", room.jid, occupant.bare_jid);

    occupant.role = 'participant';

    local affiliation = room:get_affiliation(occupant.bare_jid);
    module:log(LOGLEVEL, "affiliation %s occupant %s", affiliation, occupant.bare_jid);

    if valid_affiliations[affiliation or "none"] < valid_affiliations.member then
        module:log(LOGLEVEL, "Setting affiliation for %s -> member", occupant.bare_jid);
    end
    room:set_affiliation(true, occupant.bare_jid, 'member');

    room._data.initiator_joined = true

    module:log(LOGLEVEL, "[LOBBY_BYPASS] Bypassing lobby for %s, set owner affiliation", tostring(occupant.bare_jid))
end, -3)
