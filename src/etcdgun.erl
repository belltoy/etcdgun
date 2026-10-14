-module(etcdgun).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    clients/0,
    open/2,
    open/3,
    close/1,
    watch/5,
    cancel_watch/2,
    prefix_range_end/1
]).

-export_type([
    client/0,
    endpoint/0,
    opts/0
]).

-type client() :: atom().
-type endpoint() :: {Host :: string(), Port :: inet:port_number()}.
-type opts() :: #{
      %% A binary or a string, neither is empty, otherwise `{error, invalid_cred}'.
      cred => {Username :: binary() | string(), Password :: binary() | string()},
      %% The transport of the `Endpoints' to connect to, `tcp' by default. The transport of the
      %% members of the cluster is the scheme of their client URLs, `http' or `https'.
      transport => tcp | tls,
      %% The options of gun for every connection, e.g. `#{tls_opts => [{cacertfile, "ca.pem"}]}'
      %% for `https'. The `transport' is set by etcdgun.
      gun_opts => gun:opts(),
      %% How often to check the members of the cluster, in milliseconds, 5 minutes by default.
      %% `0' and `infinity' disable the check.
      membership_check_interval => non_neg_integer() | infinity,
      %% The egrpc interceptors of every channel, the authentication is not one of them.
      interceptors => [egrpc_interceptor:spec()]
}.

%% @doc The information of the clients which are running.
clients() ->
    Children = supervisor:which_children(etcdgun_client_sup),
    Clients = [client_info(Pid) || Pid <- client_pids(Children)],
    [Info || {ok, Info} <- Clients].

%% A child which is being restarted has no pid (`restarting'), nor one which is not started.
client_pids(Children) ->
    [Pid || {_Id, Pid, _Type, _Modules} <- Children, is_pid(Pid)].

%% The client may be gone since the list was taken.
client_info(Pid) ->
    try
        etcdgun_client:client_info(Pid)
    catch
        exit:_ -> {error, not_running}
    end.

%% @doc Equivalent to `open(Client, Endpoints, #{})', see `open/3'.
-spec open(client(), [endpoint()]) -> {ok, pid()} | {error, Reason :: term()}.
open(Client, Endpoints) ->
    open(Client, Endpoints, #{}).

%% @doc Open a client and connect to the members of the etcd cluster.
%%
%% Returns `{error, no_credentials}' if the etcd server requires authentication but no `cred' is
%% given.
%%
%% The options `unary_interceptors' and `stream_interceptors' of the former versions are replaced
%% by `interceptors', they return `{error, {removed_option, Key}}'. The authentication is not an
%% interceptor to be configured anymore.
-spec open(client(), [endpoint()], opts()) -> {ok, pid()} | {error, Reason :: term()}.
open(Client, Endpoints, Opts) ->
    etcdgun_client_sup:start_child(Client, Endpoints, Opts).

%% @doc Close the client, the watchers of it are stopped with the reason `shutdown'.
close(Client) ->
    ok = etcdgun_watcher_sup:stop_children(Client),
    etcdgun_client_sup:stop_child(Client).

%% @doc Start a watcher, which has one watch, with the create request `Request' (a
%% `WatchCreateRequest' of etcd, e.g. `#{key => Key, range_end => RangeEnd}').
%%
%% The events are given to the handler `EventHandler' (a module with the callbacks of a
%% `gen_event' handler, `init/1', `handle_event/2' and `terminate/2', or `{Module, Id}'), which is
%% initialised with `EventHandlerArgs'. The pid which is returned is the watcher.
%%
%% The handler is called by the watcher, in its process, there is no event manager process: a
%% slow handler holds the watch back. What a handler returns is what the watcher does:
%% <ul>
%%   <li>`{ok, State}': the next event is given to it;</li>
%%   <li>`{cancel_watch, State}': the watch is cancelled as by `cancel_watch/2', the watcher stops
%%       with the reason `shutdown', and the handler gets `{watch_stopped, shutdown, _}' and
%%       `terminate/2' as it does then. `cancel_watch/2' and `close/1' are not to be called by
%%       the handler, they raise `called_from_the_handler';</li>
%%   <li>an exception or any other return: it is initialised again with `EventHandlerArgs' (its
%%       state is lost, and so is the event, which is given at most once), and the watcher stops
%%       with `{handler_failed, Reason}' when that happens more than 5 times in 10 seconds.</li>
%% </ul>
%% The events are:
%% <ul>
%%   <li>`{watch_events, Events}';</li>
%%   <li>`{watch_paused, Reason, LastRevision}', once, when the connection is lost (or can not be
%%       made): the watcher stays, connects again and resumes after the last revision, no event
%%       is lost;</li>
%%   <li>`{watch_resumed, LastRevision}', when the watch is created again. This is also the case
%%       when the connection could not be made at the start: `watch/5' returns `{ok, Pid}', the
%%       handler is told `{watch_paused, Reason, undefined}' (the watch was not created, there is
%%       no revision), and `{watch_resumed, LastRevision}' when it is created. A watch which is
%%       created at the first attempt gets neither;</li>
%%   <li>`{watch_stopped, Reason, LastRevision}', when the watcher stops, as far as it is able
%%       to: it is not when it is killed.</li>
%% </ul>
%% `LastRevision' is the revision of the last event which was given to the handler, or `undefined'
%% when the watch was not created yet; to watch again without a gap or a repeat, watch from
%% `LastRevision + 1' (`start_revision' of the request). A handler needs a clause for every event
%% it does not care about, or it crashes at them. The callbacks `handle_call/2', `handle_info/2'
%% and `code_change/3' are not called.
%%
%% The watcher is the lifecycle of the watch, monitor the pid which is returned: it does not give
%% up when the network or the cluster is not available, and it is not restarted when it stops.
%% The reason of the exit is:
%% <ul>
%%   <li>`shutdown': `cancel_watch/2', `close/1' of the client, the application is stopped, or the
%%       handler returned `{cancel_watch, State}';</li>
%%   <li>`{shutdown, {canceled, {compacted, Revision}}}': the revision to start from was
%%       compacted, it is `Revision' which the store is compacted to;</li>
%%   <li>`{shutdown, {canceled, Reason}}': the server cancelled the watch (it is not allowed, ...);</li>
%%   <li>`{grpc_error, Status}': the call was refused, not for the network or the availability of the
%%       server;</li>
%%   <li>`{auth_failed, Reason}': the token was refused again after it was refreshed, e.g. the
%%       credentials were changed or removed;</li>
%%   <li>`{handler_failed, Reason}': the handler crashed too often;</li>
%%   <li>any other: it crashed.</li>
%% </ul>
%% The reason which a monitor gets is `killed' or `noproc' when the watcher was killed or ended
%% before it was monitored.
%%
%% <b>progress_notify</b>: the request may have `progress_notify => true', which is passed to the
%% server as it is (it is `false' when not given): the server then sends a response without events
%% now and then (when it decides to, by its configuration, it is a matter of minutes by default),
%% which says that everything up to its revision was sent. The watcher takes it as the last
%% revision. Without it the last revision stays at the revision of the last event, or of the
%% creation of the watch, and a watch of a key which changes rarely starts from an old revision
%% when it connects again after the connection was lost: if the store was compacted in the
%% meantime that revision is gone, and the watcher stops with
%% `{shutdown, {canceled, {compacted, Revision}}}', with `Revision' to start from (some events
%% between are not seen). It is not an option which makes the events come sooner, the handler is
%% not told of the responses without events.
%%
%% `{error, {invalid_handler, EventHandler}}' is returned when there is no handler: it is not a
%% module which has `init/1' and `handle_event/2'. `{error, {handler_init, Reason}}' is returned
%% when the initialisation of the handler fails.
%%
%% `{error, {invalid_request, _}}' is returned when `Request' has no `key', and
%% `{error, {unsupported_option, fragment}}' when it asks for fragments, which are not supported.
%% The `watch_id' of the request is ignored.
-spec watch(client(), atom(), module(), term(), map()) -> {ok, pid()} | {error, Reason :: term()}.
watch(Client, WatcherName, EventHandler, EventHandlerArgs, Request) ->
    etcdgun_watcher_sup:start_child(Client, WatcherName, EventHandler, EventHandlerArgs, Request).

cancel_watch(Client, WatcherName) ->
    etcdgun_watcher_sup:stop_child(Client, WatcherName).

-define(UNBOUND_RANGE_END, "\0").

%% @doc Given a etcd key, return the end key for a prefix range.
%%
%% The result has the type of the key: a binary for a binary and a string for a string.
-spec prefix_range_end(Key :: binary()) -> binary();
                      (Key :: string()) -> string().
prefix_range_end(Key) when is_binary(Key) ->
    list_to_binary(prefix_range_end(binary_to_list(Key)));

prefix_range_end(Key) when is_list(Key) ->
    RangeEndRev = lists:reverse(Key),
    % eqwalizer:ignore
    lists:reverse(find_prefix_rev(RangeEndRev)).

find_prefix_rev([]) -> ?UNBOUND_RANGE_END;
find_prefix_rev([H | T]) when H < 255 -> [H + 1 | T];
find_prefix_rev([_ | T]) -> find_prefix_rev(T).

-ifdef(TEST).
client_pids_test() ->
    Pid = self(),
    Children = [{a, Pid, worker, [m]}, {b, restarting, worker, [m]}, {c, undefined, worker, [m]}],
    ?assertEqual([Pid], client_pids(Children)),
    ?assertEqual([], client_pids([])).

prefix_range_end_binary_test() ->
    ?assertEqual(<<"b">>, prefix_range_end(<<"a">>)),
    ?assertEqual(<<"ab">>, prefix_range_end(<<"aa">>)),
    ?assertEqual(<<"a\x02">>, prefix_range_end(<<"a\x01">>)),
    ?assertEqual(<<"b">>, prefix_range_end(<<"a\xff">>)),
    ?assertEqual(<<0>>, prefix_range_end(<<>>)),
    ?assertEqual(<<0>>, prefix_range_end(<<255, 255>>)),
    ?assert(is_binary(prefix_range_end(<<"/etcdgun_ct/1/">>))).

get_prefix_range_end_test() ->
    ?assertEqual(?UNBOUND_RANGE_END, prefix_range_end([])),
    ?assertEqual("b", prefix_range_end("a")),
    ?assertEqual("a\x01", prefix_range_end("a\x00")),
    ?assertEqual("a\x02", prefix_range_end("a\x01")),
    ?assertEqual("b", prefix_range_end("a\xff")),
    ?assertEqual("c", prefix_range_end("b")),
    ?assertEqual("ab", prefix_range_end("aa")),
    ok.
-endif.
