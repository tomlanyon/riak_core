%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc send a partition's data via TCP-based handoff

-module(riak_core_handoff_sender).
-export([start_link/4, get_handoff_ssl_options/0]).
-include("riak_core_vnode.hrl").
-include("riak_core_handoff.hrl").
-define(ACK_COUNT, 1000).
%% can be set with env riak_core, handoff_timeout
-define(TCP_TIMEOUT, 60000).
%% can be set with env riak_core, handoff_status_interval
%% note this is in seconds
-define(STATUS_INTERVAL, 2).

-define(log_fail(Str, Args),
        lager:error("~p transfer of ~p from ~p ~p to ~p ~p failed " ++ Str,
                    [Type, Module, SrcNode, SrcPartition, TargetNode,
                     TargetPartition] ++ Args)).

%% Accumulator for the visit item HOF
-record(ho_acc,
        {
          ack            :: non_neg_integer(),
          error          :: ok | {error, any()},
          filter         :: function(),
          module         :: module(),
          parent         :: pid(),
          socket         :: any(),
          src_target     :: {non_neg_integer(), non_neg_integer()},
          stats          :: #ho_stats{},
          tcp_mod        :: module(),
          total          :: non_neg_integer()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(TargetNode, Module, {Type, Opts}, Vnode) ->
    SslOpts = get_handoff_ssl_options(),
    Pid = spawn_link(fun()->start_fold(TargetNode,
                                       Module,
                                       {Type, Opts},
                                       Vnode,
                                       SslOpts)
                     end),
    {ok, Pid}.

%%%===================================================================
%%% Private
%%%===================================================================

start_fold(TargetNode, Module, {Type, Opts}, ParentPid, SslOpts) ->
    SrcNode = node(),
    SrcPartition = get_src_partition(Opts),
    TargetPartition = get_target_partition(Opts),

     try
         Filter = get_filter(Opts),
         [_Name,Host] = string:tokens(atom_to_list(TargetNode), "@"),
         {ok, Port} = get_handoff_port(TargetNode),
         TNHandoffIP =
            case get_handoff_ip(TargetNode) of
                error ->
                    Host;
                {ok, "0.0.0.0"} ->
                    Host;
                {ok, Other} ->
                    Other
            end,
         SockOpts = [binary, {packet, 4}, {header,1}, {active, false}],
         {Socket, TcpMod} =
             if SslOpts /= [] ->
                     {ok, Skt} = ssl:connect(TNHandoffIP, Port, SslOpts ++ SockOpts,
                                             15000),
                     {Skt, ssl};
                true ->
                     {ok, Skt} = gen_tcp:connect(TNHandoffIP, Port, SockOpts, 15000),
                     {Skt, gen_tcp}
             end,

         %% Piggyback the sync command from previous releases to send
         %% the vnode type across.  If talking to older nodes they'll
         %% just do a sync, newer nodes will decode the module name.
         %% After 0.12.0 the calls can be switched to use PT_MSG_SYNC
         %% and PT_MSG_CONFIGURE
         VMaster = list_to_atom(atom_to_list(Module) ++ "_master"),
         ModBin = atom_to_binary(Module, utf8),
         Msg = <<?PT_MSG_OLDSYNC:8,ModBin/binary>>,
         ok = TcpMod:send(Socket, Msg),

         RecvTimeout = get_handoff_receive_timeout(),

         %% Now that handoff_concurrency applies to both outbound and
         %% inbound conns there is a chance that the receiver may
         %% decide to reject the senders attempt to start a handoff.
         %% In the future this will be part of the actual wire
         %% protocol but for now the sender must assume that a closed
         %% socket at this point is a rejection by the receiver to
         %% enforce handoff_concurrency.
         case TcpMod:recv(Socket, 0, RecvTimeout) of
             {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} -> ok;
             {error, timeout} -> exit({shutdown, timeout});
             {error, closed} -> exit({shutdown, max_concurrency})
         end,

         lager:info("Starting ~p transfer of ~p from ~p ~p to ~p ~p",
                    [Type, Module, SrcNode, SrcPartition,
                     TargetNode, TargetPartition]),

         M = <<?PT_MSG_INIT:8,TargetPartition:160/integer>>,
         ok = TcpMod:send(Socket, M),
         StartFoldTime = os:timestamp(),
         Stats = #ho_stats{interval_end=future_now(get_status_interval())},

         Req = ?FOLD_REQ{foldfun=fun visit_item/3,
                         acc0=#ho_acc{ack=0,
                                      error=ok,
                                      filter=Filter,
                                      module=Module,
                                      parent=ParentPid,
                                      socket=Socket,
                                      src_target={SrcPartition, TargetPartition},
                                      stats=Stats,
                                      tcp_mod=TcpMod,
                                      total=0}},


         %% IFF the vnode is using an async worker to perform the fold
         %% then sync_command will return error on vnode crash,
         %% otherwise it will wait forever but vnode crash will be
         %% caught by handoff manager.  I know, this is confusing, a
         %% new handoff system will be written soon enough.
         R = riak_core_vnode_master:sync_command({SrcPartition, SrcNode},
                                                 Req,
                                                 VMaster, infinity),

         #ho_acc{error=ErrStatus,
                 module=Module,
                 parent=ParentPid,
                 tcp_mod=TcpMod,
                 total=SentCount} = R,

         case ErrStatus of
             ok ->
                 %% One last sync to make sure the message has been received.
                 %% post-0.14 vnodes switch to handoff to forwarding immediately
                 %% so handoff_complete can only be sent once all of the data is
                 %% written.  handle_handoff_data is a sync call, so once
                 %% we receive the sync the remote side will be up to date.
                 lager:debug("~p ~p Sending final sync",
                             [SrcPartition, Module]),
                 ok = TcpMod:send(Socket, <<?PT_MSG_SYNC:8>>),

                 case TcpMod:recv(Socket, 0, RecvTimeout) of
                     {ok,[?PT_MSG_SYNC|<<"sync">>]} ->
                         lager:debug("~p ~p Final sync received",
                                     [SrcPartition, Module]);
                     {error, timeout} -> exit({shutdown, timeout})
                 end,

                 FoldTimeDiff = end_fold_time(StartFoldTime),

                 lager:info("~p transfer of ~p from ~p ~p to ~p ~p"
                            " completed: sent ~p objects in ~.2f seconds",
                            [Type, Module, SrcNode, SrcPartition,
                             TargetNode, TargetPartition, SentCount,
                             FoldTimeDiff]),

                 case Type of
                     repair -> ok;
                     _ -> gen_fsm:send_event(ParentPid, handoff_complete)
                 end;
             {error, ErrReason} ->
                 if ErrReason == timeout ->
                         exit({shutdown, timeout});
                    true ->
                         exit({shutdown, {error, ErrReason}})
                 end
         end
     catch
         exit:{shutdown,max_concurrency} ->
             %% Need to fwd the error so the handoff mgr knows
             exit({shutdown, max_concurrency});
         exit:{shutdown, timeout} ->
             %% A receive timeout during handoff
             riak_core_stat:update(handoff_timeouts),
             ?log_fail("because of TCP recv timeout", []),
             exit({shutdown, timeout});
         exit:{shutdown, {error, Reason}} ->
             ?log_fail("because of ~p", [Reason]),
             gen_fsm:send_event(ParentPid, {handoff_error,
                                            fold_error, Reason}),
             exit({shutdown, {error, Reason}});
         Err:Reason ->
             ?log_fail("because of ~p:~p ~p",
                       [Err, Reason, erlang:get_stacktrace()]),
             gen_fsm:send_event(ParentPid, {handoff_error, Err, Reason})
     end.

%% When a tcp error occurs, the ErrStatus argument is set to {error, Reason}.
%% Since we can't abort the fold, this clause is just a no-op.
visit_item(_K, _V, Acc=#ho_acc{error={error, _Reason}}) ->
    Acc;
visit_item(K, V, Acc=#ho_acc{ack=?ACK_COUNT}) ->
    #ho_acc{module=Module,
            socket=Sock,
            src_target={SrcPartition, TargetPartition},
            stats=Stats,
            tcp_mod=TcpMod
           } = Acc,

    RecvTimeout = get_handoff_receive_timeout(),
    M = <<?PT_MSG_OLDSYNC:8,"sync">>,
    NumBytes = byte_size(M),

    Stats2 = incr_bytes(Stats, NumBytes),
    Stats3 = maybe_send_status({Module, SrcPartition, TargetPartition}, Stats2),

    case TcpMod:send(Sock, M) of
        ok ->
            case TcpMod:recv(Sock, 0, RecvTimeout) of
                {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} ->
                    Acc2 = Acc#ho_acc{ack=0, error=ok, stats=Stats3},
                    visit_item(K, V, Acc2);
                {error, Reason} ->
                    Acc#ho_acc{ack=0, error={error, Reason}, stats=Stats3}
            end;
        {error, Reason} ->
            Acc#ho_acc{ack=0, error={error, Reason}, stats=Stats3}
    end;
visit_item(K, V, Acc) ->
    #ho_acc{ack=Ack,
            filter=Filter,
            module=Module,
            socket=Sock,
            src_target={SrcPartition, TargetPartition},
            stats=Stats,
            tcp_mod=TcpMod,
            total=Total
           } = Acc,

    case Filter(K) of
        true ->
            BinObj = Module:encode_handoff_item(K, V),
            M = <<?PT_MSG_OBJ:8,BinObj/binary>>,
            NumBytes = byte_size(M),

            Stats2 = incr_bytes(incr_objs(Stats), NumBytes),
            Stats3 = maybe_send_status({Module, SrcPartition, TargetPartition}, Stats2),

            case TcpMod:send(Sock, M) of
                ok ->
                    Acc#ho_acc{ack=Ack+1, error=ok, stats=Stats3, total=Total+1};
                {error, Reason} ->
                    Acc#ho_acc{error={error, Reason}, stats=Stats3}
            end;
        false ->
            Acc#ho_acc{error=ok, total=Total+1}
    end.

get_handoff_ip(Node) when is_atom(Node) ->
    case rpc:call(Node, riak_core_handoff_listener, get_handoff_ip, [],
                  infinity) of
        {badrpc, _} ->
            error;
        Res ->
            Res
    end.

get_handoff_port(Node) when is_atom(Node) ->
    case catch(gen_server2:call({riak_core_handoff_listener, Node}, handoff_port, infinity)) of
        {'EXIT', _}  ->
            %% Check old location from previous release
            gen_server2:call({riak_kv_handoff_listener, Node}, handoff_port, infinity);
        Other -> Other
    end.

get_handoff_ssl_options() ->
    case app_helper:get_env(riak_core, handoff_ssl_options, []) of
        [] ->
            [];
        Props ->
            try
                %% We'll check if the file(s) exist but won't check
                %% file contents' sanity.
                ZZ = [{_, {ok, _}} = {ToCheck, file:read_file(Path)} ||
                         ToCheck <- [certfile, keyfile, cacertfile, dhfile],
                         Path <- [proplists:get_value(ToCheck, Props)],
                         Path /= undefined],
                spawn(fun() -> self() ! ZZ end), % Avoid term...never used err
                %% Props are OK
                Props
            catch
                error:{badmatch, {FailProp, BadMat}} ->
                    lager:error("SSL handoff config error: property ~p: ~p.",
                                [FailProp, BadMat]),
                    [];
                X:Y ->
                    lager:error("Failure processing SSL handoff config "
                                "~p: ~p:~p",
                                [Props, X, Y]),
                    []
            end
    end.

get_handoff_receive_timeout() ->
    app_helper:get_env(riak_core, handoff_timeout, ?TCP_TIMEOUT).

end_fold_time(StartFoldTime) ->
    EndFoldTime = os:timestamp(),
    timer:now_diff(EndFoldTime, StartFoldTime) / 1000000.

%% @private
%%
%% @doc Produce the value of `now/0' as if it were called `S' seconds
%% in the future.
-spec future_now(pos_integer()) -> erlang:timestamp().
future_now(S) ->
    {Megas, Secs, Micros} = os:timestamp(),
    {Megas, Secs + S, Micros}.

%% @private
%%
%% @doc Check if the given timestamp `TS' has elapsed.
-spec is_elapsed(erlang:timestamp()) -> boolean().
is_elapsed(TS) ->
    os:timestamp() >= TS.

%% @private
%%
%% @doc Increment `Stats' byte count by `NumBytes'.
-spec incr_bytes(ho_stats(), non_neg_integer()) -> NewStats::ho_stats().
incr_bytes(Stats=#ho_stats{bytes=Bytes}, NumBytes) ->
    Stats#ho_stats{bytes=Bytes + NumBytes}.

%% @private
%%
%% @doc Increment `Stats' object count by 1.
-spec incr_objs(ho_stats()) -> NewStats::ho_stats().
incr_objs(Stats=#ho_stats{objs=Objs}) ->
    Stats#ho_stats{objs=Objs+1}.

%% @private
%%
%% @doc Check if the interval has elapsed and if so send handoff stats
%%      for `ModSrcTgt' to the manager and return a new stats record
%%      `NetStats'.
-spec maybe_send_status({module(), non_neg_integer(), non_neg_integer()},
                        ho_stats()) ->
                               NewStats::ho_stats().
maybe_send_status(ModSrcTgt, Stats=#ho_stats{interval_end=IntervalEnd}) ->
    case is_elapsed(IntervalEnd) of
        true ->
            Stats2 = Stats#ho_stats{last_update=os:timestamp()},
            riak_core_handoff_manager:status_update(ModSrcTgt, Stats2),
            #ho_stats{interval_end=future_now(get_status_interval())};
        false ->
            Stats
    end.

get_status_interval() ->
    app_helper:get_env(riak_core, handoff_status_interval, ?STATUS_INTERVAL).

get_src_partition(Opts) ->
    proplists:get_value(src_partition, Opts).

get_target_partition(Opts) ->
    proplists:get_value(target_partition, Opts).

-spec get_filter(proplists:proplist()) -> predicate().
get_filter(Opts) ->
    case proplists:get_value(filter, Opts) of
        none -> fun(_) -> true end;
        Filter -> Filter
    end.
