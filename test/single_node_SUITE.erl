-module(single_node_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-compile([export_all]).

-export([all/0, groups/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

init_per_suite(Config) ->
    helper:configure_logger(),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    Settings = [
        {interval, 100},
        {timeout, 10},
        {max_gap, 0}
    ],
    {ok, Sup} = tasc_sup:start_link([{task_mock, Settings}]),
    [{sup, Sup} | Config].

end_per_testcase(_TestCase, Config) ->
    Config.

get_sup(Config) ->
    case proplists:get_value(sup, Config) of
        undefined ->
            not_found;
        Sup ->
            {ok, Sup}
    end.

get_sup_child_pid(Config, ChildId) ->
    {ok, Sup} = get_sup(Config),
    Children = supervisor:which_children(Sup),

    FilteredChildren = lists:filter(
        fun({Id, _Pid, _Type, _Module}) -> Id =:= ChildId end, Children
    ),
    case FilteredChildren of
        [{_Id, Pid, _Type, _Module}] ->
            {ok, Pid};
        _ ->
            not_found
    end.

exit_sup(Config, Cause) ->
    {ok, Sup} = get_sup(Config),
    exit(Sup, Cause).

all() ->
    [
        {group, task}
    ].

groups() ->
    [
        {
            task,
            [sequence],
            [
                args_test,
                duplicate_test,
                one_proc_one_node_test,
                three_procs_one_node_test,
                three_procs_one_node_proc_crash_test
            ]
        }
    ].

spawn_sequence(NumProcs, TaskId, Counter, Size, Timeout) ->
    Sequence = lists:seq(1, NumProcs),
    PidsRefs = [
        spawn_monitor(helper, assert_sequence, [TaskId, Counter, Size, Timeout])
     || _ <- Sequence
    ],
    [P || {P, _R} <- PidsRefs].

wait_for_procs([], _Timeout) ->
    ok;
wait_for_procs(Pids, Timeout) ->
    receive
        {'DOWN', _Ref, process, Pid, normal} ->
            NewPids = lists:filter(fun(P) -> P =/= Pid end, Pids),
            wait_for_procs(NewPids, Timeout)
    after Timeout ->
        error(wait_for_procs_expired)
    end.

args_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [0]),
    helper:assert_not_receive(50),
    helper:assert_receive(0, 500),
    ok.

duplicate_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [0]),
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [10]),
    helper:assert_receive({error, already_scheduled, ?FUNCTION_NAME}, 1000),
    ok.

one_proc_one_node_test(_Config) ->
    helper:assert_sequence(?FUNCTION_NAME, 10, 5, 500),
    ok.

three_procs_one_node_test(_Config) ->
    Pids = spawn_sequence(3, ?FUNCTION_NAME, 1, 3, 500),
    wait_for_procs(Pids, 500),
    ok.

three_procs_one_node_proc_crash_test(_Config) ->
    [Pid1, Pid2, Pid3] = spawn_sequence(3, ?FUNCTION_NAME, 1, 3, 500),
    timer:sleep(10),
    exit(Pid1, crash),
    exit(Pid2, crash),
    exit(Pid3, crash),
    timer:sleep(10),
    Members = pg:get_members(task_mock_pg, task_mock_scheduler),
    ?assertEqual(Members, []),
    TaskState =
        try
            ets:lookup_element(task_mock, proc_test, 2)
        catch
            error:_ -> nil
        end,
    ?assertEqual(nil, TaskState),
    ok.
