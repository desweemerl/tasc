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

-module(tasc_util).

-include("include/tasc.hrl").

-export([proc_ids/1, config_to_children_specs/1]).

-spec proc_ids(TaskModule :: atom()) -> {PgScopeId :: atom(), SchedulerId :: atom()}.
proc_ids(TaskModule) ->
    PgScope = format_module(TaskModule, pg),
    Scheduler = format_module(TaskModule, scheduler),
    {PgScope, Scheduler}.

-spec config_to_children_specs([config()] | {TaskModule :: module(), Settings :: settings()}) -> [supervisor:child_spec()].
config_to_children_specs([]) ->
    [];
config_to_children_specs([Config | Configs]) ->
    config_to_children_specs(Config) ++ config_to_children_specs(Configs);
config_to_children_specs({TaskModule, Settings}) when is_atom(TaskModule), is_list(Settings) ->
    {PgScope, Scheduler} = proc_ids(TaskModule),
    [
        #{id => PgScope, start => {pg, start_link, [PgScope]}},
        #{id => Scheduler, start => {tasc_scheduler, start_link, [TaskModule, PgScope, Settings]}}
    ];
config_to_children_specs(_) ->
    error(bad_configuration).

format_module(Module, Suffix) ->
    FormattedModule = io_lib:format("~s_~s", [Module, Suffix]),
    Binary = list_to_binary(FormattedModule),
    binary_to_atom(Binary).
