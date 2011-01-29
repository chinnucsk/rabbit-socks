-module(rabbit_socks_socketio).

%% Protocol
-export([init/3, handle_frame/2, terminate/1]).

%% Writer
-export([send_frame/2]).

%% Debugging/test
-export([wrap_frame/1, unwrap_frames/1]).

-define(FRAME, "~m~").
-define(GUID_PREFIX, "rabbitmq-").

-record(state, {framing, protocol_state, protocol, session}).

init(Framing, Writer, {Session, BackingProtocol}) ->
    {ok, ProtocolState} = BackingProtocol:init(rabbit_socks_socketio, {Framing, Writer}),
    send_frame({utf8, Session}, {Framing, Writer}),
    {ok, #state{session = Session,
                framing = Framing,
                protocol_state = ProtocolState,
                protocol = BackingProtocol}}.

handle_frame({utf8, Bin},
             State = #state{protocol = Protocol,
                            protocol_state = ProtocolState}) ->
    ProtocolState1 = lists:foldl(
                       fun (Frame, PState) ->
                               {ok, PState1} =
                                   Protocol:handle_frame(Frame, PState),
                               PState1
                       end, ProtocolState, unwrap_frames(Bin)),
    {ok, State#state{ protocol_state = ProtocolState1}}.

terminate(#state{protocol = Protocol, protocol_state = PState}) ->
    Protocol:terminate(PState).

%% We can act as a frame serialiser by writing to an underlying framing ..
send_frame(Frame, {Underlying, Writer}) ->
    Wrapped = wrap_frame(Frame),
    Underlying:send_frame({utf8, Wrapped}, Writer).

unwrap_frames(Bin) when is_list(Bin) ->
    unwrap_frames(unicode:characters_to_binary(Bin, utf8));
unwrap_frames(Bin) ->
    unwrap_frames1(Bin, []).

unwrap_frames1(<<>>, Acc) ->
    lists:reverse(Acc);
unwrap_frames1(Bin, Acc) ->
    case Bin of
        <<?FRAME, Rest/binary>> ->
            {LenStr, Rest1} =
                rabbit_socks_util:binary_splitwith(
                  fun rabbit_socks_util:is_digit/1, Rest),
            Length = list_to_integer(binary_to_list(LenStr)),
            case Rest1 of
                <<?FRAME, Data:Length/binary, Rest2/binary>> ->
                    unwrap_frames1(Rest2, [{utf8, Data} | Acc]);
                _Else ->
                    {error, malformed_frame, Bin}
            end;
        _Else ->
            {error, malformed_frame, Bin}
    end.

wrap_frame({utf8, Bin}) ->
    case unicode:characters_to_list(Bin, utf8) of
        {error, _, _} ->
            {error, not_utf8_data, Bin};
        {incomplete, _, _} ->
            {error, incomplete_utf8_data, Bin};
        List ->
            LenStr = list_to_binary(integer_to_list(length(List))),
            [?FRAME, LenStr, ?FRAME, List]
    end.