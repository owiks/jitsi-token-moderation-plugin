local log = module._log
local cjson = require "cjson"

module:log("info", "[Logger-Hooks] Module loaded.")

-- --- CONFIGURATION ---
local HOOK_PRIORITY = module:get_option_number("logger_hooks_priority", -100)
local LOG_RAW_EVENT = module:get_option_boolean("logger_hooks_log_raw", false)

-- --- HOOKS TO LOG ---
local HOOKS_TO_LOG = {
    "user-registered", "user-authentication-success", "user-authentication-failure", "user-authenticated",
    "resource-bind", "session-created", "session-pre-bind", "session-bind", "session-started", "session-resumed", "session-closed",
    "muc-room-pre-create", "muc-room-created", "muc-room-destroyed", "muc-config-submitted", "muc-room-config-changed",
    "muc-occupant-pre-join", "muc-occupant-joined", "muc-occupant-role-changed", "muc-occupant-left",
    "muc-set-role", "muc-set-affiliation", "muc-privilege-request",
    "muc-broadcast-message", "muc-privmsg",
    "pre-presence/full", "pre-message/full", "pre-iq/full",
    "presence/full", "message/full", "iq/full",
    "jitsi-meet-token-accepted", "jitsi-meet-token-rejected", "jitsi-meet-token-check",
    "authentication-success", "authentication-failure",
}

-- --- LOG WRAPPER ---
local function log_info(fmt, ...)
    log("info", "[Logger-Hooks] " .. fmt, ...)
end

-- --- METADATA EXTRACTION ---
local function extract_event_metadata(hook_name, event)
    local stanza_text = nil
    if event.stanza and event.stanza.top_tag then
        pcall(function() stanza_text = event.stanza:top_tag() end)
    elseif event.stanza then
        stanza_text = tostring(event.stanza)
    end

    return {
        timestamp      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event          = hook_name,
        origin_type    = event.origin and event.origin.type or nil,
        origin_jid     = event.origin and event.origin.full_jid or nil,
        ip             = event.origin and event.origin.conn and event.origin.conn.ip or nil,
        is_admin       = event.origin and event.origin.jitsi_meet_context_user and event.origin.jitsi_meet_context_user.is_admin or nil,
        room_jid       = event.room and event.room.jid or nil,
        room_name      = event.room and event.room._data and event.room._data.name or nil,
        occupant_jid   = event.occupant and tostring(event.occupant.nick) or nil,
        actor          = event.actor and tostring(event.actor) or nil,
        role           = event.occupant and event.occupant.role or nil,
        affiliation    = event.occupant and event.occupant.affiliation or nil,
        nick           = event.nick and tostring(event.nick) or nil,
        stanza_name    = event.stanza and event.stanza.name or nil,
        stanza_raw     = stanza_text,
        event_debug    = tostring(event),
        raw            = LOG_RAW_EVENT and event or nil
    }
end

-- --- JSON ENCODER ---
-- --- JSON ENCODER ---
local function encode_event_to_json(event_meta)
    local clean = {}

    for k, v in pairs(event_meta) do
        if k ~= "raw" then
            clean[k] = v
        end
    end

    if LOG_RAW_EVENT and event_meta.raw then
        clean.raw = "[raw event omitted]"
    end

    local ok, encoded = pcall(cjson.encode, clean)
    if not ok then
        log("error", "[Logger-Hooks] Failed to encode event '%s': %s", tostring(event_meta.event), tostring(encoded))
        return nil
    end
    return encoded
end

-- --- HOOK WRAPPER GENERATOR ---
local function make_hook_logger(hook_name)
    return function(event)
        if type(event) ~= "table" then
            log("warn", "[Logger-Hooks] Invalid event type for %s: %s", hook_name, type(event))
            return
        end
        local metadata = extract_event_metadata(hook_name, event)
        local json_output = encode_event_to_json(metadata)
        if not json_output then return end
        log("debug", "[Logger-Hooks] %s %s", hook_name, json_output)
    end
end

-- --- REGISTER HOOKS ---
log_info("Attaching hooks with priority %d...", HOOK_PRIORITY)

for _, hook in ipairs(HOOKS_TO_LOG) do
    local handler = make_hook_logger(hook)
    module:hook(hook, handler, HOOK_PRIORITY)
    module:hook_global(hook, handler, HOOK_PRIORITY)
end

log_info("All diagnostic hooks attached.")
