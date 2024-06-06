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

-module(tasc_scheduler).

-behaviour(gen_server).

-include("include/tasc.hrl").

-export([start_link/3]).
-export([
    handle_cast/2,
    handle_info/2,
    handle_call/3
]).
-export([init/1, terminate/2]).

-export([init_task/6, run_task/5]).

-record(share, {
    interval :: pos_integer(),
    last_update :: erlang:timestamp() | undefined,
    state :: task_state(),
    priorities = [] :: [{term(), atom()}]
}).

-type share() :: #share{}.

-record(task, {
    share = #share{} :: #share{} | undefined,
    timer_ref :: reference() | undefined,
    pid :: pid() | undefined
}).

-record(state, {
    task_module :: atom(),
    pg_scope :: atom(),
    monitor_ref :: reference(),
    interval :: pos_integer(),
    timeout :: pos_integer(),
    tasks :: ets:table()
}).

-type state() :: #state{}.

-spec start_link(TaskModule :: atom(), PgScope :: atom(), Settings :: settings()) ->
    gen_server:start_ret().
start_link(TaskModule, PgScope, Settings) ->
    gen_server:start_link({local, TaskModule}, ?MODULE, {TaskModule, PgScope, Settings}, []).

-spec init({TaskModule :: atom(), PgScope :: atom(), Settings :: settings()}) ->
    {ok, State :: state()}.
init({TaskModule, PgScope, Settings}) ->
    ?INFO("starting scheduler", #{
        task_module => TaskModule, pg_scope => PgScope, settings => Settings
    }),
    Interval = get_setting(interval, Settings),
    Timeout = get_setting(timeout, Settings),

    %% Do clean up before termination.
    process_flag(trap_exit, true),

    Tasks = ets:new(TaskModule, [set, public, named_table]),
    {MonitorRef, _} = pg:monitor_scope(PgScope),
    State = #state{
        task_module = TaskModule,
        pg_scope = PgScope,
        monitor_ref = MonitorRef,
        tasks = Tasks,
        interval = Interval,
        timeout = Timeout
    },
    {ok, State}.

get_setting(Key, Settings) ->
    case proplists:is_defined(interval, Settings) of
        true ->
            proplists:get_value(interval, Settings);
        false ->
            error(missing_settings, Key)
    end.

terminate(shutdown, #state{tasks = Tasks, monitor_ref = MonitorRef}) ->
    %% Clear ets table.
    ets:delete_all_objects(Tasks),

    %% Demonitor task scheduler group.
    demonitor(MonitorRef).

pids_to_nodes(Pids) ->
    Nodes = lists:map(fun(P) -> node(P) end, Pids),
    lists:uniq(Nodes).

broadcast([], _) ->
    ok;
broadcast([Pid | Pids], Message) ->
    erlang:send(Pid, Message),
    broadcast(Pids, Message).

broadcast(PgScope, TaskId, Message) ->
    Pids = pg:get_members(PgScope, TaskId),
    broadcast(Pids, Message).

broadcast_remote_nodes([], _, _) ->
    ok;
broadcast_remote_nodes([Node | Nodes], Module, Message) ->
    gen_server:cast({Module, Node}, Message),
    broadcast_remote_nodes(Nodes, Module, Message).

cancel_task(#task{timer_ref = TimerRef, pid = Pid} = Task) ->
    case TimerRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(TimerRef)
    end,
    case Pid of
        undefined ->
            ok;
        _ ->
            erlang:exit(Pid, terminate)
    end,
    Task#task{pid = undefined, timer_ref = undefined}.

schedule_or_cancel(
    TaskModule,
    TaskId,
    #task{
        timer_ref = TimerRef,
        share = #share{last_update = LastUpdate, interval = Interval, priorities = Priorities}
    } = Task
) ->
    LocalNode = node(),
    RunLocal =
        case Priorities of
            [{_, LocalNode} | _] ->
                true;
            _ ->
                false
        end,
    Scheduled = TimerRef =/= undefined,
    if
        RunLocal and not Scheduled ->
            DiffTime = round(timer:now_diff(erlang:timestamp(), LastUpdate) / 1000),
            NewInterval = max(0, Interval - DiffTime),
            ?DEBUG("scheduling task", #{
                task_id => TaskId, task => Task, interval => NewInterval, diff_time => DiffTime
            }),
            NewTimerRef = erlang:send_after(NewInterval, TaskModule, {trigger, TaskId}),
            Task#task{timer_ref = NewTimerRef, pid = undefined};
        not RunLocal and Scheduled ->
            ?DEBUG("cancelling task", #{task_id => TaskId, task => Task, priorities => Priorities}),
            cancel_task(Task);
        true ->
            Task
    end.

merge_shares([Share | []]) ->
    Share#share{priorities = lists:sort(Share#share.priorities)};
merge_shares([Share1 | [Share2 | Shares]]) ->
    Priorities = lists:uniq(lists:merge(Share1#share.priorities, Share2#share.priorities)),
    NewShare =
        if
            Share1#share.last_update >= Share2#share.last_update ->
                Share1#share{priorities = Priorities};
            true ->
                Share2#share{priorities = Priorities}
        end,
    merge_shares([NewShare | Shares]).

-spec handle_call(
    Call :: {schedule, TaskId :: any(), Args :: [any()]} | {unschedule, TaskId :: any()},
    From :: {pid(), any()},
    State :: state()
) -> {reply, ok | {error, Cause :: atom()}, state()}.
handle_call(
    {schedule, TaskId, Args},
    {From, _},
    #state{task_module = TaskModule, tasks = Tasks, interval = Interval} = State
) ->
    erlang:spawn(?MODULE, init_task, [TaskModule, Tasks, TaskId, From, Interval, Args]),
    {reply, ok, State};
handle_call({unschedule, TaskId}, {From, _}, #state{pg_scope = PgScope} = State) ->
    pg:leave(PgScope, TaskId, From),
    {reply, ok, State}.

init_task(TaskModule, Tasks, TaskId, From, Interval, Args) ->
    try
        Task = ets:lookup_element(
            Tasks,
            TaskId,
            2,
            #task{
                share = #share{
                    last_update = erlang:timestamp(),
                    interval = Interval,
                    priorities = [{erlang:timestamp(), node()}]
                }
            }
        ),
        {NewShare, Reschedule} =
            case
                TaskModule:init(
                    TaskId, Args, Task#task.share#share.state, Task#task.share#share.interval
                )
            of
                nochange ->
                    {Task#task.share, false};
                {ok, TaskState} ->
                    {Task#task.share#share{state = TaskState}, false};
                {reschedule, TaskState, TaskInterval} when
                    is_integer(TaskInterval), TaskInterval >= 0
                ->
                    {
                        Task#task.share#share{
                            last_update = erlang:timestamp(),
                            state = TaskState,
                            interval = TaskInterval
                        },
                        true
                    }
            end,
        gen_server:cast(TaskModule, {schedule, TaskId, From, NewShare, Reschedule})
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("failed to init task", Reason, Stacktrace, #{
                task_module => TaskModule, task_id => TaskId, from => From, args => Args
            }),
            erlang:send(From, {error, tasc, init_failed, Reason, TaskId})
    end.

run_task(TaskModule, PgScope, Tasks, TaskId, TaskState) ->
    %% This part runs as a spawned process, callbacks are done via gen_server cast to the scheduler.
    try
        Result = TaskModule:run(TaskId, TaskState),

        %% Cancel timer defined for timeout.
        Task = ets:lookup_element(Tasks, TaskId, 2),
        erlang:cancel_timer(Task#task.timer_ref),
        CancelledTask = Task#task{timer_ref = undefined},

        NewShare =
            case Result of
                {continue, NewTaskState} ->
                    Task#task.share#share{last_update = erlang:timestamp(), state = NewTaskState};
                {continue, Message, NewTaskState} ->
                    broadcast(PgScope, TaskId, Message),
                    Task#task.share#share{last_update = erlang:timestamp(), state = NewTaskState};
                {reschedule, NewTaskState, Interval} when Interval >= 0 ->
                    Task#task.share#share{
                        last_update = erlang:timestamp(), state = NewTaskState, interval = Interval
                    };
                {reschedule, Message, NewTaskState, Interval} when Interval >= 0 ->
                    broadcast(PgScope, TaskId, Message),
                    Task#task.share#share{
                        last_update = erlang:timestamp(), state = NewTaskState, interval = Interval
                    };
                stop ->
                    undefined;
                {stop, Message} ->
                    broadcast(PgScope, TaskId, Message),
                    undefined
            end,
        case NewShare of
            undefined ->
                LeavePids = pg:get_members(PgScope, TaskId),
                pg:leave(PgScope, TaskId, LeavePids);
            _ ->
                NewTask = schedule_or_cancel(TaskModule, TaskId, CancelledTask#task{
                    share = NewShare
                }),
                ets:insert(Tasks, {TaskId, NewTask}),
                Members = pg:get_members(PgScope, TaskId),
                Nodes = pids_to_nodes(Members),
                RemoteNodes = [N || N <- Nodes, N =/= node()],
                broadcast_remote_nodes(RemoteNodes, TaskModule, {sync_share, TaskId, NewShare})
        end
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("failed to run task", Reason, Stacktrace, #{
                task_module => TaskModule, task_id => TaskId
            }),
            ErrorPids = pg:get_members(PgScope, TaskId),
            broadcast(ErrorPids, {error, tasc, run_failed, Reason, TaskId}),
            pg:leave(PgScope, TaskId, ErrorPids)
    end.

-spec handle_info(
    Info ::
        {Ref :: reference(), join | leave, TaskId :: any(), Pids :: [pid()]}
        | {trigger, TaskId :: any()},
    State :: state()
) -> {noreply, state()}.
handle_info({_, join, TaskId, Pids}, #state{task_module = TaskModule, tasks = Tasks} = State) ->
    try
        Task = ets:lookup_element(Tasks, TaskId, 2),
        Nodes = pids_to_nodes(Pids),
        RemoteNodes = [N || N <- Nodes, N =/= node()],
        case RemoteNodes of
            %% Proc joins locally.
            [] ->
                NewTask = schedule_or_cancel(TaskModule, TaskId, Task),
                ets:insert(Tasks, {TaskId, NewTask}),
                ok;
            RemoteNodes ->
                broadcast_remote_nodes(
                    RemoteNodes, TaskModule, {sync_share, TaskId, Task#task.share}
                )
        end
    catch
        error:badarg ->
            ok;
        Class:Reason:StackTrace ->
            ?ERROR("failed to join proc", Class, Reason, StackTrace, #{
                task_id => TaskId, pids => Pids
            })
    end,
    {noreply, State};
handle_info(
    {_, leave, TaskId, Pids},
    #state{task_module = TaskModule, tasks = Tasks, pg_scope = PgScope} = State
) ->
    try
        ?DEBUG("task is leaving a remote node", #{
            task_module => TaskModule, task_id => TaskId, pids => Pids
        }),
        Task = ets:lookup_element(Tasks, TaskId, 2),

        case pg:get_local_members(PgScope, TaskId) of
            [] ->
                ?DEBUG("task is not active on current node, cancelling it", #{
                    task_module => TaskModule,
                    task_id => TaskId,
                    pids => Pids,
                    members => pg:get_members(PgScope, TaskId)
                }),
                [?DEBUG("status of process", #{pid => P, status => process_info(P)}) || P <- Pids],
                cancel_task(Task),
                ets:delete(Tasks, TaskId);
            _ ->
                ?DEBUG("task is still active on current node", #{
                    task_module => TaskModule,
                    task_id => TaskId,
                    pids => Pids,
                    members => pg:get_members(PgScope, TaskId)
                }),
                Members = pg:get_members(PgScope, TaskId),
                Nodes = pids_to_nodes(Members),
                Share = Task#task.share,
                NewPriorities = lists:filter(
                    fun({_, N}) -> lists:member(N, Nodes) end, Share#share.priorities
                ),
                NewTask = schedule_or_cancel(TaskModule, TaskId, Task#task{
                    share = Share#share{priorities = NewPriorities}
                }),
                ets:insert(Tasks, {TaskId, NewTask})
        end
    catch
        error:badarg ->
            ok;
        Class:Reason:StackTrace ->
            ?ERROR("failed to join proc", Class, Reason, StackTrace, #{
                task_id => TaskId, pids => Pids
            })
    end,
    {noreply, State};
handle_info(
    {trigger, TaskId},
    #state{pg_scope = PgScope, tasks = Tasks, task_module = TaskModule, timeout = Timeout} = State
) ->
    try
        Task = ets:lookup_element(Tasks, TaskId, 2),
        ?DEBUG("trigger task", #{task_module => TaskModule, task_id => TaskId}),
        NewPid = erlang:spawn(?MODULE, run_task, [
            TaskModule, PgScope, Tasks, TaskId, Task#task.share#share.state
        ]),
        NewTimerRef = erlang:send_after(Timeout, self(), {reschedule, TaskId}),
        NewTask = Task#task{pid = NewPid, timer_ref = NewTimerRef},
        ets:insert(Tasks, {TaskId, NewTask})
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("failed to trigger task", Class, Reason, Stacktrace, #{
                task_module => TaskModule, task_id => TaskId
            })
    end,
    {noreply, State};
handle_info({reschedule, TaskId}, #state{tasks = Tasks, task_module = TaskModule} = State) ->
    try
        Task = ets:lookup_element(Tasks, TaskId, 2),
        CancelledTask = cancel_task(Task),
        NewTask = schedule_or_cancel(TaskModule, TaskId, CancelledTask),
        ets:insert(Tasks, {TaskId, NewTask})
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("failed to reschedule task", Class, Reason, Stacktrace, #{
                task_module => TaskModule, task_id => TaskId
            })
    end,
    {noreply, State}.

-spec handle_cast(
    {sync_share, TaskId :: any(), Share :: share()}
    | {schedule, TaskId :: any(), Share :: share(), Reschedule :: boolean()},
    State :: state()
) -> {noreply, State :: state()}.
handle_cast({sync_share, TaskId, Share}, #state{tasks = Tasks, task_module = TaskModule} = State) ->
    try
        Task = ets:lookup_element(Tasks, TaskId, 2),
        NewShare = merge_shares([Task#task.share, Share]),
        NewTask = schedule_or_cancel(TaskModule, TaskId, Task#task{share = NewShare}),
        ets:insert(Tasks, {TaskId, NewTask})
    catch
        error:badarg ->
            ok;
        Class:Reason:StackTrace ->
            ?ERROR("failed to sync task", Class, Reason, StackTrace, #{
                task_id => TaskId, share => Share
            })
    end,
    {noreply, State};
handle_cast(
    {schedule, TaskId, From, Share, Reschedule},
    #state{tasks = Tasks, pg_scope = PgScope, task_module = TaskModule} = State
) ->
    try
        LocalMembers = pg:get_local_members(PgScope, TaskId),
        case lists:member(From, LocalMembers) of
            true ->
                erlang:send(From, {error, tasc, already_scheduled, TaskId});
            false ->
                Task = ets:lookup_element(Tasks, TaskId, 2, #task{share = Share}),
                NewTask =
                    case Reschedule of
                        true ->
                            CancelledTask = cancel_task(Task),
                            CancelledTask#task{share = Share};
                        false ->
                            Task#task{share = Share}
                    end,
                ets:insert(Tasks, {TaskId, NewTask}),
                pg:join(PgScope, TaskId, From)
        end
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("failed to schedule task", Class, Reason, Stacktrace, #{
                task_module => TaskModule, task_id => TaskId, from => From, reschedule => Reschedule
            })
    end,
    {noreply, State}.
