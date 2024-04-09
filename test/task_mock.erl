-module(task_mock).

-include("include/tasc.hrl").

-behaviour(tasc).

-export([
    init/4,
    run/2
]).

init(TaskId, [], TaskState, TaskInterval) ->
    init(TaskId, [0], TaskState, TaskInterval);
init(_TaskId, [Counter], undefined, _TaskInterval) ->
    {ok, #{counter => Counter}};
init(_TaskId, [_Counter], TaskState, _TaskInterval) ->
    {ok, TaskState}.

run(_TaskId, #{counter := Counter}) ->
    {continue, Counter, #{counter => Counter + 1}}.
