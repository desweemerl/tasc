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

-module(tasc).

-include("include/tasc.hrl").

-export([start_scheduler/2, stop_scheduler/1]).
-export([schedule/3, unschedule/2]).
-export([metrics/1]).

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

count_tasks(TaskModule) ->
    case ets:info(TaskModule) of
        undefined ->
            error(not_found);
        Info ->
            proplists:get_value(size, Info)
    end.

proc_info(TaskModule) ->
    case whereis(TaskModule) of
        undefined ->
            error(not_found);
        Pid ->
            Info = process_info(Pid),
            #{
                pid => Pid,
                message_queue_len => proplists:get_value(message_queue_len, Info)
            }
    end.

-spec metrics(TaskModule :: module()) -> {ok, map()} | {error, not_found}.
metrics(TaskModule) ->
    try
        ProcInfo = proc_info(TaskModule),
        Count = count_tasks(TaskModule),
        {ok, maps:put(count, Count, ProcInfo)}
    catch
        error:not_found ->
            {error, not_found};
        Class:Reason:StackTrace ->
            ?ERROR("failed to collect metrics", Class, Reason, StackTrace, #{
                task_module => TaskModule
            }),
            {error, Reason}
    end.
