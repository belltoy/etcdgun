%% @doc A unary interceptor which logs each gRPC request of etcd: the service and method, the
%% request (the password redacted) and how long it took.
%%
%% Add `etcdgun_interceptor_log' to the `interceptors' option of the client, see `m:egrpc_interceptor'.
-module(etcdgun_interceptor_log).

-include_lib("kernel/include/logger.hrl").

-export([unary/3]).

unary(Call, Request, Next) ->
    ?LOG_DEBUG("Logging gRPC request for RPC ~s", [egrpc_call:method(Call)]),
    {Duration, Res} = timer:tc(Next, [Call, Request]),
    LogData = #{
        grpc_service => egrpc_call:service(Call),
        grpc_method => egrpc_call:method(Call),
        request => maps:map(fun
                                (password, _Value) -> "<redacted>";
                                (_Key, Value) -> Value
                            end, Request),
        duration => Duration div 1000 % Convert microseconds to milliseconds
    },
    case Res of
        {error, Reason} ->
            ?LOG_ERROR(LogData#{msg => "gRPC request failed", reason => Reason});
        _ ->
            ?LOG_INFO(LogData#{msg => "gRPC request successful"})
    end,
    Res.
