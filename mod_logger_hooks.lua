local log = module._log;
local cjson = require "cjson";

module:log("info", "[Armored-Logger] Module loaded.");

local HOOKS_TO_LOG = {
    "user-registered", "user-authentication-success", "user-authentication-failure",
    "user-authenticated", "resource-bind", "session-created", "session-pre-bind",
    "session-bind", "session-started", "session-resumed", "session-closed",
    "muc-room-pre-create", "muc-room-created", "muc-room-destroyed",
    "muc-config-submitted", "muc-room-config-changed", "muc-occupant-pre-join",
    "muc-occupant-joined", "muc-occupant-role-changed", "muc-occupant-left",
    "muc-set-role", "muc-set-affiliation", "muc-privilege-request",
    "muc-broadcast-message", "muc-privmsg", "pre-presence/full", "pre-message/full",
    "pre-iq/full", "presence/full", "message/full", "iq/full",
    "jitsi-meet-token-accepted", "jitsi-meet-token-rejected", "jitsi-meet-token-check",
    "authentication-success", "authentication-failure",
}
local HOOK_PRIORITY = -100;

local function sanitize(data, seen)
    seen = seen or {};
    local data_type = type(data);

    if data_type ~= "table" then
        return (data_type == "string" or data_type == "number" or data_type == "boolean" or data == nil) and data or string.format("<%s>", data_type);
    end
    
    if seen[data] then return "<Circular Reference>"; end
    seen[data] = true;

    local clean_table = {};
    for k, v in pairs(data) do
        if type(k) == "string" or type(k) == "number" then
            clean_table[k] = sanitize(v, seen);
        end
    end
    
    seen[data] = nil;
    return clean_table;
end

local function safe_get(root, ...)
    local current = root;
    for i = 1, select('#', ...) do
        local key = select(i, ...);
        if type(current) ~= "table" or current[key] == nil then
            return nil;
        end
        current = current[key];
    end
    return current;
end

local function make_hook_logger(hook_name)
    return function(event)
        if type(event) ~= "table" then return; end

        local metadata = {
            timestamp    = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            event        = hook_name,
            origin_type  = safe_get(event, "origin", "type"),
            origin_jid   = safe_get(event, "origin", "full_jid"),
            ip           = safe_get(event, "origin", "conn", "ip"),
            is_admin     = safe_get(event, "origin", "jitsi_meet_context_user", "is_admin"),
            room_jid     = safe_get(event, "room", "jid"),
            room_name    = safe_get(event, "room", "_data", "name"),
            occupant_jid = tostring(safe_get(event, "occupant", "nick") or ""),
            actor        = tostring(safe_get(event, "actor") or ""),
            role         = safe_get(event, "occupant", "role"),
            affiliation  = safe_get(event, "occupant", "affiliation"),
            nick         = tostring(safe_get(event, "nick") or ""),
            stanza_name  = safe_get(event, "stanza", "name"),
        };

        metadata.raw_event = sanitize(event);

        local success, json_string = pcall(cjson.encode, metadata);

        if success then
            log("info", json_string);
        else
            log("error", "[Armored-Logger] FATAL: Failed to encode event '%s'. Reason: %s", hook_name, tostring(json_string));
        end
    end
end

module:log("info", "[Armored-Logger] Attaching %d hooks with priority %d...", #HOOKS_TO_LOG, HOOK_PRIORITY);
for _, hook_name in ipairs(HOOKS_TO_LOG) do
    module:hook(hook_name, make_hook_logger(hook_name), HOOK_PRIORITY);
end
module:log("info", "[Armored-Logger] All diagnostic hooks attached.");
