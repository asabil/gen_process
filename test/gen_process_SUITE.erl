-module(gen_process_SUITE).

-include_lib("common_test/include/ct.hrl").

%% ct
-export([
	all/0,
	groups/0,
	init_per_suite/1,
	end_per_suite/1,
	init_per_group/2,
	end_per_group/2
]).

%% tests
-export([
	start_anonymous/1,
	start_local/1,
	start_global/1
]).

% The gen_process behaviour
-export([
	init/1,
	process/1,
	terminate/2,
	format_status/2
]).


all() ->
	[start_anonymous, start_local, start_global].

groups() ->
	[].

init_per_suite(Config) ->
	Config.

end_per_suite(_Config) ->
	ok.

init_per_group(_GroupName, Config) ->
	Config.

end_per_group(_GroupName, Config) ->
	Config.


start_anonymous(Config) when is_list(Config) ->
	OldFlags = process_flag(trap_exit, true),

	%% normal
	{ok, Pid0} = gen_process:start(?MODULE, [], []),
	pong = gen_process:call(Pid0, ping),
	ok = gen_process:call(Pid0, stop),
	wait_for_process(Pid0),
	{'EXIT', {noproc, _}} = (catch gen_process:call(Pid0, ping, 1)),

	%% timeout
	{ok, Pid00} = gen_process:start(?MODULE, [], [{timeout, 1000}]),
	pong = gen_process:call(Pid00, ping),
	ok = gen_process:call(Pid00, stop),
	{error, timeout} = gen_process:start(?MODULE, sleep, [{timeout,100}]),

	%% ignore
	ignore = gen_process:start(?MODULE, ignore, []),

	%% stop
	{error, stopped} = gen_process:start(?MODULE, stop, []),

    %% linked
	{ok, Pid1} = gen_process:start_link(?MODULE, [], []),
	pong = gen_process:call(Pid1, ping),
	ok = gen_process:call(Pid1, stop),
	receive
		{'EXIT', Pid1, stopped} -> ok
	after 5000 ->
		test_server:fail(not_stopped)
	end,

	process_flag(trap_exit, OldFlags),
	ok.

start_local(Config) when is_list(Config) ->
	OldFlags = process_flag(trap_exit, true),

	%% local register
	{ok, Pid2} = gen_process:start({local, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call(my_test_name, ping),
	{error, {already_started, Pid2}} = gen_process:start({local, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call(my_test_name, stop),
	wait_for_process(Pid2),
	{'EXIT', {noproc,_}} = (catch gen_process:call(Pid2, started_p, 10)),

	%% local register linked
	{ok, Pid3} = gen_process:start_link({local, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call(my_test_name, ping),
	{error, {already_started, Pid3}} = gen_process:start({local, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call(my_test_name, stop),
	receive
		{'EXIT', Pid3, stopped} -> ok
	after 5000 ->
			test_server:fail(not_stopped)
	end,

	process_flag(trap_exit, OldFlags),
	ok.

start_global(Config) when is_list(Config) ->
	OldFlags = process_flag(trap_exit, true),

	%% global register
	{ok, Pid2} = gen_process:start({global, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call({global, my_test_name}, ping),
	{error, {already_started, Pid2}} = gen_process:start({global, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call({global, my_test_name}, stop),
	wait_for_process(Pid2),
	{'EXIT', {noproc,_}} = (catch gen_process:call(Pid2, started_p, 10)),

	%% global register linked
	{ok, Pid3} = gen_process:start_link({global, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call({global, my_test_name}, ping),
	{error, {already_started, Pid3}} = gen_process:start({global, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call({global, my_test_name}, stop),
	receive
		{'EXIT', Pid3, stopped} -> ok
	after 5000 ->
			test_server:fail(not_stopped)
	end,

	process_flag(trap_exit, OldFlags),
	ok.



wait_for_process(Pid) ->
	case erlang:is_process_alive(Pid) of
		true ->
			timer:sleep(100),
			wait_for_process(Pid);
		_ ->
			ok
	end.

%%% --------------------------------------------------------
%%% Here is the tested gen_process behaviour.
%%% --------------------------------------------------------
init([]) ->
	{ok, []};
init(ignore) ->
	ignore;
init(stop) ->
	{stop, stopped};
init(sleep) ->
	test_server:sleep(1000),
	{ok, []};
init({state,State}) ->
	{ok, State}.

process(State) ->
	receive
		{'$call', From, ping} = Message ->
			gen_process:reply(From, pong),
			{continue, Message, State};
		{'$call', From, stop} = Message ->
			gen_process:reply(From, ok),
			{stop, stopped, Message, State};
		{'$call', From, {stop, Reason}} = Message ->
			gen_process:reply(From, ok),
			{stop, Reason, Message, State};
		Message ->
			{continue, Message, State}
	end.

terminate({From, stopped}, _State) ->
	io:format("FOOBAR"),
	From ! {self(), stopped},
	ok;
terminate({From, stopped_info}, _State) ->
	From ! {self(), stopped_info},
	ok;
terminate(_Reason, _State) ->
	ok.

format_status(terminate, [_PDict, State]) ->
	State;
format_status(normal, [_PDict, _State]) ->
	format_status_called.
