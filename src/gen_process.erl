-module(gen_process).
-export([
	start/3,
	start/4,
	start_link/3,
	start_link/4,
	call/2,
	call/3,
	reply/2
]).

%% System exports
-export([
		system_continue/3,
		system_terminate/4,
		system_code_change/4,
		format_status/2
	]).

%% Internal exports
-export([init_it/6]).

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
					sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, [Name, Callback, CallbackState]);
				{'EXIT', Parent, Reason} ->
					terminate(Reason, Name, Message, Callback, CallbackState, Debug);
				_ when Debug =:= [] ->
					loop(Parent, Name, Callback, NewCallbackState, Debug);
				_ ->
					NewDebug = sys:handle_debug(Debug, fun print_event/3, Name, {in, Message}),
					loop(Parent, Name, Callback, NewCallbackState, NewDebug)
			end;
		{continue, NewCallbackState} ->
			loop(Parent, Name, Callback, NewCallbackState, Debug);
		% TODO: add support for hibernating
		%{hibernate, NewCallbackState} ->
		%	proc_lib:hibernate(?MODULE, loop, [Parent, Name, Callback, NewCallbackState, Debug]);
		{stop, Reason, Message, NewCallbackState} ->
			NewDebug = sys:handle_debug(Debug, fun print_event/3, Name, {in, Message}),
			terminate(Reason, Name, Message, Callback, NewCallbackState, NewDebug);
		{'EXIT', Reason} ->
			terminate(Reason, Name, [], Callback, CallbackState, Debug)
	end.

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(Parent, Debug, [Name, Callback, CallbackState]) ->
	loop(Parent, Name, Callback, CallbackState, Debug).

-spec system_terminate(_, _, _, [_]) -> no_return().
system_terminate(Reason, _Parent, Debug, [Name, Callback, CallbackState]) ->
	terminate(Reason, Name, [], Callback, CallbackState, Debug).

system_code_change([Name, Callback, CallbackState], _Module, OldVsn, Extra) ->
	case catch Callback:code_change(OldVsn, CallbackState, Extra) of
		{ok, NewCallbackState} -> {ok, [Name, Callback, NewCallbackState]};
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

%%-----------------------------------------------------------------
%% Status information
%%-----------------------------------------------------------------
format_status(Opt, StatusData) ->
	[PDict, SysState, Parent, Debug, [Name, Callback, CallbackState]] = StatusData,
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
