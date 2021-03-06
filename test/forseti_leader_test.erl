-module(forseti_leader_test).
-compile([export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(PROCESSES, 999).

-define(NODE1, forseti1_leader@localhost).
-define(NODE2, forseti2_leader@localhost).
-define(NODE3, forseti3_leader@localhost).

-define(NODE1_SHORT, forseti1_leader).
-define(NODE2_SHORT, forseti2_leader).
-define(NODE3_SHORT, forseti3_leader).

%% -- code for the pool

start_link(<<"delay",_/integer>>) ->
    timer:sleep(2000),
    {ok, spawn_link(fun() ->
        receive _ -> ok end
    end)};

start_link(throw_error) ->
    throw(enoproc);

start_link(ret_error) ->
    {error, notfound};

start_link(_Key) ->
    {ok, spawn_link(fun() ->
        receive _ -> ok end
    end)}.

start_link(_Key, arg1, arg2, arg3) ->
    {ok, spawn_link(fun() ->
        receive _ -> ok end
    end)}.

%% -- generator

generator_test_() ->
    {foreach,
        fun start/0,
        fun stop/1, [
            fun basic_test/1,
            fun args_test/1,
            fun load_test/1,
            fun lock_test/1,
            fun ret_error/1,
            fun throw_error/1
        ]
    }.

%% -- initilizer and finisher

start() ->
    net_kernel:start([?NODE1, shortnames]),
    slave:start(localhost, ?NODE2_SHORT),
    slave:start(localhost, ?NODE3_SHORT),

    Call = {?MODULE, start_link, []},
    Nodes = [node()|nodes()],
    ?debugFmt("configuring nodes = ~p~n", [Nodes]),
    timer:sleep(1000),
    forseti:start_link(Call, Nodes),
    spawn(?NODE2, fun() -> 
        forseti:start_link(Call, Nodes),
        receive ok -> ok end
    end),
    spawn(?NODE3, fun() -> 
        forseti:start_link(Call, Nodes),
        receive ok -> ok end
    end),
    timer:sleep(500),
    ok.

stop(_) ->
    %[ rpc:call(Node, forseti, stop, []) || Node <- [node()|nodes()] ],
    [ slave:stop(N) || N <- nodes() ],
    net_kernel:stop(),
    ok.

%% -- tests

basic_test(_) ->
    ?_assert(begin
        ?assertEqual(undefined, forseti:search_key(<<"notfound">>)),
        ?assertMatch({_Node,_PID}, forseti:get_key(<<"newkey">>)),
        {_Node,PID} = forseti:search_key(<<"newkey">>),
        PID ! ok,
        timer:sleep(500),
        ?assertEqual(undefined, forseti:search_key(<<"newkey">>)),
        true
    end).

args_test(_) ->
    ?_assert(begin
        ?assertEqual(undefined, forseti:search_key(<<"argskey">>)),
        Args = [arg1, arg2, arg3],
        ?assertMatch({_Node,_PID}, forseti:get_key(<<"argskey">>, Args)),
        {_Node,PID} = forseti:search_key(<<"argskey">>), 
        PID ! ok,
        timer:sleep(500),
        ?assertEqual(undefined, forseti:search_key(<<"argskey">>)),
        true
    end).

load_test(_) ->
    [{timeout, 60, ?_assert(begin
        [ forseti:get_key(N) || N <- lists:seq(1,?PROCESSES) ],
        FullNodes = forseti:get_metrics(),
        ?assertEqual((?PROCESSES div 3), proplists:get_value(?NODE1, FullNodes)),
        ?assertEqual((?PROCESSES div 3), proplists:get_value(?NODE2, FullNodes)),
        ?assertEqual((?PROCESSES div 3), proplists:get_value(?NODE3, FullNodes)),

        ?assertNotEqual(undefined, forseti:search_key((?PROCESSES + 1) div 5)),
        ?assertNotEqual(undefined, forseti:search_key((?PROCESSES + 1) div 2)),
        ?assertNotEqual(undefined, forseti:search_key(((?PROCESSES + 1) div 10) * 9)),
        true
    end)},
    {timeout, 60, ?_assert(begin
        lists:foreach(fun(Key) ->
            {_Node,PID} = forseti:get_key(Key),
            PID ! ok
        end, lists:seq(1, ?PROCESSES)),
        timer:sleep(500),
        EmptyNodes = rpc:call(?NODE3, forseti, get_metrics, []),
        ?debugFmt("metrics: ~p~n", [EmptyNodes]),
        ?assertEqual(0, proplists:get_value(?NODE1, EmptyNodes)),
        ?assertEqual(0, proplists:get_value(?NODE2, EmptyNodes)),
        ?assertEqual(0, proplists:get_value(?NODE3, EmptyNodes)),
        true
    end)}].

lock_test(_) ->
    [{timeout, 60, ?_assert(begin
        ParentPID = self(),
        spawn(fun() ->
            lists:foreach(fun(N) ->
                Key = <<"delay",N/integer>>,
                ?debugFmt("B> generating key = ~p~n", [Key]),
                forseti:get_key(Key),
                ?debugFmt("<B generated key = ~p~n", [Key])
            end, lists:seq(1,4)),
            ParentPID ! ok
        end),
        timer:sleep(4000),
        {_,S1,_} = os:timestamp(),
        Seq = lists:seq(1, 2), 
        lists:foreach(fun(N) ->
            Key = <<"delay",N/integer>>,
            ?debugFmt(">> request existent key = ~p~n", [Key]),
            forseti:get_key(Key),
            ?debugFmt("<< requested existent key = ~p~n", [Key])
        end, Seq ++ Seq ++ Seq ++ Seq ++ Seq),
        ?assertEqual(undefined, forseti:search_key(<<"delay",4/integer>>)),
        {_,S2,_} = os:timestamp(),
        receive 
            ok -> ok 
        end,
        (S1 + 6) > S2
    end)},
    {timeout, 60, ?_assert(begin
        lists:foreach(fun(N) ->
            Key = <<"delay",N/integer>>,
            {_Node,PID} = forseti:get_key(Key),
            PID ! ok
        end, lists:seq(1,4)),
        timer:sleep(500),
        EmptyNodes = rpc:call(?NODE3, forseti, get_metrics, []),
        ?debugFmt("metrics: ~p~n", [EmptyNodes]),
        0 =:= proplists:get_value(?NODE1, EmptyNodes) andalso
        0 =:= proplists:get_value(?NODE2, EmptyNodes) andalso
        0 =:= proplists:get_value(?NODE3, EmptyNodes)
    end)}].

ret_error(_) ->
    ?_assert(begin
        ?assertMatch({error,_}, forseti:get_key(ret_error)),
        true
    end).

throw_error(_) ->
    ?_assert(begin
        ?assertMatch({error,_}, forseti:get_key(throw_error)),
        true
    end).
