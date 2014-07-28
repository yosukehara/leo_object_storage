%%====================================================================
%%
%% Leo Object Storage
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
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
%% Leo Object Storage - EUnit
%% @author yosuke hara
%% @doc
%% @end
%%====================================================================
-module(leo_object_storage_api_tests).
-author('yosuke hara').

-include_lib("eunit/include/eunit.hrl").
-include("leo_object_storage.hrl").

-ifdef(EUNIT).

%%======================================================================
%% Compaction TEST
%%======================================================================
-define(AVS_DIR_FOR_COMPACTION, "comaction_test/").

compaction_test_() ->
    {setup,
     fun ( ) ->
             ?debugVal("***** COMPACTION.START *****"),
             os:cmd("rm -rf " ++ ?AVS_DIR_FOR_COMPACTION),
             application:start(sasl),
             application:start(os_mon),
             application:start(crypto),
             ok
     end,
     fun (_) ->
             application:stop(leo_object_storage),
             application:stop(crypto),
             application:stop(os_mon),
             application:stop(sasl),
             timer:sleep(5000),
             ?debugVal("***** COMPACTION.END *****"),
             ok
     end,
     [
      {"test compaction - irregular case",
       {timeout, 600, fun compact/0}}
     ]}.

compact() ->
    %% Launch object-storage
    leo_object_storage_api:start([{1, ?AVS_DIR_FOR_COMPACTION}]),
    ok = put_regular_bin(1, 50),
    ok = put_irregular_bin(),
    ok = put_regular_bin(36, 25),
    ok = put_irregular_bin(),
    ok = put_regular_bin(51, 50),

    %% Execute compaction
    timer:sleep(3000),
    FunHasChargeOfNode = fun(_Key_,_NumOfReplicas_) ->
                                 true
                         end,
    TargetPids = leo_object_storage_api:get_object_storage_pid(all),
    ok = leo_compaction_manager_fsm:start(TargetPids, 1, FunHasChargeOfNode),

    %% Check comaction status
    ok = check_status(),

    %% Check # of active objects and total of objects
    timer:sleep(1000),
    {ok, [{_,#storage_stats{total_num  = TotalNum,
                            active_num = ActiveNum
                           }}|_]} = leo_object_storage_api:stats(),
    ?debugVal({TotalNum, ActiveNum}),
    ?assertEqual(100, TotalNum),
    ?assertEqual(TotalNum, ActiveNum),
    ok.

check_status() ->
    timer:sleep(100),
    case leo_compaction_manager_fsm:status() of        
        {ok, #compaction_stats{status = 'idle'}} ->
            ok;
        {ok, _} ->
            check_status();
        Error ->
            Error
    end.

%% @doc Put data
%% @private
put_regular_bin(_, 0) ->
    ok;
put_regular_bin(Index, Counter) ->
    AddrId = 1,
    Key = list_to_binary(lists:append(["TEST_", integer_to_list(Index)])),
    Bin = crypto:rand_bytes(erlang:phash2(leo_date:clock(), (1024 * 1024))),
    Object = #?OBJECT{method    = put,
                      addr_id   = AddrId,
                      key       = Key,
                      ksize     = byte_size(Key),
                      data      = Bin,
                      dsize     = byte_size(Bin),
                      checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, Bin)),
                      timestamp = leo_date:now(),
                      clock     = leo_date:clock()
                     },
    {ok, _} = leo_object_storage_api:put({AddrId, Key}, Object),
    put_regular_bin(Index + 1, Counter -1).

put_irregular_bin() ->
    Min = 1024 * 16,
    Len = case erlang:phash2(leo_date:clock(), (1024 * 512)) of
              Val when Val < Min ->
                  Min;
              Val ->
                  Val
          end,
    ?debugVal(Len),
    Bin = crypto:rand_bytes(Len),
    _ = leo_object_storage_api:add_incorrect_data(Bin),
    ok.


%%======================================================================
%% Suite TEST
%%======================================================================
suite_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [{with, [T]} || T <- [fun new_/1,
                           fun operate_/1,
                           fun fetch_by_addr_id_/1,
                           fun fetch_by_key_/1
                          ]]}.

setup() ->
    application:start(crypto),
    Path1 = "./avs1",
    Path2 = "./avs2",
    io:format(user, "setup~n", []),
    [Path1, Path2].

teardown([Path1, Path2]) ->
    io:format(user, "teardown~n", []),
    os:cmd("rm -rf " ++ Path1),
    os:cmd("rm -rf " ++ Path2),
    application:stop(leo_object_storage),
    application:stop(crypto),
    timer:sleep(1000),
    ok.


new_([Path1, _]) ->
    %% 1-1.
    DivCount0 = 4,
    ok = leo_object_storage_api:start([{DivCount0, Path1}]),

    Ref = whereis(leo_object_storage_sup),
    ?assertEqual(true, is_pid(Ref)),

    [{specs,_},{active,Active0},{supervisors,_},{workers,Workers0}] = supervisor:count_children(Ref),
    ?assertEqual(DivCount0 + 2, Active0),  % +2 for compaction manager + backend_db_sup
    ?assertEqual(DivCount0 + 2, Workers0), % +2 for compaction manager + backend_db_sup
    {ok, ?AVS_HEADER_VSN_TOBE} =
        leo_object_storage_server:get_avs_version_bin(
          leo_object_storage_api:get_object_storage_pid_first()),
    application:stop(leo_backend_db),
    application:stop(bitcask),
    application:stop(leo_object_storage),

    %% 2. Exception
    Res0 = leo_object_storage_api:start([]),
    ?assertEqual({error, badarg}, Res0),
    ok.

%% Get/Put/Delte
operate_([Path1, Path2]) ->
    ok = leo_object_storage_api:start([{4, Path1},{4, Path2}]),

    %% 1. Put
    AddrId = 0,
    Key = <<"air/on/g/string">>,
    Bin = <<"J.S.Bach">>,
    Object = #?OBJECT{method    = put,
                      addr_id   = AddrId,
                      key       = Key,
                      ksize     = byte_size(Key),
                      data      = Bin,
                      dsize     = byte_size(Bin),
                      checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, Bin)),
                      timestamp = leo_date:now(),
                      clock     = leo_date:clock()},
    {ok,_ETag} = leo_object_storage_api:put({AddrId, Key}, Object),

    %% 2. Get
    {ok, Meta1, Obj0} = leo_object_storage_api:get({AddrId, Key}),
    ?assertEqual(AddrId, Meta1#?METADATA.addr_id),
    ?assertEqual(Key,    Meta1#?METADATA.key),
    ?assertEqual(0,      Meta1#?METADATA.del),
    ?assertEqual(AddrId,         Obj0#?OBJECT.addr_id),
    ?assertEqual(Key,            Obj0#?OBJECT.key),
    ?assertEqual(Bin,            Obj0#?OBJECT.data),
    ?assertEqual(byte_size(Bin), Obj0#?OBJECT.dsize),
    ?assertEqual(0,              Obj0#?OBJECT.del),

    %% 2-1. Head with calculating MD5
    ExpectedMD5 = crypto:hash(md5, Bin),
    Context = crypto:hash_init(md5),
    {ok, MetaMD5, Context2} = leo_object_storage_api:head_with_calc_md5({AddrId, Key}, Context),
    ?assertEqual(ExpectedMD5, crypto:hash_final(Context2)),
    ?assertEqual(AddrId, MetaMD5#?METADATA.addr_id),
    ?assertEqual(Key,    MetaMD5#?METADATA.key),

    %% 3. Store (for Copy)
    ok = leo_object_storage_api:store(Meta1, Bin),
    {ok, Meta1_1, _} = leo_object_storage_api:get({AddrId, Key}),
    ?assertEqual(AddrId, Meta1_1#?METADATA.addr_id),
    ?assertEqual(Key,    Meta1_1#?METADATA.key),
    ?assertEqual(0,      Meta1_1#?METADATA.del),


    %% 4. Get - for range query via HTTP
    %% >> Case of regular.
    {ok, _Meta1_1, Obj0_1} = leo_object_storage_api:get({AddrId, Key}, 4, 7),
    ?assertEqual(4, byte_size(Obj0_1#?OBJECT.data)),
    ?assertEqual(<<"Bach">>, Obj0_1#?OBJECT.data),

    %% >> Case of "end-position over data-size".
    {ok, _Meta1_2, Obj0_2} = leo_object_storage_api:get({AddrId, Key}, 5, 9),
    ?assertEqual(<<>>, Obj0_2#?OBJECT.data),
    ?assertEqual(-2, Obj0_2#?OBJECT.dsize),

    %% >> Case of "end-position is zero". This means "end-position is data-size".
    {ok, _Meta1_3, Obj0_3} = leo_object_storage_api:get({AddrId, Key}, 2, 0),
    ?assertEqual(<<"S.Bach">>, Obj0_3#?OBJECT.data),

    %% >> Case of "start-position over data-size"
    {ok, _Meta1_4, Obj0_4} = leo_object_storage_api:get({AddrId, Key}, 8, 0),
    ?assertEqual(<<>>, Obj0_4#?OBJECT.data),
    ?assertEqual(-2, Obj0_4#?OBJECT.dsize),

    %% >> Case of "end-position is negative". This means retrieving from end
    {ok, _Meta1_5, Obj0_5} = leo_object_storage_api:get({AddrId, Key}, 0, -2),
    ?assertEqual(<<"ch">>, Obj0_5#?OBJECT.data),

    %% 5. Head
    {ok, Res2} = leo_object_storage_api:head({AddrId, Key}),
    Meta2 = binary_to_term(Res2),
    ?assertEqual(AddrId, Meta2#?METADATA.addr_id),
    ?assertEqual(Key,    Meta2#?METADATA.key),
    ?assertEqual(0,      Meta2#?METADATA.del),

    %% 6. Delete
    Object2 = #?OBJECT{method    = delete,
                       key       = Key,
                       ksize     = byte_size(Key),
                       addr_id   = AddrId,
                       data      = <<>>,
                       dsize     = 0,
                       checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, <<>>)),
                       timestamp = leo_date:now(),
                       clock     = leo_date:clock(),
                       del       = 1},
    ok = leo_object_storage_api:delete({AddrId, Key}, Object2),

    %% 7. Get
    Res4 = leo_object_storage_api:get({AddrId, Key}),
    ?assertEqual(not_found, Res4),

    %% 8. Head
    {ok, Res5} = leo_object_storage_api:head({AddrId, Key}),
    Meta5 = binary_to_term(Res5),
    ?assertEqual(AddrId, Meta5#?METADATA.addr_id),
    ?assertEqual(Key,    Meta5#?METADATA.key),
    ?assertEqual(1,      Meta5#?METADATA.del),

    %% 8. Put with custom-metadata
    ClusterId = "cluster_id",
    NumOfReplicas = 1,
    Ver = 1,
    Obj2 = #?OBJECT{method    = put,
                    addr_id   = AddrId,
                    key       = Key,
                    ksize     = byte_size(Key),
                    data      = Bin,
                    dsize     = byte_size(Bin),
                    checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, Bin)),
                    timestamp = leo_date:now(),
                    clock     = leo_date:clock(),

                    cluster_id = ClusterId,
                    num_of_replicas = NumOfReplicas,
                    ver = Ver
                   },
    {ok,_} = leo_object_storage_api:put({AddrId, Key}, Obj2),
    {ok, Res6, Res7} = leo_object_storage_api:get({AddrId, Key}),
    ?assertEqual(ClusterId,     Res6#?METADATA.cluster_id),
    ?assertEqual(NumOfReplicas, Res6#?METADATA.num_of_replicas),
    ?assertEqual(Ver,           Res6#?METADATA.ver),
    ?assertEqual(ClusterId,     Res7#?OBJECT.cluster_id),
    ?assertEqual(NumOfReplicas, Res7#?OBJECT.num_of_replicas),
    ?assertEqual(Ver,           Res7#?OBJECT.ver),

    application:stop(leo_backend_db),
    application:stop(bitcask),
    application:stop(leo_object_storage),
    ok.

fetch_by_addr_id_([Path1, Path2]) ->
    ok = leo_object_storage_api:start([{4, Path1},{4, Path2}]),

    try
        ok = put_test_data(0,    <<"air/on/g/string/0">>, <<"JSB0">>),
        ok = put_test_data(127,  <<"air/on/g/string/1">>, <<"JSB1">>),
        ok = put_test_data(255,  <<"air/on/g/string/2">>, <<"JSB2">>),
        ok = put_test_data(511,  <<"air/on/g/string/3">>, <<"JSB3">>),
        ok = put_test_data(1023, <<"air/on/g/string/4">>, <<"JSB4">>),

        FromAddrId = 0,
        ToAddrId   = 255,

        Fun = fun(_K, V, Acc) ->
                      %% Key = binary_to_term(K),
                      %% AddrId = leo_object_storage_api:head(Key),
                      Metadata      = binary_to_term(V),
                      AddrId = Metadata#?METADATA.addr_id,

                      case (AddrId >= FromAddrId andalso
                            AddrId =< ToAddrId) of
                          true  ->
                              io:format(user, "[debug]meta:~p~n", [Metadata]),
                              [Metadata|Acc];
                          false ->
                              Acc
                      end
              end,
        {ok, Res} = leo_object_storage_api:fetch_by_addr_id(0, Fun),
        ?assertEqual(3, length(Res))
    after
        application:stop(leo_backend_db),
        application:stop(bitcask),
        application:stop(leo_object_storage)
    end,
    ok.

fetch_by_key_([Path1, Path2]) ->
    ok = leo_object_storage_api:start([{4, Path1},{4, Path2}]),
    try
        ok = put_test_data(0,    <<"air/on/g/string/0">>, <<"JSB0">>),
        ok = put_test_data(127,  <<"air/on/g/string/1">>, <<"JSB1">>),
        ok = put_test_data(255,  <<"air/on/g/string/2">>, <<"JSB2">>),
        ok = put_test_data(511,  <<"air/on/g/string/3">>, <<"JSB3">>),
        ok = put_test_data(1023, <<"air/on/g/string/4">>, <<"JSB4">>),

        Fun = fun(K, V, Acc) ->
                      Metadata      = binary_to_term(V),

                      case (K == <<"air/on/g/string/0">> orelse
                            K == <<"air/on/g/string/2">> orelse
                            K == <<"air/on/g/string/4">>) of
                          true  ->
                              io:format(user, "[debug]meta:~p~n", [Metadata]),
                              [Metadata|Acc];
                          false ->
                              Acc
                      end
              end,
        {ok, Res} = leo_object_storage_api:fetch_by_key(<<"air/on/g/string">>, Fun),
        ?assertEqual(3, length(Res)),
        {ok, Res2} = leo_object_storage_api:fetch_by_key(<<"air/on/g/string">>, Fun, 2),
        ?assertEqual(2, length(Res2))
    after
        application:stop(leo_backend_db),
        application:stop(bitcask),
        application:stop(leo_object_storage)
    end,
    ok.

stats_test_() ->
    {timeout, 15,
     [?_test(
         begin
             application:start(crypto),
             Path1 = "./avs1",
             Path2 = "./avs2",
             ok = leo_object_storage_api:start([{4, Path1},{4, Path2}]),

             ok = put_test_data(0,    <<"air/on/g/string/0">>, <<"JSB0">>),
             ok = put_test_data(127,  <<"air/on/g/string/1">>, <<"JSB1">>),
             ok = put_test_data(255,  <<"air/on/g/string/2">>, <<"JSB2">>),
             ok = put_test_data(511,  <<"air/on/g/string/3">>, <<"JSB3">>),
             ok = put_test_data(767,  <<"air/on/g/string/4">>, <<"JSB4">>),
             ok = put_test_data(1023, <<"air/on/g/string/5">>, <<"JSB5">>),
             ok = put_test_data(2047, <<"air/on/g/string/6">>, <<"JSB6">>),
             ok = put_test_data(4095, <<"air/on/g/string/7">>, <<"JSB7">>),
             ok = put_test_data(4095, <<"air/on/g/string/7">>, <<"JSB8">>),

             {ok, Res} = leo_object_storage_api:stats(),
             ?assertEqual(8, length(Res)),

             catch leo_object_storage_sup:stop(),
             application:stop(leo_backend_db),
             application:stop(bitcask),
             application:stop(leo_object_storage),
             io:format(user, "*** [test]stopped ~n", []),

             %% relaunch and validate stored datas
             ok = leo_object_storage_api:start([{4, Path1},{4, Path2}]),
             io:format(user, "*** [test]restarted ~n", []),
             {ok, Res1} = leo_object_storage_api:stats(),
             ?assertEqual(8, length(Res)),
             {SumTotal0, SumActive0} =
                 lists:foldl(
                   fun({ok, #storage_stats{file_path  = _ObjPath,
                                           total_num  = Total,
                                           active_num = Active}},
                       {SumTotal, SumActive}) ->
                           {SumTotal + Total, SumActive + Active}
                   end, {0, 0}, Res1),
             ?assertEqual(9, SumTotal0),
             ?assertEqual(8, SumActive0),

             catch leo_object_storage_sup:stop(),
             io:format(user, "*** [test]stopped2 ~n", []),
             application:stop(leo_backend_db),
             application:stop(bitcask),
             application:stop(leo_object_storage),
             application:stop(crypto),
             os:cmd("rm -rf " ++ Path1),
             os:cmd("rm -rf " ++ Path2),
             true end)]}.

compact_test_() ->
    {timeout, 15,
     [?_test(
         begin
             Path1 = "./avs1",
             Path2 = "./avs2",
             application:start(crypto),
             application:start(sasl),
             application:start(os_mon),

             os:cmd("rm -rf " ++ Path1),
             os:cmd("rm -rf " ++ Path2),

             ok = leo_object_storage_api:start([{4, Path1}, {4, Path2}]),
             ok = put_test_data(0,    <<"air/on/g/string/0">>, <<"JSB0">>),
             ok = put_test_data(127,  <<"air/on/g/string/1">>, <<"JSB1">>),
             ok = put_test_data(255,  <<"air/on/g/string/2">>, <<"JSB2">>),
             ok = put_test_data(511,  <<"air/on/g/string/3">>, <<"JSB3">>),
             ok = put_test_data(767,  <<"air/on/g/string/4">>, <<"JSB4">>),
             ok = put_test_data(1023, <<"air/on/g/string/5">>, <<"JSB5">>),
             ok = put_test_data(2047, <<"air/on/g/string/6">>, <<"JSB6">>),
             ok = put_test_data(4095, <<"air/on/g/string/7">>, <<"JSB7">>), %% 1st time
             ok = put_test_data(4095, <<"air/on/g/string/7">>, <<"JSB7">>), %% 2nd time
             {ok, Res0} = leo_object_storage_api:stats(),
             {SumTotal0, SumActive0} =
                 lists:foldl(fun({ok, #storage_stats{file_path  = _ObjPath,
                                                     total_num  = Total,
                                                     active_num = Active}}, {SumTotal, SumActive}) ->
                                     {SumTotal + Total, SumActive + Active}
                             end, {0, 0}, Res0),
             ?assertEqual(9, SumTotal0),
             ?assertEqual(8, SumActive0),
             ?assertEqual({error,badstate}, leo_compaction_manager_fsm:suspend()),
             ?assertEqual({error,badstate}, leo_compaction_manager_fsm:resume()),

             %% append incorrect data based on IS devenv's corrupted data
             {ok, CorruptedDataBlock} = file:read_file("../test/broken_part.avs"),
             _ = leo_object_storage_api:add_incorrect_data(CorruptedDataBlock),

             ok = put_test_data(0,    <<"air/on/g/string/0">>, <<"JSB0-1">>),
             ok = put_test_data(511,  <<"air/on/g/string/3">>, <<"JSB3-1">>),

             ok = put_test_data(10001, <<"air/on/g/string/1/0">>, <<"JSB0-1">>),
             ok = put_test_data(10002, <<"air/on/g/string/1/2">>, <<"JSB0-1">>),
             ok = put_test_data(10003, <<"air/on/g/string/1/3">>, <<"JSB0-1">>),
             ok = put_test_data(10004, <<"air/on/g/string/1/4">>, <<"JSB0-1">>),
             ok = put_test_data(10005, <<"air/on/g/string/1/5">>, <<"JSB0-1">>),
             ok = put_test_data(10006, <<"air/on/g/string/1/6">>, <<"JSB0-1">>),

             AllTargets = leo_object_storage_api:get_object_storage_pid('all'),
             ?assertEqual({ok, #compaction_stats{status = 'idle',
                                                 total_num_of_targets    = 8,
                                                 num_of_reserved_targets = 0,
                                                 num_of_pending_targets  = 8,
                                                 num_of_ongoing_targets  = 0,
                                                 reserved_targets = [],
                                                 pending_targets  = AllTargets,
                                                 ongoing_targets  = [],
                                                 latest_exec_datetime = 0
                                                }}, leo_compaction_manager_fsm:status()),
             AddrId = 4095,
             Key    = <<"air/on/g/string/7">>,
             Object = #?OBJECT{method    = delete,
                               key       = Key,
                               ksize     = byte_size(Key),
                               addr_id   = AddrId,
                               data      = <<>>,
                               dsize     = 0,
                               checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, <<>>)),
                               timestamp = leo_date:now(),
                               clock     = leo_date:clock(),
                               del       = 1},
             ok = leo_object_storage_api:delete({AddrId, Key}, Object),

             %% inspect for compaction
             {ok, Res1} = leo_object_storage_api:stats(),
             {SumTotal1, SumActive1, SumTotalSize1, SumActiveSize1}
                 = get_avs_stats_summary(Res1),
             ?assertEqual(18, SumTotal1),
             ?assertEqual(13, SumActive1),
             ?assertEqual(true, SumTotalSize1 > SumActiveSize1),
             timer:sleep(250),

             FunHasChargeOfNode = fun(_Key_,_NumOfReplicas_) ->
                                          ?debugVal({_Key_,_NumOfReplicas_}),
                                          true
                                  end,
             TargetPids = leo_object_storage_api:get_object_storage_pid(all),
             io:format(user, "*** target-pids:~p~n", [TargetPids]),

             ok = leo_compaction_manager_fsm:start(TargetPids, 2, FunHasChargeOfNode),
             timer:sleep(100),

             {ok, CompactionStats} = leo_compaction_manager_fsm:status(),
             ?assertEqual('running', CompactionStats#compaction_stats.status),
             ?assertEqual(8, CompactionStats#compaction_stats.total_num_of_targets),
             ?assertEqual(true, 0 < CompactionStats#compaction_stats.num_of_pending_targets),
             ?assertEqual(true, 0 < CompactionStats#compaction_stats.num_of_ongoing_targets),

             ?assertEqual(ok, leo_compaction_manager_fsm:suspend()),
             {ok, CompactionStats2} = leo_compaction_manager_fsm:status(),
             ?assertEqual('suspend', CompactionStats2#compaction_stats.status),
             %% keep # of ongoing/pending fixed during suspend
             Pending = CompactionStats2#compaction_stats.num_of_pending_targets,
             Ongoing = CompactionStats2#compaction_stats.num_of_ongoing_targets,
             timer:sleep(1000),
             ?assertEqual(Pending, CompactionStats2#compaction_stats.num_of_pending_targets),
             ?assertEqual(Ongoing, CompactionStats2#compaction_stats.num_of_ongoing_targets),
             %% operation during suspend
             TestAddrId0 = 0,
             TestKey0    = <<"air/on/g/string/0">>,
             TestAddrId1 = 511,
             TestKey1    = <<"air/on/g/string/3">>,
             {ok, _, _} = get_test_data(TestAddrId0, TestKey0),
             {ok, _, _} = get_test_data(TestAddrId1, TestKey1),

             ?assertEqual(ok, leo_compaction_manager_fsm:resume()),

             timer:sleep(3000),
             {ok, Res2} = leo_object_storage_api:stats(),
             {SumTotal2, SumActive2, SumTotalSize2, SumActiveSize2}
                 = get_avs_stats_summary(Res2),
             io:format(user, "[debug] summary1:~p~n", [{SumTotal2, SumActive2, SumTotalSize2, SumActiveSize2}]),
             ?assertEqual(13, SumTotal2),
             ?assertEqual(13, SumActive2),
             ?assertEqual(true, SumTotalSize2 =:= SumActiveSize2),


             %% confirm whether first compaction have broken avs files or not
             ok = leo_compaction_manager_fsm:start(TargetPids, 2, FunHasChargeOfNode),
             timer:sleep(5000),
             %% must be equal the previous stats
             {ok, Res3} = leo_object_storage_api:stats(),
             {SumTotal2, SumActive2, SumTotalSize2, SumActiveSize2}
                 = get_avs_stats_summary(Res3),

             %% inspect for after compaction
             TestAddrId0 = 0,
             TestKey0    = <<"air/on/g/string/0">>,
             TestAddrId1 = 511,
             TestKey1    = <<"air/on/g/string/3">>,

             {ok, Meta0, Obj0} = get_test_data(TestAddrId0, TestKey0),
             {ok, Meta1, Obj1} = get_test_data(TestAddrId1, TestKey1),

             ?assertEqual(TestAddrId0,  Meta0#?METADATA.addr_id),
             ?assertEqual(TestKey0,     Meta0#?METADATA.key),
             ?assertEqual(6,            Meta0#?METADATA.dsize),
             ?assertEqual(0,            Meta0#?METADATA.del),
             ?assertEqual(TestAddrId0,  Obj0#?OBJECT.addr_id),
             ?assertEqual(TestKey0,     Obj0#?OBJECT.key),
             ?assertEqual(6,            Obj0#?OBJECT.dsize),
             ?assertEqual(<<"JSB0-1">>, Obj0#?OBJECT.data),
             ?assertEqual(0,            Obj0#?OBJECT.del),

             ?assertEqual(TestAddrId1,  Meta1#?METADATA.addr_id),
             ?assertEqual(TestKey1,     Meta1#?METADATA.key),
             ?assertEqual(6,            Meta1#?METADATA.dsize),
             ?assertEqual(0,            Meta1#?METADATA.del),
             ?assertEqual(TestAddrId1,  Obj1#?OBJECT.addr_id),
             ?assertEqual(TestKey1,     Obj1#?OBJECT.key),
             ?assertEqual(6,            Obj1#?OBJECT.dsize),
             ?assertEqual(<<"JSB3-1">>, Obj1#?OBJECT.data),
             ?assertEqual(0,            Obj1#?OBJECT.del),


             ok = leo_object_storage_sup:stop(),
             application:stop(leo_backend_db),
             application:stop(bitcask),
             application:stop(leo_object_storage),
             application:stop(os_mon),
             application:stop(sasl),
             application:stop(crypto),
             true end)]}.


%% proper_test_() ->
%%     {timeout, 60000, ?_assertEqual([], proper:module(leo_object_storage_api_prop))}.


%%--------------------------------------------------------------------
%% INNER FUNCTIONS
%%--------------------------------------------------------------------
get_avs_stats_summary(ResStats) ->
    lists:foldl(
      fun({ok, #storage_stats{file_path  = _ObjPath,
                              total_sizes = TotalSize,
                              active_sizes = ActiveSize,
                              has_error = HasError,
                              total_num  = Total,
                              active_num = Active} = SS},
          {SumTotal, SumActive, SumTotalSize, SumActiveSize}) ->
              io:format(user, "[debug]ss:~p~n",[SS]),
              case TotalSize of
                  0 -> void;
                  _ -> ?assertEqual(false, HasError)
              end,
              {SumTotal + Total,
               SumActive + Active,
               SumTotalSize + TotalSize,
               SumActiveSize + ActiveSize}
      end, {0, 0, 0, 0}, ResStats).


put_test_data(AddrId, Key, Bin) ->
    Object = #?OBJECT{method    = put,
                      addr_id   = AddrId,
                      key       = Key,
                      ksize     = byte_size(Key),
                      data      = Bin,
                      dsize     = byte_size(Bin),
                      checksum  = leo_hex:raw_binary_to_integer(crypto:hash(md5, Bin)),
                      timestamp = leo_date:now(),
                      clock     = leo_date:clock()
                     },
    {ok, _Checksum} = leo_object_storage_api:put({AddrId, Key}, Object),
    ok.

get_test_data(AddrId, Key) ->
    leo_object_storage_api:get({AddrId, Key}).

-endif.
