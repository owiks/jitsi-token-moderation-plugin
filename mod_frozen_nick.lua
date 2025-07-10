local log = module._log;
local json = require "cjson";

module:log("info", "Loaded mod_frozen_nick");

local function on_presence(event)
    local origin = event.origin;
    local stanza = event.stanza;

    if not origin then
        log("debug", "Presence ignored: event.origin is nil");
        return;
    end

    if not stanza then
        log("debug", "[%s] Presence ignored: event.stanza is nil", origin.username or "unknown");
        return;
    end

    local jid = origin.username or "unknown";
    log("debug", "[%s] Presence received:\n%s", jid, tostring(stanza));

    local user_ctx = origin.jitsi_meet_context_user;
    if not user_ctx then
        log("debug", "[%s] No jitsi_meet_context_user in session. Skipping nick override.", jid);
        return;
    end

    -- 🔍 логируем весь контекст
    local ok, ctx_dump = pcall(json.encode, user_ctx);
    if ok then
        log("debug", "[%s] jitsi_meet_context_user: %s", jid, ctx_dump);
    else
        log("debug", "[%s] Failed to JSON encode jitsi_meet_context_user", jid);
    end

    if not user_ctx.name then
        log("debug", "[%s] jitsi_meet_context_user.name is not set. Skipping nick override.", jid);
        return;
    end

    local forced_nick = user_ctx.name;
    log("debug", "[%s] Forcing nick to '%s' from JWT context", jid, forced_nick);

    -- лог всех старых ников
    for tag in stanza:childtags("nick", "http://jabber.org/protocol/nick") do
        log("debug", "[%s] Found original nick: '%s'", jid, tag:get_text());
    end

    -- удаляем все <nick>
    stanza:maptags(function(tag)
        if tag.name == "nick" and tag.attr.xmlns == "http://jabber.org/protocol/nick" then
            log("debug", "[%s] Removing existing <nick>", jid);
            return nil;
        end
        return tag;
    end)

    -- вставляем новый <nick>
    stanza:tag("nick", { xmlns = "http://jabber.org/protocol/nick" }):text(forced_nick):up();

    log("debug", "[%s] Nick successfully set to '%s'", jid, forced_nick);
    log("debug", "[%s] Modified stanza:\n%s", jid, tostring(stanza));
end

module:hook("pre-presence/bare", on_presence);
module:hook("pre-presence/full", on_presence);
