local log = module._log;
local cjson = require "cjson";

module:log("info", "[Hook-Logger] Module loaded.");

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

local function sanitize(data, seen, depth)
    depth = depth or 0
    if depth > 15 then
        log("debug", "[Hook-Logger][sanitize] Max depth reached at depth %d", depth)
        return "<max_depth_reached>"
    end

    local data_type = type(data)
    if data_type ~= "table" then
        local simple = (data_type == "string" or data_type == "number" or data_type == "boolean" or data == nil)
        if not simple then
            log("debug", "[Hook-Logger][sanitize] Non-simple type %s encountered: %s", data_type, tostring(data))
        end
        return simple and data or string.format("<%s>", data_type)
    end

    if not seen then seen = {} end
    if seen[data] then
        log("debug", "[Hook-Logger][sanitize] Circular reference detected at depth %d", depth)
        return "<Circular Reference>"
    end
    seen[data] = true

    local clean_table = {}
    for k, v in pairs(data) do
        local kt = type(k)
        if kt == "string" or kt == "number" then
            log("trace", "[Hook-Logger][sanitize] Processing key '%s' of type '%s' at depth %d", tostring(k), kt, depth)
            local vt = type(v)
            if vt == "table" then
                clean_table[k] = sanitize(v, seen, depth + 1)
            elseif vt == "string" or vt == "number" or vt == "boolean" or vt == "nil" then
                clean_table[k] = v
            else
                log("debug", "[Hook-Logger][sanitize] Unsupported value type '%s' at key '%s'", vt, tostring(k))
                clean_table[k] = string.format("<%s>", vt)
            end
        else
            log("debug", "[Hook-Logger][sanitize] Unsupported key type '%s' at depth %d", kt, depth)
        end
    end

    seen[data] = nil
    return clean_table
end

local function safe_get(root, ...)
    local current = root
    for i = 1, select('#', ...) do
        local key = select(i, ...)
        if type(current) ~= "table" or current[key] == nil then
            log("debug", "[Hook-Logger][safe_get] Missing key '%s' at depth %d", tostring(key), i)
            return nil
        end
        current = current[key]
    end
    return current
end

local function make_hook_logger(hook_name)
    return function(event)
        if type(event) ~= "table" then
            log("warn", "[Hook-Logger] Invalid event type for %s: %s", hook_name, type(event))
            return
        end

        log("debug", "[Hook-Logger] %s event debug string: %s", hook_name, tostring(event))

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
        }

        log("debug", "[Hook-Logger] Sanitizing event for JSON serialization")
        --metadata.raw_event = sanitize(event)
        --log("debug", "[Hook-Logger] Sanitized event: %s", tostring(metadata.raw_event) or "<nil>")

        local success, json_string = pcall(cjson.encode, metadata)

        if success then
            log("info", "[Hook-Logger] %s %s", hook_name, json_string)
        else
            log("error", "[Hook-Logger] Failed to encode metadata for '%s': %s", hook_name, tostring(metadata))
            log("error", "[Hook-Logger] FATAL: Failed to encode event '%s'. Reason: %s", hook_name, tostring(json_string))
        end
    end
end

module:log("info", "[Hook-Logger] Attaching %d hooks with priority %d...", #HOOKS_TO_LOG, HOOK_PRIORITY)
for _, hook_name in ipairs(HOOKS_TO_LOG) do
    module:hook(hook_name, make_hook_logger(hook_name), HOOK_PRIORITY)
end
module:log("info", "[Hook-Logger] All diagnostic hooks attached.")
