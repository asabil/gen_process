-module(gen_process).
-export([
	start/3,
	start/4,
	start_link/3,
	start_link/4,
	call/2,
	call/3,
	reply/2,
	enter_loop/3,
	enter_loop/4
]).

%% System exports
-export([
	system_continue/3,
	system_terminate/4,
	system_code_change/4,
	format_status/2,
	loop/5
]).

%% Internal exports
-export([init_it/6]).

-ifndef(no_callbacks).
-callback init(Args :: term()) ->
	{ok, StateData :: term()} |
	{stop, Reason :: term()} |
	ignore.
-callback process(StateData :: term()) ->
	{continue, Message :: term(), NewStateData :: term()} |
	{stop, Reason :: term(), Message :: term(), NewStateData :: term()}.
-callback terminate(Reason :: normal | shutdown | {shutdown, term()} | term(), StateData :: term()) ->
	term().
-callback code_change(OldVsn :: term() | {down, term()}, StateData :: term(), Extra :: term()) ->
	{ok, NewStateData :: term()}.
-else.
-export([behaviour_info/1]).
-spec behaviour_info(_) -> undefined | [{atom(), non_neg_integer()}].
behaviour_info(callbacks) ->
	[{init, 1}, {process, 1}, {terminate, 2}, {code_change, 3}];
behaviour_info(_Other) ->
	undefined.
-endif.


start(Mod, Args, Options) ->
	gen:start(?MODULE, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
	gen:start(?MODULE, nolink, Name, Mod, Args, Options).

start_link(Mod, Args, Options) ->
	gen:start(?MODULE, link, Mod, Args, Options).

start_link(Name, Mod, Args, Options) ->
	gen:start(?MODULE, link, Name, Mod, Args, Options).


call(Name, Request) ->
	case catch gen:call(Name, '$call', Request) of
		{ok, Res} -> Res;
		{'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request]}})
	end.

call(Name, Request, Timeout) ->
	case catch gen:call(Name, '$call', Request, Timeout) of
		{ok, Res} -> Res;
		{'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
	end.


reply({To, Tag}, Reply) ->
	catch To ! {Tag, Reply}.

enter_loop(Callback, Options, CallbackState) ->
	enter_loop(Callback, Options, CallbackState, self()).

enter_loop(Callback, Options, CallbackState, Name0) ->
	Name = get_proc_name(Name0),
	Parent = get_parent(),
	Debug = debug_options(Name, Options),
	loop(Parent, Name, Callback, CallbackState, Debug).

%%%========================================================================
%%% Gen-callback functions
%%%========================================================================

%% @hidden
init_it(Starter, self, Name, Callback, CallbackArgs, Options) ->
	init_it(Starter, self(), Name, Callback, CallbackArgs, Options);
init_it(Starter, Parent, Name0, Callback, CallbackArgs, Options) ->
	Name = name(Name0),
	Debug = gen:debug_options(Options),
	case catch Callback:init(CallbackArgs) of
		{ok, CallbackState} ->
			proc_lib:init_ack(Starter, {ok, self()}),
			loop(Parent, Name, Callback, CallbackState, Debug);
		{stop, Reason} ->
			%% For consistency, we must make sure that the
			%% registered name (if any) is unregistered before
			%% the parent process is notified about the failure.
			%% (Otherwise, the parent process could get
			%% an 'already_started' error if it immediately
			%% tried starting the process again.)
			unregister_name(Name0),
			proc_lib:init_ack(Starter, {error, Reason}),
			exit(Reason);
		ignore ->
			unregister_name(Name0),
			proc_lib:init_ack(Starter, ignore),
			exit(normal);
		{'EXIT', Reason} ->
			unregister_name(Name0),
			proc_lib:init_ack(Starter, {error, Reason}),
			exit(Reason);
		Else ->
			Error = {bad_return_value, Else},
			proc_lib:init_ack(Starter, {error, Error}),
			exit(Error)
	end.

%% @private
name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

%% @private
unregister_name({local,Name}) ->
	_ = (catch unregister(Name));
unregister_name({global,Name}) ->
	_ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
	_ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
	Pid.


%%%========================================================================
%%% Internal functions
%%%========================================================================
%%% ---------------------------------------------------
%%% The MAIN loop.
%%% ---------------------------------------------------
loop(Parent, Name, Callback, CallbackState, Debug) ->
	case catch Callback:process(CallbackState) of
		{continue, Message, NewCallbackState} ->
			case Message of
				{system, From, Request} ->
					sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, {loop, Name, Callback, NewCallbackState}, false);
				{'EXIT', Parent, Reason} ->
					terminate(Reason, Name, Message, Callback, NewCallbackState, Debug);
				_ when Debug =:= [] ->
					loop(Parent, Name, Callback, NewCallbackState, Debug);
				_ ->
					NewDebug = sys:handle_debug(Debug, fun print_event/3, Name, {in, Message}),
					loop(Parent, Name, Callback, NewCallbackState, NewDebug)
			end;
		{hibernate, Message, NewCallbackState} ->
			case Message of
				{system, From, Request} ->
					sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, {hibernate, Name, Callback, NewCallbackState}, true);
				{'EXIT', Parent, Reason} ->
					terminate(Reason, Name, Message, Callback, NewCallbackState, Debug);
				_ when Debug =:= [] ->
					proc_lib:hibernate(?MODULE, loop, [Parent, Name, Callback, NewCallbackState, Debug]);
				_ ->
					NewDebug = sys:handle_debug(Debug, fun print_event/3, Name, {in, Message}),
					proc_lib:hibernate(?MODULE, loop, [Parent, Name, Callback, NewCallbackState, NewDebug])
			end;
		{hibernate, NewCallbackState} ->
			proc_lib:hibernate(?MODULE, loop, [Parent, Name, Callback, NewCallbackState, Debug]);
		{stop, Reason, Message, NewCallbackState} ->
			NewDebug = sys:handle_debug(Debug, fun print_event/3, Name, {in, Message}),
			terminate(Reason, Name, Message, Callback, NewCallbackState, NewDebug);
		{'EXIT', Reason} ->
			terminate(Reason, Name, [], Callback, CallbackState, Debug)
	end.

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(Parent, Debug, {loop, Name, Callback, CallbackState}) ->
	loop(Parent, Name, Callback, CallbackState, Debug);
system_continue(Parent, Debug, {hibernate, Name, Callback, CallbackState}) ->
	proc_lib:hibernate(?MODULE, loop, [Parent, Name, Callback, CallbackState, Debug]).

-spec system_terminate(_, _, _, {loop | hibernate, _, _, _}) -> no_return().
system_terminate(Reason, _Parent, Debug, {_, Name, Callback, CallbackState}) ->
	terminate(Reason, Name, [], Callback, CallbackState, Debug).

system_code_change({Continue, Name, Callback, CallbackState}, _Module, OldVsn, Extra) ->
	case catch Callback:code_change(OldVsn, CallbackState, Extra) of
		{ok, NewCallbackState} -> {ok, {Continue, Name, Callback, NewCallbackState}};
		Else -> Else
	end.

%%-----------------------------------------------------------------
%% Format debug messages.  Print them as the call-back module sees
%% them, not as the real erlang messages.  Use trace for that.
%%-----------------------------------------------------------------
print_event(Dev, {in, Msg}, Name) ->
	case Msg of
		{'$gen_call', {From, _Tag}, Call} ->
			io:format(Dev, "*DBG* ~p got call ~p from ~w~n", [Name, Call, From]);
		{'$gen_cast', Cast} ->
			io:format(Dev, "*DBG* ~p got cast ~p~n", [Name, Cast]);
		_ ->
			io:format(Dev, "*DBG* ~p got ~p~n", [Name, Msg])
	end;
print_event(Dev, {out, Msg, To, State}, Name) ->
	io:format(Dev, "*DBG* ~p sent ~p to ~w, new state ~w~n", [Name, Msg, To, State]);
print_event(Dev, Event, Name) ->
	io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).

%%% ---------------------------------------------------
%%% Terminate the server.
%%% ---------------------------------------------------
-spec terminate(_, _, _, module(), _, _) -> no_return().
terminate(Reason, Name, Message, Callback, State, Debug) ->
	case catch Callback:terminate(Reason, State) of
		{'EXIT', R} ->
			error_info(R, Name, Message, State, Debug),
			exit(R);
		_ ->
			case Reason of
				normal ->
					exit(normal);
				shutdown ->
					exit(shutdown);
				{shutdown,_}=Shutdown ->
					exit(Shutdown);
				_ ->
					FmtState =
					case erlang:function_exported(Callback, format_status, 2) of
						true ->
							case catch Callback:format_status(terminate, [get(), State]) of
								{'EXIT', _} -> State;
								Else -> Else
							end;
						_ ->
							State
					end,
					error_info(Reason, Name, Message, FmtState, Debug),
					exit(Reason)
			end
	end.

error_info(Reason, Name, Msg, State, Debug) ->
	Reason1 =
	case Reason of
		{undef,[{M,F,A,L}|MFAs]} ->
			case code:is_loaded(M) of
				false ->
					{'module could not be loaded',[{M,F,A,L}|MFAs]};
				_ ->
					case erlang:function_exported(M, F, length(A)) of
						true ->
							Reason;
						false ->
							{'function not exported',[{M,F,A,L}|MFAs]}
					end
			end;
		_ ->
			Reason
	end,
	error_logger:format("** Generic process ~p terminating \n"
		"** Last message in was ~p~n"
		"** When Server state == ~p~n"
		"** Reason for termination == ~n** ~p~n",
		[Name, Msg, State, Reason1]),
	sys:print_log(Debug),
	ok.

%%% ---------------------------------------------------
%%% Misc. functions.
%%% ---------------------------------------------------

opt(Op, [{Op, Value}|_]) ->
	{ok, Value};
opt(Op, [_|Options]) ->
	opt(Op, Options);
opt(_, []) ->
	false.

debug_options(Name, Opts) ->
	case opt(debug, Opts) of
		{ok, Options} -> dbg_options(Name, Options);
		_ -> dbg_options(Name, [])
	end.

dbg_options(Name, []) ->
	Opts =
	case init:get_argument(generic_debug) of
		error ->
			[];
		_ ->
			[log, statistics]
	end,
	dbg_opts(Name, Opts);
dbg_options(Name, Opts) ->
	dbg_opts(Name, Opts).

dbg_opts(Name, Opts) ->
	case catch sys:debug_options(Opts) of
		{'EXIT',_} ->
			error_logger:format("~p: ignoring erroneous debug options - ~p~n", [Name, Opts]),
			[];
		Dbg ->
			Dbg
	end.

get_proc_name(Pid) when is_pid(Pid) ->
	Pid;
get_proc_name({local, Name}) ->
	case process_info(self(), registered_name) of
		{registered_name, Name} ->
			Name;
		{registered_name, _Name} ->
			exit(process_not_registered);
		[] ->
			exit(process_not_registered)
	end;
get_proc_name({global, Name}) ->
	case global:whereis_name(Name) of
		undefined ->
			exit(process_not_registered_globally);
		Pid when Pid =:= self() ->
			Name;
		_Pid ->
			exit(process_not_registered_globally)
	end;
get_proc_name({via, Mod, Name}) ->
	case Mod:whereis_name(Name) of
		undefined ->
			exit({process_not_registered_via, Mod});
		Pid when Pid =:= self() ->
			Name;
		_Pid ->
			exit({process_not_registered_via, Mod})
	end.

get_parent() ->
	case get('$ancestors') of
		[Parent | _] when is_pid(Parent)->
			Parent;
		[Parent | _] when is_atom(Parent)->
			name_to_pid(Parent);
		_ ->
			exit(process_was_not_started_by_proc_lib)
	end.

name_to_pid(Name) ->
	case whereis(Name) of
		undefined ->
			case global:whereis_name(Name) of
				undefined ->
					exit(could_not_find_registered_name);
				Pid ->
					Pid
			end;
		Pid ->
			Pid
	end.

%%-----------------------------------------------------------------
%% Status information
%%-----------------------------------------------------------------
format_status(Opt, StatusData) ->
	[PDict, SysState, Parent, Debug, {_Continuation, Name, Callback, CallbackState}] = StatusData,
	Header = gen:format_status_header("Status for generic process",
		Name),
	Log = sys:get_debug(log, Debug, []),
	DefaultStatus = [{data, [{"State", CallbackState}]}],
	Specific = case erlang:function_exported(Callback, format_status, 2) of
		true ->
			case catch Callback:format_status(Opt, [PDict, CallbackState]) of
				{'EXIT', _} -> DefaultStatus;
				StatusList when is_list(StatusList) -> StatusList;
				Else -> [Else]
			end;
		_ ->
			DefaultStatus
	end,
	[
		{header, Header},
		{data, [
			{"Status", SysState},
			{"Parent", Parent},
			{"Logged events", Log}
		]} |
		Specific
	].
