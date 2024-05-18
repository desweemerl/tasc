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

-module(helper).

-include_lib("stdlib/include/assert.hrl").

-export([configure_logger/0, configure_logger/1]).

-export([assert_receive/2, assert_receive/3, assert_not_receive/1]).

log_config() ->
    Node = atom_to_binary(node()),
    #{
        formatter => {
            logger_formatter, #{
                template => [
                    "[", time, ":", Node, ":", file, ":", line, ":", level, "] ", msg, "\n"
                ]
            }
        }
    }.

log_config(File) ->
    Config = log_config(),
    Config#{config => #{file => File}}.

set_log(Config) ->
    logger:set_primary_config(level, debug),
    logger:add_handler(test_logger, logger_std_h, Config).

configure_logger() ->
    set_log(log_config()).

configure_logger(File) ->
    set_log(log_config(File)).

assert_receive(Expectation, Interval, Timeout) when
    is_integer(Interval), is_integer(Timeout), Interval > 0, Timeout > 0
->
    assert_not_receive(Interval),
    assert_receive(Expectation, Timeout).

assert_receive([], _) ->
    ok;
assert_receive([Expectation | Expectations], [{Interval, Timeout} | IntervalTimeouts]) ->
    case Interval of
        0 ->
            assert_receive(Expectation, Timeout);
        _ ->
            helper:assert_receive(Expectation, Interval, Timeout)
    end,
    case IntervalTimeouts of
        [] ->
            assert_receive(Expectations, [{Interval, Timeout}]);
        _ ->
            assert_receive(Expectations, IntervalTimeouts)
    end;
assert_receive(Expectation, Timeout) when is_integer(Timeout), Timeout > 0 ->
    Time1 = erlang:timestamp(),
    receive
        Expectation ->
            Comment = io:fwrite("received ~p on node ~p", [Expectation, node()]),
            ?assert(true, Comment);
        Message ->
            Comment = io:fwrite("expected ~p received ~p on node ~p", [Expectation, Message, node()]),
            Time2 = erlang:timestamp(),
            DiffTime = round(timer:now_diff(Time2, Time1) / 1000),
            NewTimeout = Timeout - DiffTime,
            if
                NewTimeout =< 0 ->
                    ?assert(false);
                true ->
                    Comment = io:fwrite(
                        "timeout instead of expected ~p on node ~p (time1=~p, time2=~p)", [
                            Expectation, node(), Time1, Time2
                        ]
                    ),
                    assert_receive(Expectation, NewTimeout)
            end
    after Timeout ->
        Time2 = erlang:timestamp(),
        Comment = io:fwrite("timeout instead of expected ~p on node ~p (time1=~p, time2=~p)", [
            Expectation, node(), Time1, Time2
        ]),
        ?assert(false, Comment)
    end.

assert_not_receive(Timeout) when is_integer(Timeout), Timeout > 0 ->
    receive
        Msg ->
            Comment = io:fwrite("received message ~p instead of none on node ~p", [Msg, node()]),
            ?assert(false, Comment)
    after Timeout ->
        ok
    end.
