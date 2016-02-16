-module(spartan_sup).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    ZkRecordServer = {spartan_zk_record_server,
                      {spartan_zk_record_server, start_link, []},
                       permanent, 5000, worker,
                       [spartan_zk_record_server]},

    {ok, { {one_for_all, 0, 1}, [ZkRecordServer]} }.

%%====================================================================
%% Internal functions
%%====================================================================
