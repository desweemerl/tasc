-module(helper).

-include_lib("stdlib/include/assert.hrl").

-export([configure_logger/0, configure_logger/1]).

-export([assert_receive/2, assert_not_receive/1, assert_sequence/4]).

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

assert_sequence(TaskId, Counter, Size, Timeout) ->
    ok = tasc:schedule(task_mock, TaskId, [Counter]),
    Seq = lists:seq(Counter, Counter + Size),
    [helper:assert_receive(C, Timeout) || C <- Seq],
    ok.
