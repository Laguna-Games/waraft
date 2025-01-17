%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.
%%%
%%% This module implements the front-end process for accepting commits / reads

-module(wa_raft_acceptor).
-compile(warn_missing_spec).
-behaviour(gen_server).

%% OTP supervisor
-export([
    child_spec/1,
    start_link/1
]).

%% Client API - data access
-export([
    commit/2,
    commit/3,
    read/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export_type([
    command/0,
    op/0,
    read_op/0
]).

-include_lib("kernel/include/logger.hrl").
-include("wa_raft.hrl").

%% Acceptor state
-record(raft_acceptor, {
    % Service name
    name :: atom(),
    % Table name
    table :: wa_raft:table(),
    % Partition
    partition :: wa_raft:partition(),
    % Server service name
    server :: atom(),
    % Storage service name
    storage :: atom()
}).

-type command() ::
      noop
    | {config, Config :: wa_raft_server:config()}
    | {execute, Table :: atom(), Key :: term(), Module :: module(), Func :: atom(), Args :: list()}
    | term().
-type op() :: {Ref :: term(), Command :: command()}.
-type read_op() :: {From :: gen_server:from(), Command :: command()}.

-spec child_spec(Config :: [term()]) -> supervisor:child_spec().
child_spec(Config) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Config]},
        restart => transient,
        shutdown => 30000,
        modules => [?MODULE]
    }.

%% Public API
-spec start_link(RaftArgs :: wa_raft:args()) -> {ok, Pid :: pid()} | ignore | wa_raft:error().
start_link(#{table := Table, partition := Partition} = RaftArgs) ->
    Name = ?RAFT_ACCEPTOR_NAME(Table, Partition),
    gen_server:start_link({local, Name}, ?MODULE, [RaftArgs], []).

%% Commit a change on leader node specified by pid. It's a blocking call. It returns until it
%% is acknowledged on quorum nodes.
%%
%% See wa_raft_storage:execute() to find all supported commands.
%%
-spec commit(Pid :: pid() | Local :: atom() | {Service :: atom(), Node :: node()}, Op :: op()) -> {ok, term()} | wa_raft:error().
commit(Pid, Op) ->
    gen_server:call(Pid, {commit, Op}, ?RPC_CALL_TIMEOUT_MS).

-spec commit(Dest :: pid() | Local :: atom() | {Service :: atom(), Node :: node()}, From :: {pid(), term()}, Op :: op()) -> ok.
commit(Dest, From, Op) ->
    gen_server:cast(Dest, {commit, From, Op}).

% Strong-read
-spec read(ServerRef :: gen_server:server_ref(), Command :: command()) -> {ok, Result :: term()} | wa_raft:error().
read(Dest, Command) ->
    gen_server:call(Dest, {read, Command}, ?RPC_CALL_TIMEOUT_MS).

%% gen_server callbacks
-spec init([wa_raft:args()]) -> {ok, #raft_acceptor{}}.
init([#{table := Table, partition := Partition}]) ->
    process_flag(trap_exit, true),
    ?LOG_NOTICE("Starting raft acceptor on ~p:~p", [Table, Partition], #{domain => [whatsapp, wa_raft]}),

    Name = ?RAFT_ACCEPTOR_NAME(Table, Partition),
    State = #raft_acceptor{
        name = Name,
        table = Table,
        partition = Partition,
        server = ?RAFT_SERVER_NAME(Table, Partition),
        storage = ?RAFT_STORAGE_NAME(Table, Partition)
    },
    {ok, State}.

-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: #raft_acceptor{}) ->
    {reply, Reply :: term(), NewState :: #raft_acceptor{}} | {stop, Reason :: term(), Reply :: term(), NewState :: #raft_acceptor{}}.

handle_call({read, Command}, From, #raft_acceptor{} = State0) ->
    State1 = read_impl(From, Command, State0),
    {noreply, State1};

handle_call({commit, Op}, From, State0) ->
    State1 = commit_impl(From, Op, State0),
    {noreply, State1};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Cmd, From, #raft_acceptor{name = Name} = State) ->
    ?LOG_ERROR("[~p] Unexpected call ~p from ~p", [Name, Cmd, From], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.


-spec handle_cast(Request :: term(), State :: #raft_acceptor{}) -> {noreply, NewState :: #raft_acceptor{}}.
handle_cast({commit, From, Op}, State0) ->
    State1 = commit_impl(From, Op, State0),
    {noreply, State1};

handle_cast(Cmd, #raft_acceptor{name = Name} = State) ->
    ?LOG_ERROR("[~p] Unexpected cast ~p", [Name, Cmd], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.


-spec handle_info(Request :: term(), State :: #raft_acceptor{}) -> {noreply, NewState :: #raft_acceptor{}}.
handle_info(Command, #raft_acceptor{name = Name} = State) ->
    ?LOG_ERROR("[~p] Unexpected info ~p", [Name, Command], #{domain => [whatsapp, wa_raft]}),
    {noreply, State}.

-spec terminate(Reason :: term(), State0 :: #raft_acceptor{}) -> State1 :: #raft_acceptor{}.
terminate(Reason, #raft_acceptor{name = Name} = State) ->
    ?LOG_NOTICE("[~p] Acceptor terminated for reason ~p", [Name, Reason], #{domain => [whatsapp, wa_raft]}),
    State.

%% Private functions

-spec commit_impl(From :: {pid(), term()}, Request :: op(), State :: #raft_acceptor{}) -> NewState :: #raft_acceptor{}.
commit_impl(From, {Ref, _} = Op, #raft_acceptor{table = Table, partition = Partition, server = Server, name = Name} = State) ->
    StartT = os:timestamp(),
    ?LOG_DEBUG("[~p] Commit starts", [Name], #{domain => [whatsapp, wa_raft]}),
    case wa_raft_queue:commit(Table, Partition, Ref, From) of
        duplicate ->
            ?LOG_WARNING("[~p] Duplicate request ~p.", [Name, Ref, 100], #{domain => [whatsapp, wa_raft]}),
            ?RAFT_COUNT('raft.acceptor.error.duplicate_commit'),
            gen_server:reply(From, {error, {duplicate_request, Ref}});
        commit_queue_full ->
            ?LOG_WARNING("[~p] Reject request ~p. Commit queue is full", [Name, Ref], #{domain => [whatsapp, wa_raft]}),
            ?RAFT_COUNT('raft.acceptor.error.commit_queue_full'),
            gen_server:reply(From, {error, {commit_queue_full, Ref}});
        apply_queue_full ->
            ?LOG_WARNING("[~p] Reject request ~p. Apply queue is full", [Name, Ref], #{domain => [whatsapp, wa_raft]}),
            ?RAFT_COUNT('raft.acceptor.error.apply_queue_full'),
            gen_server:reply(From, {error, {apply_queue_full, Ref}});
        ok ->
            wa_raft_server:commit(Server, Op)
    end,
    ?RAFT_GATHER('raft.acceptor.commit.func', timer:now_diff(os:timestamp(), StartT)),
    State.

-spec read_impl(From :: gen_server:from(),
                Command :: command(),
                State0 :: #raft_acceptor{}) -> State1 :: #raft_acceptor{}.
%% Strongly-consistent read.
read_impl(From, Command, #raft_acceptor{name = Name, table = Table, partition = Partition, server = Server} = State) ->
    StartT = os:timestamp(),
    ?LOG_DEBUG("Acceptor[~p] starts to handle read of ~0P from ~0p.",
        [Name, Command, 100, From], #{domain => [whatsapp, wa_raft]}),
    case wa_raft_queue:reserve_read(Table, Partition) of
        read_queue_full ->
            ?RAFT_COUNT('raft.acceptor.strong_read.error.read_queue_full'),
            ?LOG_WARNING("Acceptor[~p] is rejecting read request from ~p because the read queue is full.",
                [Name, From], #{domain => [whatsapp, wa_raft]}),
            gen_server:reply(From, {error, read_queue_full});
        apply_queue_full ->
            ?RAFT_COUNT('raft.acceptor.strong_read.error.apply_queue_full'),
            ?LOG_WARNING("Acceptor[~p] is rejecting read request from ~p because the apply queue is full.",
                [Name, From], #{domain => [whatsapp, wa_raft]}),
            gen_server:reply(From, {error, apply_queue_full});
        ok ->
            wa_raft_server:read(Server, {From, Command})
    end,
    ?RAFT_GATHER('raft.acceptor.strong_read.func', timer:now_diff(os:timestamp(), StartT)),
    State.
