-module(tasc).

-include("include/tasc.hrl").

-export([start_scheduler/2, stop_scheduler/1]).
-export([schedule/3, unschedule/2]).

-callback init(
    TaskId :: task_id(),
    Args :: [any()],
    TaskState :: task_state() | undefined,
    Interval :: pos_integer()
) ->
    {ok, TaskState :: task_state()}
    | {reschedule, TaskState :: task_state(), Interval :: pos_integer()}
    | nochange.

-callback run(TaskId :: task_id(), TaskState :: task_state()) ->
    {continue, Message :: any(), TaskState :: task_state()}
    | {continue, TaskState :: task_state()}
    | {reschedule, Message :: any(), TaskState :: task_state(), Interval :: pos_integer()}
    | {reschedule, TaskState :: task_state(), Interval :: pos_integer()}
    | stop
    | {stop, Message :: any()}.

-spec schedule(TaskModule :: module(), TaskId :: task_id(), Args :: [any()]) ->
    ok | {error, Cause :: atom()}.
schedule(TaskModule, TaskId, Args) ->
    gen_server:call(TaskModule, {schedule, TaskId, Args}).

-spec unschedule(TaskModule :: module(), TaskId :: task_id()) ->
    ok | {error, Cause :: atom()}.
unschedule(TaskModule, TaskId) ->
    gen_server:call(TaskModule, {unschedule, TaskId}).

-spec start_scheduler(TaskModule :: module(), Settings :: settings()) -> ok.
start_scheduler(TaskModule, Settings) ->
    ChildrenSpecs = tasc_util:config_to_children_specs({TaskModule, Settings}),
    [{ok, _} = supervisor:start_child(tasc_sup, C) || C <- ChildrenSpecs],
    ok.

-spec stop_scheduler(TaskModule :: module()) -> ok.
stop_scheduler(TaskModule) ->
    Ids = tuple_to_list(tasc_util:proc_ids(TaskModule)),
    [stop_child(I) || I <- Ids],
    ok.

stop_child(Id) ->
    ok = supervisor:terminate_child(tasc_sup, Id),
    supervisor:delete_child(tasc_sup, Id).
