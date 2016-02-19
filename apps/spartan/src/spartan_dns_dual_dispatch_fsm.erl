-module(spartan_dns_dual_dispatch_fsm).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/5,
         resolve/3,
         async_resolve/4,
         async_resolve/5,
         sync_resolve/3]).

%% gen_fsm callbacks
-export([init/1,
         execute/2,
         waiting/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-include("spartan.hrl").

%% We can't include these because of name clashes.
% -include_lib("kernel/src/inet_dns.hrl").
% -include_lib("kernel/src/inet_res.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-record(state, {req_id :: req_id(),
                from :: pid(),
                message :: dns:message(),
                authority_records :: [dns:rr()],
                host :: dns:ip(),
                self :: pid(),
                name :: dns_query:name(),
                type :: dns_query:type(),
                class :: dns_query:class()
               }).

-type error()      :: term().
-type req_id()     :: term().

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(req_id(), pid(), dns:message(), [dns:rr()], dns:ip()) -> {ok, pid()} | ignore | {error, error()}.
start_link(ReqId, From, Message, AuthorityRecords, Host) ->
    gen_fsm:start_link(?MODULE,
                       [ReqId, From, Message, AuthorityRecords, Host],
                       []).

-spec resolve(dns:message(), [dns:rr()], dns:ip()) -> {ok, req_id()}.
resolve(Message, AuthorityRecords, Host) ->
    ReqId = mk_reqid(),
    _ = spartan_dns_dual_dispatch_fsm_sup:start_child(
            [ReqId, self(), Message, AuthorityRecords, Host]),
    {ok, ReqId}.

-spec sync_resolve(dns:message(), [dns:rr()], dns:ip()) -> {ok, dns:message()}.
sync_resolve(Message, AuthorityRecords, Host) ->
    ReqId = mk_reqid(),
    _ = spartan_dns_dual_dispatch_fsm_sup:start_child(
            [ReqId, self(), Message, AuthorityRecords, Host]),
    spartan_app:wait_for_reqid(ReqId, infinity).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init([ReqId, From, Message, AuthorityRecords, Host]) ->
    lager:info("Resolution request for message: ~p", [Message]),
    Self = self(),
    Questions = Message#dns_message.questions,
    Question = hd(Questions),
    Name = Question#dns_query.name,
    Type = Question#dns_query.type,
    Class = Question#dns_query.class,
    lager:info("Question: ~p", [Question]),
    {ok, execute, #state{req_id=ReqId,
                         from=From,
                         message=Message,
                         authority_records=AuthorityRecords,
                         host=Host,
                         self=Self,
                         name=Name,
                         type=Type,
                         class=Class}, 0}.

%% @doc Dispatch to all resolvers.
execute(timeout, #state{self=Self,
                        name=Name,
                        class=Class,
                        type=Type,
                        message=Message,
                        authority_records=AuthorityRecords,
                        host=Host}=State) ->
    Name = normalize_name(Name),
    case dns:dname_to_labels(Name) of
      [] ->
            gen_fsm:send_event(Self, {error, zone_not_found});
      [_] ->
            gen_fsm:send_event(Self, {error, zone_not_found});
      [_|Labels] ->
            case Labels of
                [<<"zk">>] ->
                    %% Zookeeper request.
                    spawn(?MODULE, async_resolve, [Self, Message, AuthorityRecords, Host]);
                [<<"mesos">>] ->
                    %% Mesos request.
                    [spawn(?MODULE, async_resolve, [Self, Name, Class, Type, Resolver])
                     || Resolver <- ?MESOS_RESOLVERS];
                Label ->
                    lager:info("Assuming upstream: ~p", [Label]),
                    %% Upstream request.
                    [spawn(?MODULE, async_resolve, [Self, Name, Class, Type, Resolver])
                     || Resolver <- ?UPSTREAM_RESOLVERS]
            end
    end,
    {next_state, waiting, State}.

%% @doc Return as soon as we receive the first response.
waiting(Response, #state{req_id=ReqId, from=From}=State) ->
    lager:info("Received response: ~p", [Response]),
    From ! {ReqId, ok, convert(Response)},
    {stop, normal, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
normalize_name(Name) when is_list(Name) ->
    string:to_lower(Name);
normalize_name(Name) when is_binary(Name) ->
    list_to_binary(string:to_lower(binary_to_list(Name))).

%% @private
%% @doc Internal callback function for performing local resolution.
async_resolve(Self, Message, AuthorityRecords, Host) ->
    Response = erldns_resolver:resolve(Message, AuthorityRecords, Host),
    gen_fsm:send_event(Self, Response).

%% @private
%% @doc Internal callback function for performing resolution.
async_resolve(Self, Name, Class, Type, Resolver) ->
    {ok, IpAddress} = inet:parse_address(Resolver),
    Opts = [{nameservers, [{IpAddress, ?PORT}]}],

    %% @todo It's unclear how to return a nxdomain response through
    %%       erldns, yet.  Figure it out.
    {ok, Response} = inet_res:resolve(binary_to_list(Name), Class, Type, Opts),

    gen_fsm:send_event(Self, Response).

%% @doc Generate a request id.
mk_reqid() ->
    erlang:phash2(erlang:timestamp()).

%% @private
%% @doc
%%
%% Convert a inet_dns response to a dns response so that it's cachable
%% and encodable via the erldns application.
%%
%% This first formal argument is a #dns_rec, from inet_dns, but we can't
%% load because it will cause a conflict with the naming in the dns
%% application used by erldns.
%%
convert(#dns_message{} = Message) ->
    Message;
convert(Message) ->
    Header = inet_dns:msg(Message, header),
    Questions = inet_dns:msg(Message, qdlist),
    Answers = inet_dns:msg(Message, anlist),
    Authorities = inet_dns:msg(Message, nslist),
    Resources = inet_dns:msg(Message, arlist),
    #dns_message{
              id = inet_dns:header(Header, id),
              qr = inet_dns:header(Header, qr),
              oc = inet_dns:header(Header, opcode), %% @todo Could be wrong.
              aa = inet_dns:header(Header, aa),
              tc = inet_dns:header(Header, tc),
              rd = inet_dns:header(Header, rd),
              ra = inet_dns:header(Header, ra),
              ad = 0, %% @todo Could be wrong.
              cd = 0, %% @todo Could be wrong.
              rc = inet_dns:header(Header, rcode), %% @todo Could be wrong.
              qc = 0,
              anc = 0,
              auc = 0,
              adc = 0,
              questions = convert(qdlist, Questions),
              answers = convert(anlist, Answers),
              authority = convert(nslist, Authorities),
              additional = convert(arlist, Resources)}.

convert(qdlist, _Questions) ->
    [];
convert(anlist, _Answers) ->
    [];
convert(nslist, _Authorities) ->
    [];
convert(arlist, _Resources) ->
    [].

-ifdef(TEST).

-endif.
