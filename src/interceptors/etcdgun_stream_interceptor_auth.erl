-module(etcdgun_stream_interceptor_auth).

-feature(maybe_expr, enable).

-behaviour(egrpc_stream_interceptor).

-include_lib("kernel/include/logger.hrl").

-export([
    init_req/4
]).

% -define(USER_EMPTY,
%         <<"rpc error: code = InvalidArgument desc = etcdserver: user name is empty">>).
% -define(INVALID_TOKEN,
%         <<"rpc error: code = Unauthenticated desc = etcdserver: invalid auth token">>).
% -define(AUTH_STORE_OLD_REVISION,
%         <<"rpc error: code = InvalidArgument desc = etcdserver: revision of auth store is old">>).
% -define(PERMISSION_DENIED,
%         <<"rpc error: code = PermissionDenied desc = etcdserver: permission denied">>).

init_req(Stream, Opts, Next, State) ->
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
        {Next(Stream, Opts#{metadata => Metadata#{<<"token">> => Token}}), State}
    else
        _ -> {Next(Stream, Opts), State}
    end.

get_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{token := Token} -> {ok, Token};
        _ -> undefined
    end.
