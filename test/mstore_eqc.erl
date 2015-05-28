-module(mstore_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../include/mstore.hrl").

-import(mstore_helper, [int_array/0, pos_int/0, non_neg_int/0,
                        non_empty_int_list/0, defined_int_array/0]).

-compile(export_all).
%%%-------------------------------------------------------------------
%%% Generators
%%%-------------------------------------------------------------------

-define(S, mstore).
-define(G, gb_trees).
-define(M, <<"metric">>).
-define(DIR, ".qcdata").

store(FileSize) ->
    ?SIZED(Size, store(FileSize, Size)).

insert(FileSize, Size) ->
    ?LAZY(?LET({{S, T}, M, O, V},
               {store(FileSize, Size-1), ?M, offset(), non_z_int()},
               {{call, ?S, put, [S, M, O, V]},
                {call, ?G, enter, [O, V, T]}})).

reopen(FileSize, Size) ->
    ?LAZY(?LET({S, T},
               store(FileSize, Size-1),
               {oneof(
                  [
                   {call, ?MODULE, do_reindex, [S]},
                   {call, ?MODULE, renew, [S, FileSize, ?DIR]},
                   {call, ?MODULE, do_reopen, [S, ?DIR]}]), T})).

delete(FileSize, Size) ->
        ?LAZY(?LET({{S, T}, O},
               {store(FileSize, Size-1), offset()},
               {{call, ?MODULE, do_delete, [S, O]},
                {call, ?MODULE, do_delete_t, [O, FileSize, T]}})).


store(FileSize, Size) ->
    ?LAZY(oneof(
            [{{call, ?MODULE, new, [FileSize, ?DIR]}, {call, ?G, empty, []}}
             || Size == 0]
            ++ [frequency(
                  [{9, insert(FileSize, Size)},
                   {1, delete(FileSize, Size)},
                   {1, reopen(FileSize, Size)}]) || Size > 0])).

do_delete(Set, Offset) ->
    {ok, MSet} = mstore:delete(Set, Offset),
    MSet.

do_delete_t(Offset, FileSize, Tree) ->
    O1 = (Offset div FileSize) * FileSize,
    G = [{T, V} || {T, V} <- ?G:to_list(Tree),
                   T > O1],
    G1 = lists:sort(G),
    ?G:from_orddict(G1).

do_reindex(Old) ->
    {ok, MSet} = mstore:reindex(Old),
    MSet.

do_reopen(Old, Dir) ->
    ok = mstore:close(Old),
    {ok, MSet} = mstore:open(Dir),
    MSet.

renew(Old, FileSize, Dir) ->
    ok = mstore:close(Old),
    new(FileSize, Dir).

new(FileSize, Dir) ->
    {ok, MSet} = mstore:new(Dir, [{file_size, FileSize}]),
    MSet.

non_z_int() ->
    ?SUCHTHAT(I, int(), I =/= 0).

size() ->
    choose(1000,2000).

offset() ->
    choose(0, 5000).

string() ->
    ?LET(S, ?SUCHTHAT(L, list(choose($a, $z)), L =/= ""), list_to_binary(S)).

unlist([E]) ->
    E.
%%%-------------------------------------------------------------------
%%% Properties
%%%-------------------------------------------------------------------
prop_read_write() ->
    ?FORALL({Metric, Size, Time, Data},
            {string(), size(), offset(), non_empty_int_list()},
            begin
                os:cmd("rm -r " ++ ?DIR),
                {ok, S1} = ?S:new(?DIR, [{file_size, Size}]),
                S2 = ?S:put(S1, Metric, Time, Data),
                {ok, Res1} = ?S:get(S2, Metric, Time, length(Data)),
                Res2 = mmath_bin:to_list(Res1),
                Metrics = btrie:fetch_keys(?S:metrics(S2)),
                ?S:delete(S2),
                Res2 == Data andalso
                    Metrics == [Metric]
            end).

prop_read_len() ->
    ?FORALL({Metric, Size, Time, Data, TimeOffset, LengthOffset},
            {string(), size(), offset(), non_empty_int_list(), int(), int()},
            ?IMPLIES((Time + TimeOffset) > 0 andalso
                     (length(Data) + LengthOffset) > 0,
                     begin
                         os:cmd("rm -r " ++ ?DIR),
                         {ok, S1} = ?S:new(?DIR, [{file_size, Size}]),
                         S2 = ?S:put(S1, Metric, Time, Data),
                         ReadLen = length(Data) + LengthOffset,
                         ReadTime = Time + TimeOffset,
                         {ok, Read} = ?S:get(S2, Metric, ReadTime, ReadLen),
                         ?S:delete(S2),
                         mmath_bin:length(Read) == ReadLen
                     end)).

prop_gb_comp() ->
    ?FORALL(FileSize, size(),
            ?FORALL(D, store(FileSize),
                    begin
                        os:cmd("rm -r " ++ ?DIR),
                        {S, T} = eval(D),
                        List = ?G:to_list(T),
                        List1 = [{?S:get(S, ?M, Time, 1), V} || {Time, V} <- List],
                        ?S:delete(S),
                        List2 = [{unlist(mmath_bin:to_list(Vs)), Vt} || {{ok, Vs}, Vt} <- List1],
                        List3 = [true || {_V, _V} <- List2],
                        Len = length(List),
                        Res = length(List1) == Len andalso
                            length(List2) == Len andalso
                            length(List3) == Len,
                        ?WHENFAIL(io:format(user,
                                            "L:  ~p~n"
                                            "L1: ~p~n"
                                            "L2: ~p~n"
                                            "L3: ~p~n", [List, List1, List2, List3]),
                                  Res)
                    end
                    )).

-include("eqc_helper.hrl").
