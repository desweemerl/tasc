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

-module(task_mock).

-include("include/tasc.hrl").

-behaviour(tasc).

-export([
    init/4,
    run/2
]).

-record(state, {
    counter :: pos_integer(),
    action :: message | undefined,
    last_counter :: pos_integer() | undefined,
    last_action :: stop | stop_message | undefined,
    intervals = [] :: [pos_integer()]
}).

init(TaskId, [], TaskState, TaskInterval) ->
    init(TaskId, [0, message, undefined, undefined, undefined], TaskState, TaskInterval);
init(TaskId, [Counter], TaskState, TaskInterval) ->
    init(TaskId, [Counter, message, undefined, undefined, []], TaskState, TaskInterval);
init(_, [Counter, Action, LastCounter, LastAction, Intervals], undefined, _) ->
    TaskState = #state{
        counter = Counter,
        action = Action,
        last_counter = LastCounter,
        last_action = LastAction,
        intervals = Intervals
    },
    {ok, TaskState};
init(_, _, TaskState, _) ->
    {ok, TaskState}.

run(
    _TaskId,
    #state{
        counter = Counter,
        action = Action,
        last_counter = LastCounter,
        last_action = LastAction,
        intervals = Intervals
    } = TaskState
) ->
    if
        (LastCounter =:= Counter) and (LastAction =/= undefined) ->
            case LastAction of
                stop ->
                    stop;
                stop_message ->
                    {stop, {stop, Counter}}
            end;
        true ->
            case Intervals of
                [] ->
                    NewTaskState = TaskState#state{counter = Counter + 1},
                    case Action of
                        message ->
                            {continue, Counter, NewTaskState};
                        _ ->
                            {continue, NewTaskState}
                    end;
                [Interval | Tail] ->
                    NewTaskState = TaskState#state{counter = Counter + 1, intervals = Tail},
                    case Action of
                        message ->
                            {reschedule, Counter, NewTaskState, Interval};
                        _ ->
                            {reschedule, NewTaskState, Interval}
                    end
            end
    end.
