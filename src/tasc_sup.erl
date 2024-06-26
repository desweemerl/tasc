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

-module(tasc_sup).

-behaviour(supervisor).

-include("include/tasc.hrl").

-export([start_link/1]).
-export([init/1]).

-spec init(Config :: config()) ->
    {ok, {{supervisor:strategy(), 10, 10}, [supervisor:child_spec()]}}.
init(Config) ->
    ChildrenSpecs = tasc_util:config_to_children_specs(Config),
    {ok, {{one_for_one, 10, 10}, ChildrenSpecs}}.

-spec start_link(Config :: config()) -> {ok, pid()}.
start_link(Config) when is_list(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).
