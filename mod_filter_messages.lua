local util              = module:require 'util';
local get_room_from_jid = util.get_room_from_jid;
local st                = require 'util.stanza';
local serialization     = require 'util.serialization';

local function to_s(val)
    if type(val) == 'table' and serialization then
        return serialization.serialise(val);
    end
    return tostring(val);
end

local function on_message(event)
    local stanza  = event.stanza;
    local body    = stanza:get_child('body');
    local session = event.origin;

    -- Basic stanza information
    module:log('debug', 'stanza: %s', stanza:top_tag());
    module:log('debug', 'from=%s to=%s session.type=%s',
        stanza.attr.from, stanza.attr.to, session and session.type or 'nil');

    if body then
        module:log('debug', 'body="%s"', body:get_text());
    end

    if session and session.jitsi_meet_context_features then
        module:log('debug', 'context_features=%s',
            to_s(session.jitsi_meet_context_features));
    end

    if not body or not session then
        module:log('info', 'Skipping: no body or session');
        return;
    end

    -- Resolve room
    local room = get_room_from_jid(stanza.attr.to);
    if not room then
        module:log('warn', 'Room "%s" not found', stanza.attr.to);
        return;
    end
    
    local restricted = false;

  if room and room.jitsiMetadata and type(room.jitsiMetadata.permissions) == 'table' then
        restricted = room.jitsiMetadata.permissions.groupChatRestricted == true;
    end
  
  module:log('debug', 'room=%s groupChatRestricted=%s', room.jid, tostring(restricted));

    -- Permission check
    if restricted
        and not is_feature_allowed('send-groupchat',
            session.jitsi_meet_context_features) then

        module:log('info',
            'Blocking group message from %s to room %s (feature send-groupchat not allowed)',
            stanza.attr.from, room.jid);

        local reply = st.error_reply(stanza, 'cancel', 'not-allowed',
            'Sending group messages not allowed');
        if session.type == 's2sin' or session.type == 's2sout' then
            reply.skipMapping = true;
        end
        module:send(reply);

        return true; -- message filtered
    end

    module:log('debug', 'Message allowed');
end

module:hook('message/bare', on_message);                  -- room messages
module:hook('jitsi-visitor-groupchat-pre-route', on_message); -- visitor messages
