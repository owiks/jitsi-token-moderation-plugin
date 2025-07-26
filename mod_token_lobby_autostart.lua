-- Enhanced mod_token_lobby_autostart.lua with detailed logging
-- Auto-activates lobby unless lobby_autostart is disabled in the token payload

local LOGLEVEL = "debug"
local util = module:require "util";
local is_admin = util.is_admin;
local is_healthcheck_room = util.is_healthcheck_room;

local TAG = "[LOBBY_AUTOSTART] ";

module:log("info", TAG .. "Loaded enhanced module");

module:hook("muc-room-pre-create", function (event)
    local room = event.room

    if not room then
        module:log("error", TAG .. "muc-room-pre-create: room is nil");
        return;
    end

    if is_healthcheck_room(room.jid) then
        module:log(LOGLEVEL, TAG .. "Healthcheck room, skipping: %s", room.jid);
        return;
    end

    module:log("info", TAG .. "Creating room: %s", tostring(room.jid));

    room._data.auto_lobby_deactivated = false;

    prosody.events.fire_event("create-persistent-lobby-room", { room = room; });
end);

module:hook("muc-occupant-pre-join", function (event)
    local session, room, occupant = event.origin, event.room, event.occupant;

    if not (session and room and occupant) then
        module:log("warn", TAG .. "muc-occupant-pre-join: Missing session, room, or occupant");
        return;
    end

    local bare_jid = occupant.bare_jid or "nil";

    if is_admin(bare_jid) then
        module:log(LOGLEVEL, TAG .. "Skipping admin %s", bare_jid);
        return;
    end

    if is_healthcheck_room(room.jid) then
        module:log(LOGLEVEL, TAG .. "Skipping healthcheck room %s", room.jid);
        return;
    end

    if room._data.lobby_deactivated then
        module:log(LOGLEVEL, TAG .. "Lobby already deactivated for %s", room.jid);
        return;
    end

    if not session.auth_token then
        module:log(LOGLEVEL, TAG .. "No token found for %s", bare_jid);
        return;
    end

    local context_room = session.jitsi_meet_context_room;
    if not context_room then
        module:log(LOGLEVEL, TAG .. "No context room in token for %s", bare_jid);
        return;
    end

    module:log(LOGLEVEL, TAG .. "Token context: %s", require "util.serialization".serialize(context_room));

    if context_room["lobby_autostart"] == false then
        module:log("info", TAG .. "Deactivating lobby for %s by token", room.jid);

        room:set_members_only(false);

        local role = room:get_default_role(room:get_affiliation(bare_jid));
        occupant.role = role or 'participant';

        prosody.events.fire_event('destroy-lobby-room', {
            room = room,
            newjid = room.jid,
        });

        room._data.lobby_deactivated = true;

        module:log("info", TAG .. "Lobby auto-start disabled for room %s", room.jid);
    else
        module:log(LOGLEVEL, TAG .. "lobby_autostart is enabled (default) for %s", room.jid);
    end
end, -2);
