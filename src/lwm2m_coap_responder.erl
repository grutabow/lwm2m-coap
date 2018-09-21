%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% request handler
% provides caching for atomic multi-block operations
% provides synchronous callbacks that block until a response is ready
-module(lwm2m_coap_responder).
-behaviour(gen_server).

-include("coap.hrl").

-export([start_link/2, stop/1, stop/2, notify/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-record(state, {channel, prefix, module, args, insegs, last_response, observer, obseq, lwm2m_state, timer}).

-define(EXCHANGE_LIFETIME, 247000).

start_link(Channel, Uri) ->
    gen_server:start_link(?MODULE, [Channel, Uri], []).

stop(Reason) ->
    stop(self(), Reason).
stop(Pid, Reason) ->
    gen_server:cast(Pid, {stop, Reason}).

notify(Uri, Resource) ->
    case pg2:get_members({coap_observer, Uri}) of
        {error, _} -> ok;
        List -> [gen_server:cast(Pid, Resource) || Pid <- List]
    end.

init([Channel, Uri]) ->
    % the receiver will be determined based on the URI
    process_flag(trap_exit, true),
    case lwm2m_coap_server_registry:get_handler(Uri) of
        {Prefix, Module, Args} ->
            {ok, #state{channel=Channel, prefix=Prefix, module=Module, args=Args,
                insegs=orddict:new(), obseq=0}};
        undefined ->
            {stop, {resource_handler_not_found, Uri}}
    end.

handle_call(Msg, From, State) ->
    invoke_system_callbacks(handle_call, [Msg, From], State).

handle_cast({stop, Reason}, State=#state{observer=Observer}) ->
    NewState =
        case Observer of
            undefined ->
                State;
            Observer ->
                {ok, State2} = cancel_observer(Observer, State),
                State2
        end,
    {stop, {shutdown, Reason}, NewState};

handle_cast(Resource=#coap_content{}, State=#state{observer=Observer}) ->
    case Observer of
        undefined ->
            {noreply, State, hibernate};
        Observer ->
            return_resource(Observer, Resource, State)
    end;
handle_cast({error, Code}, State=#state{observer=Observer}) ->
    {ok, State2} = cancel_observer(Observer, State),
    return_response(Observer, {error, Code}, State2);

handle_cast(Msg, State) ->
    invoke_system_callbacks(handle_cast, [Msg], State).

handle_info({coap_request, ChId, _Channel, undefined, Request}, State) ->
    %io:fwrite("-> ~p~n", [Request]),
    handle(ChId, Request, State);
handle_info(cache_expired, State=#state{observer=undefined}) ->
    {stop, normal, State};
handle_info(cache_expired, State) ->
    % multi-block cache expired, but the observer is still active
    {noreply, State, hibernate};

handle_info({coap_ack, ChId, _Channel, Ref},
        State=#state{module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    case invoke_callback(Module, coap_ack, [ChId, Ref], Lwm2mState, Args) of
        {ok, Lwm2mState2} ->
            {noreply, State#state{lwm2m_state=Lwm2mState2}, hibernate}
    end;

handle_info({coap_response, ChId, _Channel, Ref, #coap_message{
                type = Type, method = Method, payload = Payload, options = Opts
             }}, State=#state{
                module=Module, observer=Observer, lwm2m_state=Lwm2mState, channel = Channel, args=Args
             }) ->
    CallbackArgs = [ChId, Ref, Type, Method, Payload, Opts],
    case invoke_callback(Module, coap_response, CallbackArgs, Lwm2mState, Args) of
         {send_request, Request, Ref3, Lwm2mState2} ->
             send_request(Channel, Ref3, Request),
             {noreply, State#state{lwm2m_state=Lwm2mState2}, hibernate};
         {noreply, Lwm2mState2} ->
             {noreply, State#state{lwm2m_state=Lwm2mState2}, hibernate};
         {error, Code, Lwm2mState2} ->
             {ok, State2} = cancel_observer(Observer, State#state{lwm2m_state=Lwm2mState2}),
             return_response(Observer, {error, Code}, State2)
    end;

handle_info(Info, State) ->
    invoke_system_callbacks(handle_info, [Info], State).

terminate(Reason, State) ->
    invoke_system_callbacks(terminate, [Reason], State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


% handlers

handle(ChId, Request=#coap_message{options=Options}, State=#state{channel=Channel}) ->
    Block1 = proplists:get_value(block1, Options),
    case assemble_payload(Request, Block1, State) of
        {error, Code} ->
            return_response(Request, {error, Code}, State);
        {continue, State2} ->
            {ok, _} = lwm2m_coap_channel:send_response(Channel, [],
                lwm2m_coap_message:set(block1, Block1,
                    lwm2m_coap_message:response({ok, continue}, Request))),
            set_timeout(?EXCHANGE_LIFETIME, State2);
        {ok, Payload, State2} ->
            process_request(ChId, Request#coap_message{payload=Payload}, State2)
    end.

assemble_payload(#coap_message{payload=Payload}, undefined, State) ->
    {ok, Payload, State};
assemble_payload(#coap_message{payload=Segment}, {Num, true, Size}, State=#state{insegs=Segs}) ->
    case byte_size(Segment) of
        Size -> {continue, State#state{insegs=orddict:store(Num, Segment, Segs)}};
        _Else -> {error, bad_request}
    end;
assemble_payload(#coap_message{payload=Segment}, {_Num, false, _Size}, State=#state{insegs=Segs}) ->
    Payload = lists:foldl(
        fun ({Num1, Segment1}, Acc) when Num1*byte_size(Segment1) == byte_size(Acc) ->
                <<Acc/binary, Segment1/binary>>;
            (_Else, _Acc) ->
                throw({error, request_entity_incomplete})
        end, <<>>, orddict:to_list(Segs)),
    {ok, <<Payload/binary, Segment/binary>>, State#state{insegs=orddict:new()}}.

process_request(ChId, Request=#coap_message{options=Options},
        State=#state{last_response={ok, Code, Content}}) ->
    case proplists:get_value(block2, Options) of
        {N, _, _} when N > 0 ->
            return_resource([], Request, {ok, Code}, Content, State);
        _Else ->
            check_resource(ChId, Request, State)
    end;
process_request(ChId, Request, State) ->
    check_resource(ChId, Request, State).

check_resource(ChId, Request, State=#state{prefix=Prefix, module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    Content = lwm2m_coap_message:get_content(Request),
    case invoke_callback(Module, coap_get, [ChId, Prefix, uri_query(Request), Content], Lwm2mState, Args) of
        {ok, Response = #coap_content{}, Lwm2mState2} ->
            check_preconditions(ChId, Request, Response, State#state{lwm2m_state=Lwm2mState2});
        {error, not_found, Lwm2mState2} ->
            check_preconditions(ChId, Request, {error, not_found}, State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Lwm2mState2} ->
            return_response(Request, {error, Code}, State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Reason, Lwm2mState2} ->
            return_response([], Request, {error, Code}, Reason, State#state{lwm2m_state=Lwm2mState2})
    end.

check_preconditions(ChId, Request, Resource, State) ->
    case if_match(Request, Resource) and if_none_match(Request, Resource) of
        true ->
            handle_method(ChId, Request, Resource, State);
        false ->
            return_response(Request, {error, precondition_failed}, State)
    end.

if_match(#coap_message{options=Options}, #coap_content{etag=ETag}) ->
    case proplists:get_value(if_match, Options, []) of
        % empty string matches any existing representation
        [] -> true;
        % match exact resources
        List -> lists:member(ETag, List)
    end;
if_match(#coap_message{options=Options}, {error, not_found}) ->
    not proplists:is_defined(if_match, Options).

if_none_match(#coap_message{options=Options}, #coap_content{}) ->
    not proplists:is_defined(if_none_match, Options);
if_none_match(#coap_message{}, {error, _}) ->
    true.

handle_method(ChId, Request=#coap_message{method='get', options=Options}, Resource=#coap_content{}, State) ->
    case proplists:get_value(observe, Options) of
        0 ->
            handle_observe(ChId, Request, Resource, State);
        1 ->
            handle_unobserve(ChId, Request, Resource, State);
        undefined ->
            return_resource(Request, Resource, State);
        _Else ->
            return_response(Request, {error, bad_option}, State)
    end;
handle_method(_ChId, Request=#coap_message{method='get'}, {error, Code}, State) ->
    return_response(Request, {error, Code}, State);
handle_method(ChId, Request=#coap_message{method='post'}, _Resource, State) ->
    handle_post(ChId, Request, State);
handle_method(ChId, Request=#coap_message{method='put'}, Resource, State) ->
    handle_put(ChId, Request, Resource, State);
handle_method(ChId, Request=#coap_message{method='delete'}, _Resource, State) ->
    handle_delete(ChId, Request, State);
handle_method(_ChId, Request, _Resource, State) ->
    return_response(Request, {error, method_not_allowed}, State).

handle_observe(ChId, Request=#coap_message{options=Options}, Content=#coap_content{},
        State=#state{prefix=Prefix, module=Module, observer=undefined, lwm2m_state=Lwm2mState, args=Args}) ->
    % the first observe request from this user to this resource
    Content = lwm2m_coap_message:get_content(Request),
    case invoke_callback(Module, coap_observe, [ChId, Prefix, requires_ack(Request), Content], Lwm2mState, Args) of
        {ok, Lwm2mState2} ->
            Uri = proplists:get_value(uri_path, Options, []),
            pg2:create({coap_observer, Uri}),
            ok = pg2:join({coap_observer, Uri}, self()),
            return_resource(Request, Content, State#state{observer=Request, lwm2m_state=Lwm2mState2});
        {error, method_not_allowed, Lwm2mState2} ->
            % observe is not supported, fallback to standard get
            return_resource(Request, Content, State#state{observer=undefined, lwm2m_state=Lwm2mState2});
        {error, Error, Lwm2mState2} ->
            return_response(Request, {error, Error}, State#state{lwm2m_state=Lwm2mState2});
        {error, Error, Reason, Lwm2mState2} ->
            return_response([], Request, {error, Error}, Reason, State#state{lwm2m_state=Lwm2mState2})
    end;
handle_observe(_ChId, Request, Content, State) ->
    % subsequent observe request from the same user
    return_resource(Request, Content, State#state{observer=Request}).

requires_ack(#coap_message{type=con}) -> true;
requires_ack(#coap_message{type=non}) -> false.

handle_unobserve(_ChId, Request, Resource, State) ->
    {ok, State2} = cancel_observer(Request, State),
    return_resource(Request, Resource, State2).

cancel_observer(undefined, _State) ->
    {ok, _State};
cancel_observer(#coap_message{options=Options}, State=#state{module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    {ok, Lwm2mState2} = invoke_callback(Module, coap_unobserve, [], Lwm2mState, Args),
    Uri = proplists:get_value(uri_path, Options, []),
    ok = pg2:leave({coap_observer, Uri}, self()),
    % will the last observer to leave this group please turn out the lights
    case pg2:get_members({coap_observer, Uri}) of
        [] -> pg2:delete({coap_observer, Uri});
        _Else -> ok
    end,
    {ok, State#state{observer=undefined, lwm2m_state=Lwm2mState2}}.

handle_post(ChId, Request, State=#state{prefix=Prefix, module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    Content = lwm2m_coap_message:get_content(Request),
    case invoke_callback(Module, coap_post, [ChId, Prefix, uri_query(Request), Content], Lwm2mState, Args) of
        {ok, Code, Content2, Lwm2mState2} ->
            return_resource([], Request, {ok, Code}, Content2, State#state{lwm2m_state=Lwm2mState2});
        {error, Error, Lwm2mState2} ->
            return_response(Request, {error, Error}, State#state{lwm2m_state=Lwm2mState2});
        {error, Error, Reason, Lwm2mState2} ->
            return_response([], Request, {error, Error}, Reason, State#state{lwm2m_state=Lwm2mState2})
    end.

handle_put(ChId, Request, Resource, State=#state{prefix=Prefix, module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    Content = lwm2m_coap_message:get_content(Request),
    case invoke_callback(Module, coap_put, [ChId, Prefix, uri_query(Request), Content], Lwm2mState, Args) of
        {ok, Lwm2mState2} ->
            return_response(Request, created_or_changed(Resource), State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Lwm2mState2} ->
            return_response(Request, {error, Code}, State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Reason, Lwm2mState2} ->
            return_response([], Request, {error, Code}, Reason, State#state{lwm2m_state=Lwm2mState2})
    end.

handle_delete(ChId, Request, State=#state{prefix=Prefix, module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    Content = lwm2m_coap_message:get_content(Request),
    case invoke_callback(Module, coap_delete, [ChId, Prefix, Content], Lwm2mState, Args) of
        {ok, Lwm2mState2} ->
            return_response(Request, {ok, deleted}, State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Lwm2mState2} ->
            return_response(Request, {error, Code}, State#state{lwm2m_state=Lwm2mState2});
        {error, Code, Reason, Lwm2mState2} ->
            return_response([], Request, {error, Code}, Reason, State#state{lwm2m_state=Lwm2mState2})
    end.

invoke_system_callbacks(terminate, CallbackArgs, #state{module=Module, lwm2m_state=Lwm2mState, args=Args}) ->
    invoke_callback(Module, terminate, CallbackArgs, Lwm2mState, Args);

invoke_system_callbacks(CallbackFunName, CallbackArgs, State=#state{
        module=Module, observer=Observer, lwm2m_state=Lwm2mState,
        channel = Channel, args=Args}) ->
    case invoke_callback(Module, CallbackFunName, CallbackArgs, Lwm2mState, Args) of
        {send_request, Request, Ref3, Lwm2mState2} ->
            send_request(Channel, Ref3, Request),
            {noreply, State#state{lwm2m_state=Lwm2mState2}, hibernate};
        {reply, Response, Lwm2mState2} ->
            {reply, Response, State#state{lwm2m_state=Lwm2mState2}, hibernate};
        {noreply, Lwm2mState2} ->
            {noreply, State#state{lwm2m_state=Lwm2mState2}, hibernate};
        {stop, Reason, Lwm2mState2} ->
            {stop, {shutdown, Reason}, State#state{lwm2m_state=Lwm2mState2}};
        {error, Code, Lwm2mState2} ->
            {ok, State2} = cancel_observer(Observer, State#state{lwm2m_state=Lwm2mState2}),
            return_response(Observer, {error, Code}, State2)
    end.

invoke_callback(Module, Fun, CallbackArgs, Lwm2mState, undefined) ->
    do_invoke_callback(Module, Fun, CallbackArgs, Lwm2mState);
invoke_callback(Module, Fun, CallbackArgs, Lwm2mState, HandlerArgs) ->
    do_invoke_callback(Module, Fun, CallbackArgs ++ HandlerArgs, Lwm2mState).

do_invoke_callback(Module, Fun, Args, Lwm2mState) ->
    case catch apply(Module, Fun, Args ++ [Lwm2mState]) of
        {'EXIT', Error} ->
            error_logger:error_msg("~p", [Error]),
            {error, internal_server_error, Lwm2mState};
        Response ->
            Response
    end.

return_resource(Request, Content, State) ->
    return_resource([], Request, {ok, content}, Content, State).

return_resource(Ref, Request=#coap_message{options=Options}, {ok, Code}, Content=#coap_content{etag=ETag}, State) ->
    send_observable(Ref, Request,
        case lists:member(ETag, proplists:get_value(etag, Options, [])) of
            true ->
                lwm2m_coap_message:set_content(#coap_content{etag=ETag},
                    lwm2m_coap_message:response({ok, valid}, Request));
            false ->
                lwm2m_coap_message:set_content(Content,
                    proplists:get_value(block2, Options),
                        lwm2m_coap_message:response({ok, Code}, Request))
        end, State#state{last_response={ok, Code, Content}}).

return_response(Request, Code, State) ->
    return_response([], Request, Code, <<>>, State).

return_response(Ref, Request, Code, Reason, State) ->
    send_response(Ref, lwm2m_coap_message:response(Code, Reason, Request), State#state{last_response=Code}).

send_observable(Ref, #coap_message{token=Token, options=Options}, Response,
        State=#state{observer=Observer, obseq=Seq}) ->
    case {proplists:get_value(observe, Options), Observer} of
        % when requested observe and is observing, return the sequence number
        {0, #coap_message{token=Token}} ->
            send_response(Ref, lwm2m_coap_message:set(observe, Seq, Response), State#state{obseq=next_seq(Seq)});
        _Else ->
            send_response(Ref, Response, State)
    end.

send_response(Ref, Response=#coap_message{options=Options},
        State=#state{channel=Channel, observer=Observer}) ->
    %io:fwrite("<- ~p~n", [Response]),
    {ok, _} = lwm2m_coap_channel:send_response(Channel, Ref, Response),
    case Observer of
        #coap_message{} ->
            % notifications will follow
            {noreply, State, hibernate};
        undefined ->
            case proplists:get_value(block2, Options) of
                {_, true, _} ->
                    % client is expected to ask for more blocks
                    set_timeout(?EXCHANGE_LIFETIME, State);
                _Else ->
                    % no further communication concerning this request
                    {noreply, State, hibernate}
            end
    end.

send_request(Channel, Ref, Request) ->
    lwm2m_coap_channel:send_request(Channel, Ref, Request).

uri_query(#coap_message{options=Options}) ->
    proplists:get_value(uri_query, Options, []).

next_seq(Seq) ->
    if
        Seq < 16#0FFF -> Seq+1;
        true -> 0
    end.

set_timeout(Timeout, State=#state{timer=undefined}) ->
    set_timeout0(State, Timeout);
set_timeout(Timeout, State=#state{timer=Timer}) ->
    _ = erlang:cancel_timer(Timer),
    set_timeout0(State, Timeout).

set_timeout0(State, Timeout) ->
    Timer = erlang:send_after(Timeout, self(), cache_expired),
    {noreply, State#state{timer=Timer}, hibernate}.

created_or_changed(#coap_content{}) ->
    {ok, changed};
created_or_changed({error, not_found}) ->
    {ok, created}.

% end of file
