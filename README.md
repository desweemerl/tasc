# tasc (Task Scheduler)

![Build Status](https://github.com/desweemerl/tasc/actions/workflows/build-test.yml/badge.svg)

Copyright(c) 2024 Ludovic Desweemer

**Version:** 0.1.0

## tasc

**tasc** is a task scheduler for Erlang/OTP.
 
## Goal

**tasc** manages task scheduling, either on a single or multiples nodes.

## Configuration

A task callback module must be implemented with functions **init** and **run**:

```erlang
-module(my_task).
-behaviour(tasc).
-export([init/4, run/2]).

init(_TaskId, _Args, undefined, _Interval) ->
	TaskState = #{counter => 0},
	{ok, TaskState};
init(_TaskId, _Args, _TaskState, _Interval) ->
	nochange.

run(_TaskId, TaskState) ->
	#{counter => Counter} = TaskState,
	{continue, Counter, #{counter => Counter + 1}).
```

Run the **tasc** application:  

```erlang
application:ensure_all(tasc).
```
A task scheduler must be configured before scheduling a task. It can be done:

By configuring **tasc** in the application resource file:
 ```erlang
{env, [
	{tasc, [{my_task, [{interval, 1000}, {timeout, 30000}]]}
]}
 ```
Interval and timeout are expressed in milliseconds.

Or by starting directly a scheduler:
```erlang
Settings = [{interval, 1000}, {timeout, 30000}],
Module = my_task,
tasc:start_scheduler(Module, Settings).
```
## Scheduling

Scheduling is done via:
```erlang
Arg1 = 0,
Arg2 = 1,
task:schedule(my_task, task_id, [Arg1, Arg2]).
```
The callback function **init** is called. The state is *undefined* when the task was never initialized. The callback must return:
```erlang
{ok, NewState}.
```
The interval can also be modified by returning:
```erlang
{reschedule, NewState, NewInterval}.
```
Of if the state and the interval don't change:
```erlang
nochange.
```
Scheduling can be done multiple times with the same task/task id but NOT from the same process.
**init** will be called with the state/interval that you previously provided.

## Running the task

After a delay specified by the task interval, the callback function **run** is triggered.
To send a message back to the processes that initiated the scheduling and update the task:
```erlang
{continue, Message, NewTaskState}.
```
To continue the task without sending any messages:
```erlang
{continue, NewTaskState}.
```
To change both the state and the interval for next scheduling, and also send a message back to the processes that scheduled the task:
```erlang
{reschedule, Message, NewTaskState, NewInterval}.
```
To reschedule the task without sending any messages:
```erlang
{reschedule, NewTaskState, NewInterval}.
```
To stop further scheduling and send message:
```erlang
{stop, Message}.
```
To stop scheduling without sending any messages:
```erlang
stop.
```
## Scheduling on multiple nodes

When a task with the same module/task id is configured and scheduled on multiple nodes, a priority list is created from the initialization time on the node.
The task will be only executed on the node where the task was first initiated. Messages will be broadcast on local and remote processes.
If the node in charge of running the task goes down, the task will be automatically executed on the next node of the priority list.


