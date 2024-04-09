-module(multi_nodes_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-compile([export_all]).

-export([all/0]).

all() ->
    [{group, task_multi_nodes}].

groups() ->
    [
        {task_multi_nodes, [sequence], [three_nodes_test, three_nodes_one_node_disconnection_test]}
    ].

init_per_suite(Config) ->
    helper:configure_logger(),
    NodePeers = start_nodes(3),
    [{node_peers, NodePeers} | Config].

end_per_suite(Config) ->
    NodePeers = proplists:get_value(node_peers, Config),
    stop_nodes(NodePeers).

wait_connections([], _) ->
    ok;
wait_connections(Nodes, Timeout) ->
    net_kernel:monitor_nodes(true),
    ExcludedNodes = nodes(known),
    NewNodes = [N || N <- Nodes, not lists:member(N, ExcludedNodes)],

    receive
        {nodeup, Node} ->
            wait_connections([N || N <- NewNodes, N =/= Node], Timeout)
    after Timeout ->
        error(nodes_not_connected)
    end.

init_node() ->
    helper:configure_logger("multi_nodes_SUITE.log"),
    application:start(tasc).

start_nodes(Num) ->
    ct:print("starting ~p nodes", [Num]),
    net_kernel:monitor_nodes(true),
    Seq = lists:seq(1, Num),
    %% Don't start global because we need to simulate a node disconnection in some tests,
    %% which can lead to node disconnection everywhere when global is activated.
    %% More explanations in this topic:
    %% https://erlangforums.com/t/how-do-i-replace-ct-slave-start-with-ct-peer-or-the-peer-module/1494/8
    Peers = [
        ?CT_PEER(#{
            wait_boot => {self(), tag},
            args => ["-pa" | code:get_path()] ++ ["-kernel", "connect_all", "false"],
            name => io_lib:format("node~p", [N]),
            shutdown => halt
        })
     || N <- Seq
    ],

    [unlink(P) || {_, P} <- Peers],

    ct:print("waiting for ~p nodes to be started...", [Num]),
    NodePeers = [
        receive
            {tag, {started, Node, P}} -> {Node, P}
        end
     || {ok, P} <- Peers
    ],

    Nodes = [N || {N, _} <- NodePeers],
    ct:print("connecting nodes each other ~p", [Nodes]),
    [true = rpc:call(N, net_kernel, connect_node, [N]) || N <- Nodes],

    ct:print("initializing ~p nodes...", [Num]),
    [ok = rpc:call(N, ?MODULE, init_node, []) || {N, _} <- NodePeers],

    NodePeers.

wait_disconnections([], _) ->
    ok;
wait_disconnections([Node | Nodes], Timeout) ->
    KnownNodes = nodes(known),
    NewNodes = [N || N <- Nodes, lists:member(N, KnownNodes)],

    receive
        {nodedown, Node} ->
            ct:print("Msg ~p", [Node]),
            wait_disconnections([N || N <- NewNodes, N =/= Node], Timeout)
    after Timeout ->
        error(nodes_not_disconnected)
    end.

stop_nodes(NodePeers) ->
    ct:print("stop_nodes ~p", [NodePeers]),
    [peer:stop(P) || {_, P} <- NodePeers].

spawn_node(NodeNum) when is_integer(NodeNum) ->
    NodeName = io_lib:format("node~p", [NodeNum]),
    Opts = #{
        wait_boot => {self(), tag},
        name => NodeName,
        args => ["-pa" | code:get_path() ++ ["ebin"]]
    },
    {ok, Peer, Node} = ?CT_PEER(Opts),
    ok = rpc:call(Node, ?MODULE, init_node, []),

    {Peer, Node}.

call_remote_nodes(NodePeers, Module, Function, Args) ->
    Keys = [rpc:async_call(N, Module, Function, Args) || {N, _} <- NodePeers],
    [rpc:yield(K) || K <- Keys].

call_remote_nodes(NodePeers, Module, Function, Args, ExpectedResult) ->
    Results = call_remote_nodes(NodePeers, Module, Function, Args),
    ExpectedResults = lists:duplicate(length(NodePeers), ExpectedResult),
    ?assertEqual(ExpectedResults, Results).

remote_three_nodes() ->
    %% Start task scheduler.
    Settings = [{interval, 100}, {timeout, 10}],
    tasc:start_scheduler(task_mock, Settings),

    %% Trigger task mock.
    ok = tasc:schedule(task_mock, task_mock, [0]),

    %% Check messages on all nodes.
    Seq = lists:seq(0, 10),
    [helper:assert_receive(C, 1000) || C <- Seq],

    %% Stop the scheduler on each node and check that no more messages are sent.
    tasc:stop_scheduler(task_mock),
    helper:assert_not_receive(500),
    ok.

three_nodes_test(Config) when is_list(Config) ->
    NodePeers = proplists:get_value(node_peers, Config),
    call_remote_nodes(NodePeers, ?MODULE, remote_three_nodes, [], ok).

remote_three_nodes_one_node_disconnection(NodeDisconnected, Nodes) ->
    %% Start task scheduler.
    Settings = [{interval, 100}, {timeout, 10}],
    tasc:start_scheduler(task_mock, Settings),

    %% Trigger task mock.
    ok = tasc:schedule(task_mock, task_mock, [0]),

    %% Check messages on all nodes.
    Seq1 = lists:seq(0, 3),
    [helper:assert_receive(C, 1000) || C <- Seq1],

    %% Disconnect first node. Scheduler must not preventing task from being running
    %% on the disconnect node and on the remaining cluster.
    case node() of
        NodeDisconnected ->
            ct:print("disconnecting node ~p from cluster ~p...", [NodeDisconnected, Nodes]),
            [erlang:disconnect_node(N) || N <- Nodes, N =/= NodeDisconnected];
        _ ->
            []
    end,
    Seq2 = lists:seq(4, 10),
    [helper:assert_receive(C, 1000) || C <- Seq2],

    %% Reconnect first node. Scheduler prevents task from being executed on multiple nodes.
    case node() of
        NodeDisconnected ->
            ct:print("reconnecting node ~p to cluster ~p...", [NodeDisconnected, Nodes]),
            [net_kernel:connect_node(N) || N <- Nodes, N =/= NodeDisconnected];
        _ ->
            []
    end,
    Seq3 = lists:seq(11, 15),
    [helper:assert_receive(C, 1000) || C <- Seq3],

    %% Stop the scheduler on each node and check that no more messages are sent.
    tasc:stop_scheduler(task_mock),
    helper:assert_not_receive(500),
    ok.

three_nodes_one_node_disconnection_test(Config) when is_list(Config) ->
    NodePeers = proplists:get_value(node_peers, Config),
    Nodes = [N || {N, _} <- NodePeers],
    [NodeDisconnected | _] = Nodes,
    call_remote_nodes(
        NodePeers, ?MODULE, remote_three_nodes_one_node_disconnection, [NodeDisconnected, Nodes], ok
    ).
