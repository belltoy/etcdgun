%% @doc This module handles authentication for etcd gRPC requests: the call credentials which add
%% the token to the requests, and an interceptor which refreshes the token when it expires.
%%
%% See `call_credentials/1' and `refresh_token/4' functions for implementation details.
%%
%% See also `t:egrpc_stub:unary_interceptor/0' for the type of gRPC unary interceptor.
-module(etcdgun_interceptor_auth).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").

-export([
    call_credentials/1,
    refresh_token/4
]).

%% @doc The call credentials of etcdgun channels, see `t:egrpc_stub:call_credentials/0'.
%%
%% It adds the token to every call, streaming calls included.
call_credentials(Stream) ->
    Service = egrpc_stream:grpc_service(Stream),
    Method = egrpc_stream:grpc_method(Stream),
    %% Which RPCs require the token when authentication is enabled depends on the etcd version.
    %% Without a token, the RPC fails with "etcdserver: user name is empty" where `token' is shown
    %% (checked against etcd 3.5.10, 3.6.5 and 3.7.0):
    %%
    %%   RPC                              3.5     3.6     3.7
    %%   KV.Range                         token   token   token
    %%   Maintenance.Status               -       token   token
    %%   Cluster.MemberList               -       -       token
    %%   Lease.* (with LeaseKeepAlive)    -       -       token
    %%
    %% The token is always accepted, even by the RPCs which do not require it, so it is sent to all
    %% of them except `Auth.Authenticate', which is how the token is obtained. When there is no
    %% token yet, e.g. the authentication is not enabled, nothing is sent.
    case should_auth(Service, Method) andalso get_token(Stream) of
        {ok, Token} ->
            ?LOG_DEBUG("Authenticating RPC ~s.~s", [Service, Method]),
            {ok, #{<<"token">> => Token}};
        _ ->
            {ok, #{}}
    end.

%% Whether the RPC gets the token: the services of etcd, except `Auth.Authenticate'.
should_auth(Service, Method) ->
    case {string:split(atom_to_list(Service), ".", all), Method} of
        {["etcdserverpb", "Auth"], 'Authenticate'} -> false;
        {["etcdserverpb", _], _} -> true;
        {["v3electionpb", _], _} -> true;
        {["v3lockpb", _], _} -> true;
        {_, _} -> false
    end.

%% The token of the channel info is for the channels which are not opened by a client yet, e.g.
%% while bootstrapping, otherwise the current one of the client.
get_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{token := Token} -> {ok, Token};
        #{client := Client} -> etcdgun_client:cached_token(Client);
        _ -> undefined
    end.

%% TODO: This is an unary interceptor for authentication refresh.
%% streaming authentication refresh is not implemented yet.
refresh_token(Stream, Req, Opts, Next) ->
    ?LOG_DEBUG("Refresh token interceptor for RPC ~s.~s",
              [egrpc_stream:grpc_service(Stream), egrpc_stream:grpc_method(Stream)]),
    %% The token the request is sent with, before it is: when it is refused and the current one is
    %% not it anymore, the token was refreshed by someone else, and there is nothing to refresh.
    Stale = stale_token(Stream),
    Res = case Next(Stream, Req, Opts) of
              {ok, _} = Ok -> Ok;
              {error, {grpc_error, _, _} = GrpcError} ->
                  {error, etcdgun_error:from_grpc_error(GrpcError)};
              {error, _} = Err -> Err
          end,

    case Res of
        {error, {etcd_error, Reason}} when Reason =:= user_empty;
                                           Reason =:= auth_old_revision;
                                           Reason =:= invalid_auth_token ->
            case refresh_token(Stream, Stale) of
                {ok, NewToken} ->
                    %% Use the same stream (not http2 stream) to retry sending the request with
                    %% the new token
                    ?LOG_DEBUG("Refreshing token and retrying request with new token"),
                    Metadata = maps:get(metadata, Opts, #{}),
                    Next(Stream, Req, Opts#{metadata => Metadata#{<<"token">> => NewToken}});
                {error, Reason1} ->
                    ?LOG_ERROR("Failed to refresh token with reason: ~p", [Reason1]),
                    Res
            end;
        Other -> Other
    end.

stale_token(Stream) ->
    case egrpc_stub:info(egrpc_stream:channel(Stream)) of
        #{client := Client} when is_atom(Client) ->
            case etcdgun_client:cached_token(Client) of
                {ok, Token} -> Token;
                undefined -> undefined
            end;
        _ -> undefined
    end.

refresh_token(Stream, Stale) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{client := Client} when is_atom(Client) -> etcdgun_client:refresh_token(Client, Stale);
        _ -> {error, not_a_client}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Which RPCs get the token. The Lease RPCs are in, `LeaseRevoke' checks the permissions of the
%% keys of the lease, and etcd 3.7 requires the token for all of them.
should_auth_test() ->
    Yes = [
        {'etcdserverpb.KV', 'Range'},
        {'etcdserverpb.KV', 'Put'},
        {'etcdserverpb.Watch', 'Watch'},
        {'etcdserverpb.Lease', 'LeaseGrant'},
        {'etcdserverpb.Lease', 'LeaseRevoke'},
        {'etcdserverpb.Lease', 'LeaseKeepAlive'},
        {'etcdserverpb.Lease', 'LeaseTimeToLive'},
        {'etcdserverpb.Lease', 'LeaseLeases'},
        {'etcdserverpb.Cluster', 'MemberList'},
        {'etcdserverpb.Maintenance', 'Status'},
        {'etcdserverpb.Auth', 'UserAdd'},
        {'v3electionpb.Election', 'Campaign'},
        {'v3lockpb.Lock', 'Lock'}
    ],
    No = [
        {'etcdserverpb.Auth', 'Authenticate'},
        {'grpc.health.v1.Health', 'Check'},
        {'grpc.reflection.v1.ServerReflection', 'ServerReflectionInfo'}
    ],
    [?assert(should_auth(S, M)) || {S, M} <- Yes],
    [?assertNot(should_auth(S, M)) || {S, M} <- No].
-endif.
