gen_process
===========

A behaviour module for implementing a process able to consume messages. A generic process (gen_process) implemented using this module will have a standard set of interface functions and include functionality for tracing and error reporting. It will also fit into an OTP supervision tree. Refer to OTP Design Principles for more information.

Goals
-----

gen_process was created to be a low level behaviour complementing the *gen_server* and *gen_fsm* behaviours provided by OTP.

Example
-------
This is an example module for a rate limiter that will call a function at maximum ```Count``` number of times per ```Window``` milliseconds.

```erlang
-module(rate_limiter).
-export([
  start_link/3,
	call/2
]).

-behaviour(gen_process).
-export([
	init/1,
	process/1,
	terminate/2,
	code_change/3
]).

-record(state, {
	window  :: pos_integer(),
	tokens  :: pos_integer(),
	func    :: fun()
}).

-spec start_link(pos_integer(), pos_integer(), fun()) -> {ok, pid()}.
start_link(Window, Count, Fun) ->
	gen_process:start_link(?MODULE, [Window, Count, Fun], []).

-spec call(pid(),list()) -> any().
call(Limiter, Args) ->
	gen_process:call(Limiter, Args, infinity).

%% @hidden
init([Window, Count, Fun]) ->
	erlang:send_after(Window, self(), {refill, Count}),
	{ok, #state{window = Window, tokens = Count, func = Fun}}.

%% @hidden
process(#state{window = Window, tokens = 0} = State) ->
	%% No more tokens, we need to wait for a refill
	receive
		{refill, Count} = Message ->
			erlang:send_after(Window, self(), {refill, Count}),
			{continue, Message, State#state{tokens = Count}};
		{Type, _, _} = Message when Type =:= system; Type =:= 'EXIT' ->
			{continue, Message, State}
	end;
process(#state{window = Window, tokens = Tokens, func = Fun} = State) ->
	receive
		{'$call', From, Args} = Message ->
			gen_process:reply(From, erlang:apply(Fun, Args)),
			{continue, Message, State#state{tokens = Tokens - 1}};
		{refill, Count} = Message ->
			erlang:send_after(Window, self(), {refill, Count}),
			{continue, Message, State#state{tokens = Count}};
		{Type, _, _} = Message when Type =:= system; Type =:= 'EXIT' ->
			{continue, Message, State}
	end.

%% @hidden
terminate(_Reason, _State) ->
	ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
```
