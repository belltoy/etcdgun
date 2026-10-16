%% @doc The authentication of etcd gRPC requests: the call credentials which add the token to
%% every attempt, and an interceptor which refreshes the token when it is refused and maps the
%% errors of the server to `etcd_error' (see `etcdgun_error').
%%
%% Both are installed by etcdgun on every client, they are not options.
-module(etcdgun_interceptor_auth).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").

-export([
    call_credentials/1,
    unary/3
]).

%% @doc The call credentials of etcdgun channels, see `m:egrpc_credentials'.
%%
%% It adds the token to every attempt of a unary call and to every stream.
call_credentials(#{service := Service, method := Path, info := Info}) ->
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
    case should_auth(Service, Path) andalso get_token(Info) of
        {ok, Token} ->
            ?LOG_DEBUG("Authenticating RPC ~s", [Path]),
            {ok, #{<<"token">> => Token}};
        _ ->
            {ok, #{}}
    end.

%% Whether the RPC gets the token: the services of etcd, except `Auth.Authenticate'.
should_auth(Service, Path) ->
    case {string:split(atom_to_list(Service), ".", all), Path} of
        {["etcdserverpb", "Auth"], <<"/etcdserverpb.Auth/Authenticate">>} -> false;
        {["etcdserverpb", _], _} -> true;
        {["v3electionpb", _], _} -> true;
        {["v3lockpb", _], _} -> true;
        {_, _} -> false
    end.

get_token(#{client := Client}) -> etcdgun_client:cached_token(Client);
get_token(_) -> undefined.

%% @doc The unary interceptor: a request which is refused for its token is made again once with a
%% new one (the credentials read it for the new attempts), and the errors of the server are
%% `{etcd_error, _}' when etcdgun knows them.
%%
%% The deadline of the call is shared by both runs of it, and the refresh is made once for the
%% requests which are refused at the same time, see `etcdgun_client:refresh_token/2'.
unary(Call, Req, Next) ->
    Stale = current_token(Call),
    case map_error(Next(Call, Req)) of
        {error, {etcd_error, Reason}} = Res when Reason =:= user_empty;
                                                 Reason =:= auth_old_revision;
                                                 Reason =:= invalid_auth_token ->
            case refresh_token(Call, Stale) of
                {ok, _} ->
                    ?LOG_DEBUG("Refreshed the token, retrying ~s", [egrpc_call:method(Call)]),
                    map_error(Next(Call, Req));
                {error, Reason1} ->
                    ?LOG_ERROR("Failed to refresh token with reason: ~p", [Reason1]),
                    Res
            end;
        Res ->
            Res
    end.

map_error({error, {grpc_error, _, _} = GrpcError}) -> {error, etcdgun_error:from_grpc_error(GrpcError)};
map_error(Res) -> Res.

%% The token the request is sent with, before it is: when it is refused and the current one is
%% not it anymore, the token was refreshed by someone else, and there is nothing to refresh.
current_token(Call) ->
    case egrpc_call:info(Call) of
        #{client := Client} ->
            case etcdgun_client:cached_token(Client) of
                {ok, Token} -> Token;
                undefined -> undefined
            end;
        _ -> undefined
    end.

refresh_token(Call, Stale) ->
    case egrpc_call:info(Call) of
        #{client := Client} -> etcdgun_client:refresh_token(Client, Stale);
        _ -> {error, not_a_client}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Which RPCs get the token. The Lease RPCs are in, `LeaseRevoke' checks the permissions of the
%% keys of the lease, and etcd 3.7 requires the token for all of them.
should_auth_test() ->
    Yes = [
        {'etcdserverpb.KV', <<"/etcdserverpb.KV/Range">>},
        {'etcdserverpb.KV', <<"/etcdserverpb.KV/Put">>},
        {'etcdserverpb.Watch', <<"/etcdserverpb.Watch/Watch">>},
        {'etcdserverpb.Lease', <<"/etcdserverpb.Lease/LeaseGrant">>},
        {'etcdserverpb.Lease', <<"/etcdserverpb.Lease/LeaseRevoke">>},
        {'etcdserverpb.Lease', <<"/etcdserverpb.Lease/LeaseKeepAlive">>},
        {'etcdserverpb.Lease', <<"/etcdserverpb.Lease/LeaseTimeToLive">>},
        {'etcdserverpb.Lease', <<"/etcdserverpb.Lease/LeaseLeases">>},
        {'etcdserverpb.Cluster', <<"/etcdserverpb.Cluster/MemberList">>},
        {'etcdserverpb.Maintenance', <<"/etcdserverpb.Maintenance/Status">>},
        {'etcdserverpb.Auth', <<"/etcdserverpb.Auth/UserAdd">>},
        {'v3electionpb.Election', <<"/v3electionpb.Election/Campaign">>},
        {'v3lockpb.Lock', <<"/v3lockpb.Lock/Lock">>}
    ],
    No = [
        {'etcdserverpb.Auth', <<"/etcdserverpb.Auth/Authenticate">>},
        {'grpc.health.v1.Health', <<"/grpc.health.v1.Health/Check">>},
        {'grpc.reflection.v1.ServerReflection', <<"/grpc.reflection.v1.ServerReflection/ServerReflectionInfo">>}
    ],
    [?assert(should_auth(S, M)) || {S, M} <- Yes],
    [?assertNot(should_auth(S, M)) || {S, M} <- No].
-endif.
