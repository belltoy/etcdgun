-module(etcdgun_interceptor_auth).

-feature(maybe_expr, enable).

-include_lib("kernel/include/logger.hrl").

-export([authenticate/4]).

authenticate(Stream, Req, Opts, Next) ->
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
