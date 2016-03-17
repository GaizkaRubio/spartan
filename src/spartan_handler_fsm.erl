-module(spartan_handler_fsm).
-author("sdhillon").
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API

-define(SERVER, ?MODULE).

-define(TIMEOUT, 5000).

-include("spartan.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-type error() :: term().

%% State callbacks
-export([execute/2,
         wait_for_reply/2,
         waiting_for_rest_replies/2]).

%% Private utility functions
-export([do_resolve/3]).

%% API
-export([start_link/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-type dns_message() :: #dns_message{}.
-type from_module() :: spartan_udp_server | spartan_tcp_handler.
-type from_key() :: {inet:ip4_address(), inet:port_number()} | pid().
-type from() :: {from_module(), from_key()}.
-type outstanding_upstream() :: {upstream(), pid()}.

-record(state, {
    from = erlang:error() :: from(),
    dns_message :: dns_message(),
    data = erlang:error() :: binary(),
    outstanding_upstreams = [] :: [outstanding_upstream()],
    send_query_time :: integer(),
    start_timestamp = undefined :: os:timestamp()
}).

-spec(start_link(from(), binary()) -> {ok, pid()} | ignore | {error, error()}).
start_link(From, Data) ->
    gen_fsm:start_link(?MODULE, [From, Data], []).

%% @private
init([From, Data]) ->
    process_flag(trap_exit, true),
    case From of
        {spartan_tcp_handler, Pid} when is_pid(Pid) ->
            %% Link handler pid.
            link(Pid);
        _ ->
            %% Don't link.
            ok
    end,
    {ok, execute, #state{from=From, data=Data}, 0}.

%% @private
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%% @private
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info({'EXIT', FromPid, normal}, StateName,
            #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->
    Upstream = lists:keyfind(FromPid, 2, OutstandingUpstreams0),
    spartan_metrics:update([?MODULE, Upstream, successes], 1, ?COUNTER),
    OutstandingUpstreams = lists:keydelete(Upstream, 1, OutstandingUpstreams0),
    {next_state, StateName, State#state{outstanding_upstreams=OutstandingUpstreams}};
handle_info({'EXIT', FromPid, _Reason}, StateName,
            #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->
    Upstream = lists:keyfind(FromPid, 2, OutstandingUpstreams0),
    spartan_metrics:update([?MODULE, Upstream, failures], 1, ?COUNTER),
    OutstandingUpstreams = lists:keydelete(Upstream, 1, OutstandingUpstreams0),
    {next_state, StateName, State#state{outstanding_upstreams=OutstandingUpstreams}};
handle_info(Info, StateName, State) ->
    lager:debug("Got info: ~p", [Info]),
    {next_state, StateName, State}.

%% @private
terminate(_Reason, _StateName, #state{from=From}) ->
    case From of
        {spartan_tcp_handler, Pid} when is_pid(Pid) ->
            %% Unlink handler pid.
            unlink(Pid);
        _ ->
            %% Don't link.
            ok
    end,
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

execute(timeout, State = #state{data = Data}) ->
    %% The purpose of this pattern match is to bail as soon as possible,
    %% in case the data we've received is 'corrupt'
    DNSMessage = #dns_message{} = dns:decode_message(Data),
    Questions = DNSMessage#dns_message.questions,
    State1 = State#state{dns_message = DNSMessage, send_query_time = erlang:monotonic_time()},
    case spartan_router:upstreams_from_questions(Questions) of
        [] ->
            spartan_metrics:update([?APP, no_upstreams_available], 1, ?COUNTER),
            reply_fail(State1),
            {stop, normal, State};
        Upstreams0 ->
            StartTimestamp = os:timestamp(),
            {ok, QueryUpstreams} = take_upstreams(Upstreams0),
            OutstandingUpstreams = lists:map(fun(Upstream) ->
                            Pid = spawn_link(?MODULE,
                                             do_resolve,
                                             [self(), Upstream, State]),
                            {Upstream, Pid}
                            end, QueryUpstreams),
            State2 = State1#state{start_timestamp=StartTimestamp,
                                  outstanding_upstreams=OutstandingUpstreams},
            {next_state, wait_for_reply, State2, ?TIMEOUT}
    end.

%% The first reply.
wait_for_reply({upstream_reply, Upstream, ReplyData},
               #state{start_timestamp=StartTimestamp}=State) ->
    %% Match to force quick failure.
    #dns_message{} = dns:decode_message(ReplyData),

    %% Reply immediately.
    reply_success(ReplyData, State),
    spartan_metrics:update([?MODULE, Upstream, successes], 1, ?COUNTER),

    %% Then, record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    spartan_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    maybe_done(Upstream, State);
%% Timeout waiting for messages, assume all upstreams have timed out.
wait_for_reply(timeout, #state{outstanding_upstreams=Upstreams}=State) ->
    spartan_metrics:update([?APP, upstreams_failed], 1, ?COUNTER),
    lists:foreach(fun(Upstream) ->
                        spartan_metrics:update([?MODULE, Upstream, failures], 1, ?COUNTER)
                  end, Upstreams),
    {stop, normal, State}.

waiting_for_rest_replies({upstream_reply, Upstream, _ReplyData},
                         #state{start_timestamp=StartTimestamp}=State) ->
    %% Record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    spartan_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    %% Ignore reply data.
    maybe_done(Upstream, State);
waiting_for_rest_replies(timeout,
                         #state{outstanding_upstreams=Upstreams}=State) ->
    lists:foreach(fun(Upstream) ->
                        spartan_metrics:update([?MODULE, Upstream, failures], 1, ?COUNTER)
                  end, Upstreams),
    {stop, normal, State}.

%% Internal API
%% Kind of ghetto. Fix it.
%% @private
maybe_done(Upstream, #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->
    Now = erlang:monotonic_time(),
    OutstandingUpstreams = lists:keydelete(Upstream, 1, OutstandingUpstreams0),
    State1 = State#state{outstanding_upstreams=OutstandingUpstreams0},
    case OutstandingUpstreams of
        [] ->
            %% We're done. Great.
            {stop, normal, State1};
        _ ->
            Timeout = erlang:convert_time_unit(Now - State#state.send_query_time, native, milli_seconds),
            {next_state, waiting_for_rest_replies, State1, Timeout}
    end.

%% @private
reply_success(Data, _State = #state{from = {FromModule, FromKey}}) ->
    FromModule:do_reply(FromKey, Data).

%% @private
reply_fail(_State1 = #state{dns_message = DNSMessage, from = {FromModule, FromKey}}) ->
    Reply =
        DNSMessage#dns_message{
            rc = ?DNS_RCODE_SERVFAIL
        },
    EncodedReply = dns:encode_message(Reply),
    FromModule:do_reply(FromKey, EncodedReply).

%% @private
do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {spartan_udp_server, _}}) ->
    {ok, Socket} = gen_udp:open(0, [{reuseaddr, true}, {active, once}, binary]),
    gen_udp:send(Socket, UpstreamIP, UpstreamPort, Data),
    %% Should put a timeout here given we're linked to our parents?
    receive
        {udp, Socket, UpstreamIP, UpstreamPort, ReplyData} ->
            lager:debug("Received Reply"),
            gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData});
        Else ->
            lager:debug("Received else: ~p, while upstream: ~p", [Else, Upstream])
        after ?TIMEOUT ->
            lager:debug("Timed out waiting for upstream: ~p", [Upstream])
    end,
    gen_udp:close(Socket);

%% @private
do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {spartan_tcp_handler, _}}) ->
    {ok, Socket} = gen_tcp:connect(UpstreamIP, UpstreamPort, [{active, once}, binary, {packet, 2}]),
    gen_tcp:send(Socket, Data),
    %% Should put a timeout here given we're linked to our parents?
    receive
        {tcp, Socket, ReplyData} ->
            gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData})
    after ?TIMEOUT ->
        ok
    end,
    gen_tcp:close(Socket).

%% @private
take_upstreams(Upstreams0) ->
    Length = length(Upstreams0),
    case Length > 2 of
        true ->
            Upstreams = lists:map(fun(_) ->
                              Nth = random:uniform(Length),
                              lists:nth(Nth, Upstreams0)
                      end,
                      lists:seq(1, 2)),
            {ok, Upstreams};
        false ->
            {ok, Upstreams0}
    end.
