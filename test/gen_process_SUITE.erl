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
	start_global/1,
	crash/1,
	hibernate/1,
	sys_state/1
]).

% The gen_process behaviour
-export([
	init/1,
	process/1,
	terminate/2,
	format_status/2
]).


all() ->
	[start_anonymous, start_local, start_global, crash, hibernate, sys_state].

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
	ok = gen_process:call(Pid0, {stop, stopped}),
	wait_for_process(Pid0),
	{'EXIT', {noproc, _}} = (catch gen_process:call(Pid0, ping, 1)),

	%% timeout
	{ok, Pid00} = gen_process:start(?MODULE, [], [{timeout, 1000}]),
	pong = gen_process:call(Pid00, ping),
	ok = gen_process:call(Pid00, {stop, stopped}),
	{error, timeout} = gen_process:start(?MODULE, sleep, [{timeout,100}]),

	%% ignore
	ignore = gen_process:start(?MODULE, ignore, []),

	%% stop
	{error, stopped} = gen_process:start(?MODULE, stop, []),

    %% linked
	{ok, Pid1} = gen_process:start_link(?MODULE, [], []),
	pong = gen_process:call(Pid1, ping),
	ok = gen_process:call(Pid1, {stop, stopped}),
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
	ok = gen_process:call(my_test_name, {stop, stopped}),
	wait_for_process(Pid2),
	{'EXIT', {noproc,_}} = (catch gen_process:call(Pid2, started_p, 10)),

	%% local register linked
	{ok, Pid3} = gen_process:start_link({local, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call(my_test_name, ping),
	{error, {already_started, Pid3}} = gen_process:start({local, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call(my_test_name, {stop, stopped}),
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
	ok = gen_process:call({global, my_test_name}, {stop, stopped}),
	wait_for_process(Pid2),
	{'EXIT', {noproc,_}} = (catch gen_process:call(Pid2, started_p, 10)),

	%% global register linked
	{ok, Pid3} = gen_process:start_link({global, my_test_name}, ?MODULE, [], []),
	pong = gen_process:call({global, my_test_name}, ping),
	{error, {already_started, Pid3}} = gen_process:start({global, my_test_name}, ?MODULE, [], []),
	ok = gen_process:call({global, my_test_name}, {stop, stopped}),
	receive
		{'EXIT', Pid3, stopped} -> ok
	after 5000 ->
			test_server:fail(not_stopped)
	end,

	process_flag(trap_exit, OldFlags),
	ok.


crash(Config) when is_list(Config) ->
	error_logger_forwarder:register(),

	process_flag(trap_exit, true),

	%% This crash should not generate a crash report.
	{ok, Pid0} = gen_process:start_link(?MODULE, [], []),
	{'EXIT', {{shutdown, reason}, _}} = (catch gen_process:call(Pid0, {exit, {shutdown, reason}})),
	receive {'EXIT', Pid0, {shutdown, reason}} -> ok end,

	%% This crash should not generate a crash report.
	{ok, Pid1} = gen_process:start_link(?MODULE, {state, state1}, []),
	{'EXIT', {{shutdown, reason}, _}} = (catch gen_process:call(Pid1, {stop_noreply, {shutdown, reason}})),
	receive {'EXIT', Pid1, {shutdown, reason}} -> ok end,

	%% This crash should not generate a crash report.
	{ok, Pid2} = gen_process:start_link(?MODULE, [], []),
	{'EXIT', {shutdown, _}} = (catch gen_process:call(Pid2, {exit, shutdown})),
	receive {'EXIT', Pid2, shutdown} -> ok end,

	%% This crash should not generate a crash report.
	{ok, Pid3} = gen_process:start_link(?MODULE, {state, state3}, []),
	{'EXIT', {shutdown, _}} = (catch gen_process:call(Pid3, {stop_noreply, shutdown})),
	receive {'EXIT', Pid3, shutdown} -> ok end,

	process_flag(trap_exit, false),

	%%%% This crash should generate a crash report and a report
	%%%% from gen_process.
	{ok, Pid4} = gen_process:start(?MODULE, {state, state4}, []),
	{'EXIT', {crashed, _}} = (catch gen_process:call(Pid4, {exit, crashed})),
	receive
		{error, _GroupLeader4, {Pid4, "** Generic process" ++ _, [Pid4, [], state4, crashed]}} ->
			ok;
		Other4a ->
			io:format("Unexpected: ~p", [Other4a]),
			test_server:fail()
	end,
	receive
		{error_report, _, {Pid4, crash_report, [List4|_]}} ->
			{exit,crashed,_} = proplists:get_value(error_info, List4),
			Pid4 = proplists:get_value(pid, List4);
		Other4 ->
			io:format("Unexpected: ~p", [Other4]),
			test_server:fail()
	end,
	receive
		Any ->
			io:format("Unexpected: ~p", [Any]),
			test_server:fail()
	after 500 ->
			ok
	end,
	ok.

hibernate(Config) when is_list(Config) ->
	OldFlags = process_flag(trap_exit, true),

	{ok, Pid} = gen_process:start_link({local, gen_process_hibernate}, ?MODULE, [], []),

	pong = gen_process:call(gen_process_hibernate, ping),
	ok = gen_process:call(gen_process_hibernate, hibernate),
	timer:sleep(100),
	{current_function, {erlang, hibernate, 3}} = erlang:process_info(Pid, current_function),
	Parent = self(),
	Fun = fun() ->
			receive
				go ->
					ok
			end,
			timer:sleep(100),
			X = erlang:process_info(Pid, current_function),
			Pid ! {reply, ok},
			Parent ! {result, X}
	end,
	Pid2 = spawn_link(Fun),
	ok = gen_process:call(gen_process_hibernate, {hibernate_noreply, Pid2}),
	receive
		{result, R} ->
			{current_function, {erlang, hibernate, 3}} = R
	end,
	ok = gen_process:call(gen_process_hibernate, hibernate),
	timer:sleep(100),
	{current_function, {erlang, hibernate, 3}} = erlang:process_info(Pid, current_function),
	sys:suspend(gen_process_hibernate),
	timer:sleep(100),
	{current_function,{erlang, hibernate, 3}} = erlang:process_info(Pid, current_function),
	sys:resume(gen_process_hibernate),
	timer:sleep(100),
	{current_function, {erlang, hibernate, 3}} = erlang:process_info(Pid, current_function),
	pong = gen_process:call(gen_process_hibernate, ping),
	true = ({current_function, {erlang, hibernate, 3}} =/= erlang:process_info(Pid, current_function)),

	ok = gen_process:call(gen_process_hibernate, {stop, stopped}),
	receive
		{'EXIT', Pid, stopped} -> ok
	after
		5000 -> test_server:fail(gen_process_did_not_die)
	end,
	process_flag(trap_exit, OldFlags),
	ok.

sys_state(_) ->
	case erlang:function_exported(sys, get_state, 1) of
		false ->
			{skip, {not_exported, {sys, get_state, 1}}};
		true ->
			{ok, Pid} = gen_process:start(?MODULE, [], []),
			%% will hibernate after receiving sys message.
			[] = sys:get_state(Pid),
			%% will hibernate after receiving sys message.
			new_state = sys:replace_state(Pid, fun(_) -> new_state end),
			%% will NOT hibernate after receiving sys message.
			new_state = sys:get_state(Pid),
			%% will NOT hibernate after receiving sys message.
			new_state = sys:replace_state(Pid, fun(_) -> error(failed) end),
			%% will NOT hibernate after receiving sys message.
			newer_state = sys:replace_state(Pid, fun(_) -> newer_state end),
			%% will hibernate after receiving sys message.
			newer_state = sys:replace_state(Pid, fun(_) -> error(failed) end),
			pong = gen_process:call(Pid, ping),
			ok = gen_process:call(Pid, {stop, stopped}),
			wait_for_process(Pid),
			ok
	end.

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
		{'$call', From, {stop, Reason}} = Message ->
			gen_process:reply(From, ok),
			{stop, Reason, Message, State};
		{'$call', _From, {exit, Reason}} = _Message ->
			exit(Reason);
		{'$call', _From, {stop_noreply, Reason}} = Message ->
			{stop, Reason, Message, State};
		{'$call', From, hibernate} = Message ->
			gen_process:reply(From, ok),
			{hibernate, Message, State};
		{'$call', From, {hibernate_noreply, Pid}} = Message ->
			Pid ! go,
			{hibernate, Message, From};
		{reply, Reply} = Message ->
			gen_process:reply(State, Reply),
			{continue, Message, []};
		{system, _, _} = Message when State =:= new_state ->
			{continue, Message, State};
		{system, _, _} = Message ->
			{hibernate, Message, State};
		Message ->
			{continue, Message, State}
	end.

terminate({From, stopped}, _State) ->
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
