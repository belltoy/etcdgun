-module(etcdgun_interceptor_auth).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").

-export([
    authenticate/4,
    refresh_token/4
]).

authenticate(Stream, Req, Opts, Next) ->
    ?LOG_DEBUG("Authentication interceptor for RPC ~s.~s",
               [egrpc_stream:grpc_service(Stream), egrpc_stream:grpc_method(Stream)]),
    Service = atom_to_list(egrpc_stream:grpc_service(Stream)),
    Method = egrpc_stream:grpc_method(Stream),
    ShouldAuth =
        case {string:split(Service, ".", all), Method} of
                {["etcdserverpb", "Cluster"], 'MemberList'} -> false;
                {["etcdserverpb", "Auth"], 'Authenticate'} -> false;
                {["etcdserverpb", "Lease"], _} -> false;
                {["etcdserverpb", _], _} -> true;
                {["v3electionpb", _], _} -> true;
                {["v3lockpb", _], _} -> true;
                {_, _} -> false
            end,
    maybe
        true ?= ShouldAuth,
        {ok, Token} ?= get_token(Stream),
        Metadata = maps:get(metadata, Opts, #{}),
        ?LOG_DEBUG("Authenticating in the interceptor for RPC ~s.~s", [Service, Method]),
        Next(Stream, Req, Opts#{metadata => Metadata#{<<"token">> => Token}})
    else
        _ -> Next(Stream, Req, Opts)
    end.

get_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{token := Token} -> {ok, Token};
        _ -> undefined
    end.

%% TODO: This is an unary interceptor for authentication refresh.
%% streaming authentication refresh is not implemented yet.
refresh_token(Stream, Req, Opts, Next) ->
    ?LOG_DEBUG("Refresh token interceptor for RPC ~s.~s",
              [egrpc_stream:grpc_service(Stream), egrpc_stream:grpc_method(Stream)]),
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
            case refresh_token(Stream) of
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

refresh_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{client := Client} when is_atom(Client) -> etcdgun_client:refresh_token(Client);
        _ -> {error, not_a_client}
    end.
