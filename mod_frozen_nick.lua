local log  = module._log
local json = require "cjson"

log("info", "Loaded mod_frozen_nick (muc-occupant-pre-join)")

local function on_pre_join(event)
    local room     = event.room
    local occupant = event.occupant
    local origin   = occupant and occupant.origin
    local stanza   = event.stanza

    if not (room and origin and stanza) then
        log("warn", "Received pre-join without full context — room=%s origin=%s stanza=%s",
            tostring(room and room.jid), tostring(origin), tostring(stanza))
        return
    end

    local bare_jid = origin.username or "unknown"
    log("info", "[%s] Pre-join for room %s", bare_jid, room.jid)

    local ctx = origin.jitsi_meet_context_user
    if not ctx then
        log("info", "[%s] No jitsi_meet_context_user in session — keeping client nick", bare_jid)
        return
    end

    local ok, ctx_json = pcall(json.encode, ctx)
    if ok then
        log("info", "[%s] JWT user context: %s", bare_jid, ctx_json)
    else
        log("info", "[%s] Failed to JSON-encode user context", bare_jid)
    end

    if not ctx.name or ctx.name == "" then
        log("info", "[%s] JWT does not contain a name — keeping client nick", bare_jid)
        return
    end
    local forced_nick = ctx.name
    log("info", "[%s] Forcing nick → '%s'", bare_jid, forced_nick)

    local nick_removed = false
    stanza:maptags(function(tag)
        if tag.name == "nick"
           and tag.attr.xmlns == "http://jabber.org/protocol/nick" then
            nick_removed = true
            return nil
        end
        return tag
    end)
    if nick_removed then
        log("info", "[%s] Removed nick element(s) supplied by client", bare_jid)
    else
        log("info", "[%s] No <nick> element from client — adding new", bare_jid)
    end

    stanza:tag("nick", { xmlns = "http://jabber.org/protocol/nick" })
          :text(forced_nick):up()

    log("info", "[%s] Nick finalised to '%s' for room %s", bare_jid, forced_nick, room.jid)
end

-- ранний, когда origin есть (обычные пользователи)
module:hook("muc-occupant-pre-join", on_pre_join, -10)

-- запасной, когда occupant уже создан (origin точно есть)
module:hook("muc-occupant-joined", function (event)
    on_pre_join{
        room     = event.room,
        occupant = event.occupant,
        origin   = event.occupant.origin,
        stanza   = event.stanza
    }
