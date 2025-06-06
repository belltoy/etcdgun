-module(etcdgun_stream_interceptor_auth).

-feature(maybe_expr, enable).

-behaviour(egrpc_stream_interceptor).

-include_lib("kernel/include/logger.hrl").

-export([
    init_request/4,
    send_msg/5,
    recv_msg/4,
    parse_msg/4
]).

-define(USER_EMPTY,
        <<"rpc error: code = InvalidArgument desc = etcdserver: user name is empty">>).
-define(INVALID_TOKEN,
        <<"rpc error: code = Unauthenticated desc = etcdserver: invalid auth token">>).
-define(AUTH_STORE_OLD_REVISION,
        <<"rpc error: code = InvalidArgument desc = etcdserver: revision of auth store is old">>).
-define(PERMISSION_DENIED,
        <<"rpc error: code = PermissionDenied desc = etcdserver: permission denied">>).

-define(WATCH_CREATE_REQ_CACHE, watch_create_req_cache).

init_request(Stream, Opts, Next, _State) ->
    Service = egrpc_stream:grpc_service(Stream),
    Method = egrpc_stream:grpc_method(Stream),
    ShouldAuth =
        case {Service, Method} of
            {'etcdserverpb.Watch', 'Watch'} -> true;
            {'etcdserverpb.Maintenance', 'Snapshot'} -> true;
            {'v3electionpb.Election', 'Observe'} -> true;
            _ -> false
        end,

    maybe
        true ?= ShouldAuth,
        {ok, Token} ?= get_token(Stream),
        Metadata = maps:get(metadata, Opts, #{}),
        ?LOG_DEBUG("Authenticating in the interceptor for RPC ~s.~s", [Service, Method]),
        Next(Stream, Opts#{metadata => Metadata#{<<"token">> => Token}})
    else
        _ -> Next(Stream, Opts)
    end.

send_msg(Stream, Req, IsFin, Next, _State) ->
    case is_watch_create(Stream, Req) of
        true ->
            Stream1 = req_cache_in(Stream, Req),
            Next(Stream1, Req, IsFin);
        false ->
            Next(Stream, Req, IsFin)
    end.

%% Maybe fresh token and retry Watch create request in recv_msg/4 and parse_msg/4.
%% But what if the request is not the first watch create request in the stream?
recv_msg(Stream, Acc, Next, _State) ->
    ?LOG_DEBUG("Receiving message, state: ~p~n", [_State]),
    Res = Next(Stream, Acc),
    maybe
        'etcdserverpb.Watch' ?= egrpc_stream:grpc_service(Stream),
        'Watch' ?= egrpc_stream:grpc_method(Stream),
        {ok, Stream1, Res1, Rest} ?= Res,
        true ?= is_watch_create_failed(Res1),
        true ?= should_refresh_token(Res1),
        {ok, CachedReq, Stream2} ?= req_cache_out(Stream1),
        {ok, Token} ?= refresh_token(Stream),
        ?LOG_DEBUG("Refreshing token: ~p~n", [Token]),
        %% TODO:
        %% Create a new stream with the new token and re-send the cached request.
        %% ONLY when the watch create request is the first one in the stream.
        Res
    else
        _ -> Res
    end.

parse_msg(Stream, Acc, Next, _State) ->
    Res = Next(Stream, Acc),
    % ?LOG_DEBUG("Parsed message: ~p", [Res]),
    Res.

get_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{token := Token} -> {ok, Token};
        _ -> undefined
    end.

is_watch_create(Stream, #{request_union := {create_request, _}} = _Req) ->
    GrpcService = egrpc_stream:grpc_service(Stream),
    GrpcMethod = egrpc_stream:grpc_method(Stream),
    {'etcdserverpb.Watch', 'Watch'} =:= {GrpcService, GrpcMethod};
is_watch_create(_Stream, _Req) ->
    false.

is_watch_create_failed(#{created := true, canceled := true}) -> true;
is_watch_create_failed(_) -> false.

refresh_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{client := Client} -> etcdgun_client:refresh_token(Client);
        _ -> {error, not_a_client}
    end.

should_refresh_token({ok, #{created := true, canceled := true, reason := ?USER_EMPTY}}) -> true;
should_refresh_token({ok, #{created := true, canceled := true, reason := ?INVALID_TOKEN}}) -> true;
should_refresh_token({ok, #{created := true, canceled := true, reason := ?AUTH_STORE_OLD_REVISION}}) -> true;
should_refresh_token({ok, #{created := true, canceled := true, reason := ?PERMISSION_DENIED}}) -> false;
should_refresh_token({ok, #{created := false, canceled := true, reason := _Reason}}) -> false;
should_refresh_token(_) -> false.

req_cache_out(Stream) ->
    maybe
        #{?WATCH_CREATE_REQ_CACHE := Q} ?= egrpc_stream:info(Stream, #{}),
        true ?= queue:is_queue(Q),
        {{value, Req}, Q1} ?= queue:out(Q),
        Stream1 = egrpc_stream:set_info(Stream, #{?WATCH_CREATE_REQ_CACHE => Q1}),
        {ok, Req, Stream1}
    else
        _ -> undefined
    end.

req_cache_in(Stream, Req) ->
    case egrpc_stream:info(Stream, #{}) of
        #{?WATCH_CREATE_REQ_CACHE := Q} ->
            Q1 = queue:in(Req, Q),
            egrpc_stream:set_info(Stream, #{?WATCH_CREATE_REQ_CACHE => Q1});
        _ ->
            egrpc_stream:set_info(Stream, #{?WATCH_CREATE_REQ_CACHE => queue:in(Req, queue:new())})
    end.
