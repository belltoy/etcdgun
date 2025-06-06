-module(etcdgun_interceptor_refresh_token).

-include_lib("kernel/include/logger.hrl").

-export([authenticate/4]).

%% TODO: This is an unary interceptor for authentication refresh.
%% streaming authentication refresh is not implemented yet.
authenticate(Stream, Req, Opts, Next) ->
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
                    %% Use the same stream to retry sending the request with the new token
                    ?LOG_DEBUG("Refreshing token and retrying request with new token"),
                    Metadata = maps:get(metadata, Opts, #{}),
                    Next(Stream, Req, Opts#{metadata => Metadata#{<<"token">> => NewToken}});
                {error, Reason1} ->
                    ?LOG_ERROR("Failed to refresh token with reason: ~p", [Reason1]),
                    Res;
                undefined ->
                    Res
            end;
        Other -> Other
    end.

refresh_token(Stream) ->
    Channel = egrpc_stream:channel(Stream),
    case egrpc_stub:info(Channel) of
        #{client := Client} -> etcdgun_client:refresh_token(Client);
        _ -> undefined
    end.
