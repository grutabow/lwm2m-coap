%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% socket pair, identified by a 2-tuple of local and remote socket addresses
% stores state for a given endpoint
-module(lwm2m_coap_channel).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).
-export([ping/1, send/2, send_request/3, send_message/3, send_response/3, close/1]).

-define(VERSION, 1).
-define(MAX_MESSAGE_ID, 65535). % 16-bit number

-record(state, {sock, chid, tokens, msgid_token, trans, nextmid, responder}).

-include("coap.hrl").

start_link(SockPid, ChId) ->
    gen_server:start_link(?MODULE, [SockPid, ChId], []).

ping(Channel) ->
    send_message(Channel, make_ref(), #coap_message{type=con}).

send(Channel, Message=#coap_message{type=Type, method=Method})
        when is_tuple(Method); Type==ack; Type==reset ->
    send_response(Channel, make_ref(), Message);
send(Channel, Message=#coap_message{}) ->
    send_request(Channel, make_ref(), Message).

send_request(Channel, Ref, Message) ->
    gen_server:cast(Channel, {send_request, Message, {self(), Ref}}),
    {ok, Ref}.
send_message(Channel, Ref, Message) ->
    gen_server:cast(Channel, {send_message, Message, {self(), Ref}}),
    {ok, Ref}.
send_response(Channel, Ref, Message) ->
    gen_server:cast(Channel, {send_response, Message, {self(), Ref}}),
    {ok, Ref}.

close(Pid) ->
    gen_server:cast(Pid, shutdown).

init([SockPid, ChId]) ->
    % we want to get called upon termination
    process_flag(trap_exit, true),
    _ = rand:seed(exs1024),
    Time = 80000 + rand:uniform(10000),
    erlang:send_after(Time, self(), {ping, ?PING, Time}),
    {ok, #state{sock=SockPid, chid=ChId, tokens=dict:new(),
        msgid_token=dict:new(),
        trans=dict:new(), nextmid=first_mid()}}.

handle_call(_Unknown, _From, State) ->
    {reply, unknown_call, State, hibernate}.

% outgoing CON(0) or NON(1) request
handle_cast({send_request, Message, Receiver}, State) ->
    transport_new_request(Message, Receiver, State);
% outgoing CON(0) or NON(1)
handle_cast({send_message, Message, Receiver}, State) ->
    transport_new_message(Message, Receiver, State);
% outgoing response, either CON(0) or NON(1), piggybacked ACK(2) or RST(3)
handle_cast({send_response, Message, Receiver}, State) ->
    transport_response(Message, Receiver, State);
handle_cast(shutdown, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    io:fwrite("coap_channel unknown cast ~p~n", [Request]),
    {noreply, State, hibernate}.

transport_new_request(Message = #coap_message{}, Receiver,
        State=#state{tokens=Tokens, msgid_token=MsgidToToken, nextmid=MsgId}) ->
    Token = crypto:strong_rand_bytes(4), % shall be at least 32 random bits
    Tokens2 = dict:store(Token, {sent, Receiver}, Tokens),
    MsgidToToken2 = dict:store(MsgId, Token, MsgidToToken),
    transport_new_message(Message#coap_message{token=Token}, Receiver,
        State#state{tokens=Tokens2, msgid_token=MsgidToToken2}).

transport_new_message(Message, Receiver, State=#state{nextmid=MsgId}) ->
    transport_message({out, MsgId}, Message#coap_message{id=MsgId}, Receiver, State#state{nextmid=next_mid(MsgId)}).

transport_message(TrId, Message, Receiver, State) ->
    update_state(State, TrId,
        lwm2m_coap_transport:send(Message, create_transport(TrId, Receiver, State))).

transport_response(Message=#coap_message{id=MsgId}, Receiver, State=#state{trans=Trans}) ->
    case dict:find({in, MsgId}, Trans) of
        {ok, TrState} ->
            case lwm2m_coap_transport:awaits_response(TrState) of
                true ->
                    update_state(State, {in, MsgId},
                        lwm2m_coap_transport:send(Message, TrState));
                false ->
                    transport_new_message(Message, Receiver, State)
            end;
        error ->
            transport_new_message(Message, Receiver, State)
    end.

% incoming CON(0) or NON(1) request
handle_info({datagram, BinMessage= <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, State = #state{sock=Sock, chid=ChId, responder = undefined}) ->
    case catch lwm2m_coap_message_parser:decode(BinMessage) of
        #coap_message{options=Options} ->
            Uri = proplists:get_value(uri_path, Options, []),
            case lwm2m_coap_responder:start_link(self(), Uri) of
                {ok, Re} ->
                    TrId = {in, MsgId},
                    State2 = State#state{responder = Re},
                    update_state(State2, TrId,
                        lwm2m_coap_transport:received(BinMessage, create_transport(TrId, undefined, State2)));
                {error, Error} ->
                    send_reset(Sock, ChId, MsgId,
                        {coap_responder_start_failed, Error}),
                    {noreply, State, hibernate}
            end;
        {error, _Error} ->
            {noreply, State, hibernate}
    end;
handle_info({datagram, BinMessage= <<?VERSION:2, 0:1, _:1, _TKL:4, 0:3, _CodeDetail:5, MsgId:16, _/bytes>>}, State) ->
    TrId = {in, MsgId},
    update_state(State, TrId,
        lwm2m_coap_transport:received(BinMessage, create_transport(TrId, undefined, State)));
% incoming CON(0) or NON(1) response
handle_info({datagram, BinMessage= <<?VERSION:2, 0:1, _:1, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
        State=#state{sock=Sock, chid=ChId, tokens=Tokens, trans=Trans}) ->
    TrId = {in, MsgId},
    case dict:find(TrId, Trans) of
        {ok, TrState} ->
            update_state(State, TrId, lwm2m_coap_transport:received(BinMessage, TrState));
        error ->
            case dict:find(Token, Tokens) of
                {ok, {acked, Receiver}} ->
                    update_state(State, TrId,
                        lwm2m_coap_transport:received(BinMessage, init_transport(TrId, Receiver, State)));
                Error ->
                    % token was not recognized
                    send_reset(Sock, ChId, MsgId, {token_not_found, Error}),
                    {noreply, State, hibernate}
            end
    end;

% incoming empty ACK(2) or RST(3)
handle_info({datagram, BinMessage= <<?VERSION:2, _T:2, 0:4, _Code:8, MsgId:16>>},
        State=#state{sock=Sock, chid=ChId, trans=Trans, tokens=Tokens, msgid_token=MsgidToToken}) ->
    case dict:find(MsgId, MsgidToToken) of
        error ->
            send_reset(Sock, ChId, MsgId, msgid_not_found),
            {noreply, State, hibernate};
        {ok, Token} ->
            {_, Receiver} = dict:fetch(Token, Tokens),
            Tokens2 = dict:store(Token, {acked, Receiver}, Tokens),
            TrId = {out, MsgId},
            update_state(State#state{tokens = Tokens2}, TrId,
                case dict:find(TrId, Trans) of
                    error -> undefined; % ignore unexpected responses
                    {ok, TrState} -> lwm2m_coap_transport:received(BinMessage, TrState)
                end)
    end;

% incoming piggybacked ACK(2) to a request or response
handle_info({datagram, BinMessage= <<?VERSION:2, _T:2, TKL:4, _Code:8, MsgId:16, Token:TKL/bytes, _/bytes>>},
        State=#state{sock=Sock, chid=ChId, trans=Trans, tokens=Tokens}) ->
    TrId = {out, MsgId},
    case dict:find(Token, Tokens) of
        {ok, {sent, Receiver}} ->
            Tokens2 = dict:store(Token, {acked, Receiver}, Tokens),
            update_state(State#state{tokens = Tokens2}, TrId,
                case dict:find(TrId, Trans) of
                    error -> undefined; % ignore unexpected responses
                    {ok, TrState} -> lwm2m_coap_transport:received(BinMessage, TrState)
                end);
        {ok, {acked, _Receiver}} ->
            {noreply, State, hibernate};
        _Error ->
            send_reset(Sock, ChId, MsgId, {msgid_not_found, _Error}),
            {noreply, State, hibernate}
    end;

% silently ignore other versions
handle_info({datagram, <<Ver:2, _/bytes>>}, State) when Ver /= ?VERSION ->
    {noreply, State, hibernate};
handle_info({timeout, TrId, Event}, State=#state{trans=Trans}) ->
    update_state(State, TrId,
        case dict:find(TrId, Trans) of
            error -> undefined; % ignore unexpected responses
            {ok, TrState} -> lwm2m_coap_transport:timeout(Event, TrState)
        end);
handle_info({request_complete, #coap_message{token=Token, id=Id}},
        State=#state{tokens=Tokens, msgid_token=MsgidToToken}) ->
    Tokens2 = dict:erase(Token, Tokens),
    MsgidToToken2 = dict:erase(Id, MsgidToToken),
    {noreply, State#state{tokens=Tokens2, msgid_token=MsgidToToken2}, hibernate};

handle_info({'EXIT', Resp, Reason}, State = #state{responder = Resp}) ->
    error_logger:info_msg("channel received exit from responder: ~p, reason: ~p", [Resp, Reason]),
    {stop, Reason, State};
handle_info({'EXIT', _Pid, _Reason}, State = #state{}) ->
    error_logger:error_msg("channel received exit from stranger: ~p, reason: ~p", [_Pid, _Reason]),
    {noreply, State, hibernate};

handle_info({ping, Data, Time}, State = #state{sock=SockPid, chid=ChId}) ->
    erlang:send_after(Time, self(), {ping, ?PING, Time}),
    SockPid ! {ping, ChId, Data},
    {noreply, State, hibernate};

handle_info(Info, State) ->
    io:fwrite("unexpected massage ~p~n", [Info]),
    {noreply, State, hibernate}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, #state{sock=SockPid, chid=ChId}) ->
    error_logger:info_msg("channel ~p finished, reason: ~p", [ChId, normal]),
    SockPid ! {terminated, ChId},
    ok;
terminate(Reason, #state{sock=SockPid, chid=ChId}) ->
    error_logger:info_msg("channel ~p finished, reason: ~p", [ChId, Reason]),
    SockPid ! {terminated, ChId},
    ok.

send_reset(Sock, ChId, MsgId, ErrorMsg) ->
    error_logger:error_msg("<- reset, error: ~p", [ErrorMsg]),
    Sock ! {datagram, ChId,
        lwm2m_coap_message_parser:encode(#coap_message{type=reset, id=MsgId})}.

first_mid() ->
    _ = rand:seed(exs1024),
    rand:uniform(?MAX_MESSAGE_ID).

next_mid(MsgId) ->
    if
        MsgId < ?MAX_MESSAGE_ID -> MsgId + 1;
        true -> 1 % or 0?
    end.

create_transport(TrId, Receiver, State=#state{trans=Trans}) ->
    case dict:find(TrId, Trans) of
        {ok, TrState} -> TrState;
        error -> init_transport(TrId, Receiver, State)
    end.

init_transport(TrId, undefined, #state{sock=Sock, chid=ChId, responder=ReSup}) ->
    lwm2m_coap_transport:init(Sock, ChId, self(), TrId, ReSup, undefined);
init_transport(TrId, Receiver, #state{sock=Sock, chid=ChId}) ->
    lwm2m_coap_transport:init(Sock, ChId, self(), TrId, undefined, Receiver).

update_state(State=#state{trans=Trans}, _TrId, undefined) ->
    {noreply, State#state{trans=Trans}, hibernate};
update_state(State=#state{trans=Trans}, TrId, TrState) ->
    Trans2 = dict:store(TrId, TrState, Trans),
    {noreply, State#state{trans=Trans2}, hibernate}.
