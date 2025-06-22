-module(etcdgun_interceptor_log).

-include_lib("kernel/include/logger.hrl").

-export([log/4]).

log(Stream, Request, Opts, Next) ->
    ?LOG_DEBUG("Logging gRPC request for RPC ~s.~s",
               [egrpc_stream:grpc_service(Stream), egrpc_stream:grpc_method(Stream)]),
    GrpcType = egrpc_stream:grpc_type(Stream),
    {Duration, Res} = timer:tc(Next, [Stream, Request, Opts]),
    LogData = #{
        grpc_type => GrpcType,
        grpc_service => egrpc_stream:grpc_service(Stream),
        grpc_method => egrpc_stream:grpc_method(Stream),
        request => maps:map(fun
                                (password, _Value) -> "<redacted>";
                                (_Key, Value) -> Value
                            end, Request),
        duration => Duration div 1000 % Convert microseconds to milliseconds
    },
    case Res of
        {ok, _} ->
            ?LOG_INFO(LogData#{msg => "gRPC request successful"});
        {error, Reason} ->
            ?LOG_ERROR(LogData#{msg => "gRPC request failed", reason => Reason})
    end,
    Res.
