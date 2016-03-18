-module(spartan_tcp_handler).
-behaviour(ranch_protocol).

-export([start_link/4,
         do_reply/2]).

-export([init/4]).

-record(state, {peer}).

-include("spartan.hrl").
-define(TIMEOUT, 10000).

do_reply(Pid, Data) ->
    Pid ! {do_reply, Data}.

start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(Ref, Socket, Transport, _Opts = []) ->
    ok = ranch:accept_ack(Ref),
    ok = inet:setopts(Socket, [{packet, 2}, {active, true}]),
    {ok, Peer} = inet:peername(Socket),
    loop(Socket, Transport, #state{peer = Peer}).

loop(Socket, Transport, State) ->
    receive
        {tcp, Socket, Data} ->
            case spartan_handler_sup:start_child([{?MODULE, self()}, Data]) of
                {ok, Pid} when is_pid(Pid) ->
                    spartan_metrics:update([?MODULE, successes], 1, ?COUNTER),
                    ok;
                Else ->
                    lager:warning("Failed to start query handler: ~p", [Else]),
                    spartan_metrics:update([?MODULE, failures], 1, ?COUNTER),
                    error
            end,
            loop(Socket, Transport, State);
        {do_reply, ReplyData} ->
            Transport:send(Socket, ReplyData);
        {tcp_closed, Socket} ->
            ok
    %% Should the timeout here be more aggressive?
    after ?TIMEOUT ->
        Transport:close(Socket)
    end.
