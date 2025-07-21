local log = module._log;
local cjson = require "cjson";

log('info', '[Logger-Hooks] Module loaded.');

-- --- CONFIGURATION ---
local MAX_DEPTH = 4; -- Max recursion depth for the text logger

---
-- Text Formatter: Recursively formats a table into a readable string with depth limit.
---
local function format_text_with_depth(data, depth)
    depth = depth or 1;
    if depth > MAX_DEPTH then return "{... MAX_DEPTH ...}"; end
    local t = type(data);
    if t == "table" then
        local parts = {};
        for k, v in pairs(data) do
            if type(v) ~= "function" and type(v) ~= "cdata" and type(v) ~= "userdata" then
                local key_str = string.format("%-20s", tostring(k));
                table.insert(parts, string.format("%s = %s", key_str, format_text_with_depth(v, depth + 1)));
            end
        end
        if #parts == 0 then return "{}"; end
        return string.format("{\n%s  %s\n%s}", string.rep("  ", depth), table.concat(parts, ",\n" .. string.rep("  ", depth + 1)), string.rep("  ", depth));
    else
        return tostring(data);
    end
end

---
-- JSON Sanitizer: Cleans a table for safe JSON conversion, handling circular refs.
---
local function sanitize_for_json(data, visited)
    visited = visited or { [data] = true };
    local clean_table = {};
    for k, v in pairs(data) do
        local key_type = type(k);
        if key_type == "string" or key_type == "number" then
            local value_type = type(v);
            if value_type == "string" or value_type == "number" or value_type == "boolean" or value_type == "nil" then
                clean_table[k] = v;
            elseif value_type == "table" then
                if visited[v] then
                    clean_table[k] = "[Circular Reference]";
                else
                    visited[v] = true;
                    clean_table[k] = sanitize_for_json(v, visited);
                end
            else
                clean_table[k] = string.format("[%s]", value_type);
            end
        end
    end
    return clean_table;
end

---
-- Generic hook handler that logs in both formats.
---
local function log_event_hybrid(event)
    local event_name = event.event or "unknown_event";

    local text_output = format_text_with_depth(event);
    local clean_event = sanitize_for_json(event);
    
    local success, json_string = pcall(cjson.encode, clean_event);
    
    local json_output = success and json_string or string.format("{\"error\": \"Failed to encode event to JSON: %s\"}", tostring(json_string));
    
    log('debug', "\n---[ HOOK: %s ]---\n%s\n---[ END HOOK: %s ]---",
               event_name, json_output, event_name);
end

log('info', '[Hybrid-Logger] Attaching hooks...');

module:hook("user-authenticated", log_event_hybrid, -100);
module:hook("session-started", log_event_hybrid, -100);
module:hook("session-closed", log_event_hybrid, -100);
module:hook("muc-room-pre-create", log_event_hybrid, -100);
module:hook("muc-room-created", log_event_hybrid, -100);
module:hook("muc-room-destroyed", log_event_hybrid, -100);
module:hook("muc-occupant-pre-join", log_event_hybrid, -100);
module:hook("muc-occupant-joined", log_event_hybrid, -100);
module:hook("muc-occupant-left", log_event_hybrid, -100);
module:hook("muc-set-affiliation", log_event_hybrid, -100);
module:hook("muc-set-role", log_event_hybrid, -100);
module:hook("pre-presence/full", log_event_hybrid, -100);
module:hook("pre-message/full", log_event_hybrid, -100);
module:hook("pre-iq/full", log_event_hybrid, -100);
log('info', '[Logger-Hooks] All diagnostic hooks have been successfully attached.');
