%% MIT License
%%
%% Copyright (c) 2024 Ludovic Desweemer
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy of this software
%% and associated documentation files (the "Software"), to deal in the Software without restriction,
%% including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
%% subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all copies or substantial
%% portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
%% LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
%% OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

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

init_per_testcase(bad_interval_test, Config) ->
    Config;
init_per_testcase(bad_timeout_test, Config) ->
    Config;
init_per_testcase(_TestCase, Config) ->
    Settings = [
        {interval, 100},
        {timeout, 10}
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
                bad_interval_test,
                bad_timeout_test,
                args_test,
                init_failed_test,
                duplicate_test,
                run_failed_test,
                continue_stop_test,
                continue_message_stop_test,
                continue_message_stop_message_test,
                continue_message_stop_crash_test,
                reschedule_stop_test,
                reschedule_message_stop_test,
                metrics_module_not_found_test,
                metrics_test
            ]
        }
    ].

spawn_procs(NumProcs, Func, Args) ->
    Sequence = lists:seq(1, NumProcs),
    PidsRefs = [spawn_monitor(?MODULE, Func, Args) || _ <- Sequence],
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

bad_interval(Interval) ->
    Settings = [
        {interval, Interval},
        {timeout, 10}
    ],
    tasc_sup:start_link([{task_mock, Settings}]).

check_bad_setting({Pid, Ref}, Key, Value, Reason) ->
    receive
        {'DOWN', Ref, process, Pid,
            {shutdown,
                {failed_to_start_child, task_mock_scheduler, {
                    {invalid_setting, Key, Value, Reason}, _
                }}}} ->
            ok
    after 500 ->
        ?assert(false, "error not raised or incorrect")
    end.

bad_timeout(Timeout) ->
    Settings = [
        {interval, 10},
        {timeout, Timeout}
    ],
    tasc_sup:start_link([{task_mock, Settings}]).

bad_interval_test(_Config) ->
    PidRef1 = spawn_monitor(?MODULE, bad_interval, [-100]),
    check_bad_setting(PidRef1, interval, -100, pos_integer),
    PidRef2 = spawn_monitor(?MODULE, bad_interval, [wrong_type]),
    check_bad_setting(PidRef2, interval, wrong_type, pos_integer).

bad_timeout_test(_Config) ->
    PidRef1 = spawn_monitor(?MODULE, bad_timeout, [-100]),
    check_bad_setting(PidRef1, timeout, -100, pos_integer),
    PidRef2 = spawn_monitor(?MODULE, bad_timeout, [0]),
    check_bad_setting(PidRef2, timeout, 0, not_null),
    PidRef3 = spawn_monitor(?MODULE, bad_timeout, [wrong_type]),
    check_bad_setting(PidRef3, timeout, wrong_type, pos_integer).

args_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [0]),
    helper:assert_receive(0, 90, 50),
    ok.

init_failed_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [-1]),
    helper:assert_receive(
        {error, tasc, init_failed, negative_counter, {task_mock, ?FUNCTION_NAME}}, 100
    ),
    ok.

duplicate_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [0]),
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [10]),
    helper:assert_receive(
        {error, tasc, init_failed, already_scheduled, {task_mock, ?FUNCTION_NAME}}, 100
    ),
    ok.

metrics_module_not_found_test(_Config) ->
    Metrics = tasc:metrics(unknown),
    ?assertEqual(Metrics, {error, not_found}, "error not_found is not returned"),
    ok.

metrics_test(_Config) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [10]),
    Pid = whereis(task_mock),
    {ok, Metrics} = tasc:metrics(task_mock),
    QueueLen = maps:get(message_queue_len, Metrics),
    ?assert(
        is_integer(QueueLen) and (QueueLen >= 0), "message_queue_len is not a positive integer"
    ),
    ?assertEqual(
        Metrics,
        #{count => 1, message_queue_len => QueueLen, pid => Pid},
        "metrics are not correctly returned"
    ),
    ok.

run_failed(Counter, LastCounter, Limit, Interval, Timeout) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, message, LastCounter, stop, [], Limit]),
    Seq = lists:seq(Counter, Limit),
    [helper:assert_receive(C, Interval, Timeout) || C <- Seq],
    helper:assert_receive(
        {error, tasc, run_failed, limit_reached, {task_mock, ?FUNCTION_NAME}}, 200
    ),
    helper:assert_not_receive(Timeout).

schedule_continue_stop(Counter, LastCounter, Timeout) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, undefined, LastCounter, stop, []]),
    helper:assert_not_receive(Timeout).

schedule_continue_message_stop(Counter, LastCounter, Interval, Timeout) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, message, LastCounter, stop, []]),
    %% Last counter is not sent due to stop.
    Seq = lists:seq(Counter, LastCounter - 1),
    [helper:assert_receive(C, Interval, Timeout) || C <- Seq],
    helper:assert_not_receive(Interval + Timeout).

schedule_continue_message_stop_message(Counter, LastCounter, Interval, Timeout) ->
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, message, LastCounter, stop_message, []]),
    Seq = lists:seq(Counter, LastCounter - 1),
    [helper:assert_receive(C, Interval, Timeout) || C <- Seq],
    %% Last counter is sent as {stop, Lastcounter}.
    helper:assert_receive({stop, LastCounter}, Interval, Timeout).

schedule_reschedule_stop(Counter, Intervals, Timeout) ->
    LastCounter = Counter + length(Intervals),
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, undefined, LastCounter, stop, Intervals]),
    helper:assert_not_receive(Timeout).

schedule_reschedule_message_stop(Counter, Intervals, Gap, Timeout) ->
    LastCounter = Counter + length(Intervals),
    ok = tasc:schedule(task_mock, ?FUNCTION_NAME, [Counter, message, LastCounter, stop, Intervals]),
    [LastInterval | ReversedIntervals] = lists:reverse(Intervals),
    MsgIntervals = [100 | lists:reverse(ReversedIntervals)],
    [
        helper:assert_receive(Counter + N, I - Gap, Timeout)
     || {N, I} <- lists:enumerate(0, MsgIntervals)
    ],
    helper:assert_not_receive(LastInterval + Timeout).

run_failed_test(_Config) ->
    Pids = spawn_procs(3, run_failed, [0, 10, 5, 90, 50]),
    wait_for_procs(Pids, 1000),
    ok.

continue_stop_test(_Config) ->
    Pids = spawn_procs(3, schedule_continue_stop, [0, 5, 700]),
    wait_for_procs(Pids, 1000),
    ok.

continue_message_stop_test(_Config) ->
    Pids = spawn_procs(3, schedule_continue_message_stop, [0, 5, 90, 50]),
    wait_for_procs(Pids, 1000),
    ok.

continue_message_stop_message_test(_Config) ->
    Pids = spawn_procs(3, schedule_continue_message_stop_message, [0, 5, 90, 50]),
    wait_for_procs(Pids, 1000),
    ok.

continue_message_stop_crash_test(_Config) ->
    [Pid1, Pid2, Pid3] = spawn_procs(3, schedule_continue_message_stop, [0, 5, 90, 50]),
    timer:sleep(10),
    exit(Pid1, crash),
    exit(Pid2, crash),
    exit(Pid3, crash),
    timer:sleep(10),
    %% Check that no task is scheduled after crashes.
    Members = pg:get_members(task_mock_pg, task_mock_scheduler),
    ?assertEqual(Members, []),
    Recs = ets:tab2list(task_mock),
    ?assertEqual(Recs, []).

reschedule_stop_test(_Config) ->
    Intervals = [200, 300, 400, 500],
    Pids = spawn_procs(3, schedule_reschedule_stop, [0, Intervals, 1800]),
    wait_for_procs(Pids, 2000),
    ok.

reschedule_message_stop_test(_Config) ->
    Intervals = [200, 300, 400, 500],
    Pids = spawn_procs(3, schedule_reschedule_message_stop, [0, Intervals, 20, 50]),
    wait_for_procs(Pids, 2000),
    ok.
