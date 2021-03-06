-module(rafter_log).

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-include("rafter.hrl").
-include("rafter_opts.hrl").

%% API
-export([start_link/2, stop/1, append/2, check_and_append/3, binary_to_entry/1,
        entry_to_binary/1,get_last_entry/1, get_entry/2, get_term/2,
        get_last_index/1, get_last_term/1, get_config/1, set_metadata/3,
        get_metadata/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/2]).

%%=============================================================================
%% Logfile Structure
%%=============================================================================
%% @doc A log is made up of a file header and entries. The header contains file
%%      metadata and is written once at file creation. Each entry is a binary
%%      of arbitrary size containing header information and is followed by a trailer.
%%      The formats of the file header and entries are described below.
%%
%%         File Header Format
%%         -----------------------
%%         <<Version:8>>
%%
%%         Entry Format
%%         ----------------
%%         <<Sha1:20/binary, Type:8, Term:64, Index: 64, DataSize:32, Data/binary>>
%%
%%         Sha1 - hash of the rest of the entry,
%%         Type - ?CONFIG | ?OP
%%         Term - The term of the entry
%%         Index - The log index of the entry
%%         DataSize - The size of Data in bytes
%%         Data - Data encoded with term_to_binary/1
%%
%%     After each log entry a trailer is written. The trailer is used for
%%     detecting incomplete/corrupted writes, pointing to the latest config and
%%     traversing the log file backwards.
%%
%%         Trailer Format
%%         ----------------
%%         <<Crc:32, ConfigStart:64, EntryStart:64, ?MAGIC:64>>
%%
%%         Crc - checksum, computed with erlang:crc32/1, of the rest of the trailer
%%         ConfigStart - file location of last seen config,
%%         EntryStart - file location of the start of this entry
%%         ?MAGIC - magic number marking the end of the trailer.
%%                  A fully consistent log should always have
%%                  the following magic number as the last 8 bytes:
%%                  <<"\xFE\xED\xFE\xED\xFE\xED\xFE\xED">>
%%

-define(MAX_HINTS, 1000).

-type index() :: non_neg_integer().
-type offset() :: non_neg_integer().

-record(state, {
    logfile :: file:io_device(),
    version :: non_neg_integer(),
    meta_filename :: string(),
    write_location = 0 :: non_neg_integer(),
    config :: #config{},
    config_loc :: offset(),
    meta :: #meta{},
    last_entry :: #rafter_entry{},
    index = 0 :: index(),
    hints :: ets:tid(),
    hint_prunes = 0 :: non_neg_integer(),

    %% frequency of number of entries scanned in get_entry/2 calls
    seek_counts = dict:new()}).

-define(MAGIC, <<"\xFE\xED\xFE\xED\xFE\xED\xFE\xED">>).
-define(MAGIC_SIZE, 8).
-define(HEADER_SIZE, 41).
-define(TRAILER_SIZE, 28).
-define(FILE_HEADER_SIZE, 1).
-define(READ_BLOCK_SIZE, 1048576). %% 1MB
-define(LATEST_VERSION, 1).

%% Entry Types
-define(NOOP, 0).
-define(CONFIG, 1).
-define(OP, 2).
-define(ALL, [?CONFIG, ?OP]).

-ifdef(TEST).
-define(ETS_OPTS, [ordered_set, protected]).
-else.
-define(ETS_OPTS, [named_table, ordered_set, protected]).
-endif.


%%====================================================================
%% API
%%====================================================================
entry_to_binary(#rafter_entry{type=noop, term=Term, index=Index, cmd=noop}) ->
    entry_to_binary(?NOOP, Term, Index, noop);
entry_to_binary(#rafter_entry{type=config, term=Term, index=Index, cmd=Data}) ->
    entry_to_binary(?CONFIG, Term, Index, Data);
entry_to_binary(#rafter_entry{type=op, term=Term, index=Index, cmd=Data}) ->
    entry_to_binary(?OP, Term, Index, Data).

entry_to_binary(Type, Term, Index, Data) ->
    BinData = term_to_binary(Data),
    B0 = <<Type:8, Term:64, Index:64, (byte_size(BinData)):32, BinData/binary>>,
    Sha1 = crypto:hash(sha, B0),
    <<Sha1/binary, B0/binary>>.

binary_to_entry(<<Sha1:20/binary, Type:8, Term:64, Index:64, Size:32, Data/binary>>) ->
    %% We want to crash on badmatch here if if our log is corrupt
    %% TODO: Allow an operator to repair the log by truncating at that point
    %% or repair each entry 1 by 1 by consulting a good log.
    Sha1 = crypto:hash(sha, <<Type:8, Term:64, Index:64, Size:32, Data/binary>>),
    binary_to_entry(Type, Term, Index, Data).

binary_to_entry(?NOOP, Term, Index, _Data) ->
    #rafter_entry{type=noop, term=Term, index=Index, cmd=noop};
binary_to_entry(?CONFIG, Term, Index, Data) ->
    #rafter_entry{type=config, term=Term, index=Index, cmd=binary_to_term(Data)};
binary_to_entry(?OP, Term, Index, Data) ->
    #rafter_entry{type=op, term=Term, index=Index, cmd=binary_to_term(Data)}.

start_link(Peer, Opts) ->
    gen_server:start_link({local, logname(Peer)}, ?MODULE, [Peer, Opts], []).

stop(Peer) ->
    gen_server:cast(logname(Peer), stop).

%% @doc check_and_append/3 gets called in the follower state only and will only
%% truncate the log if entries don't match. It never truncates and re-writes
%% committed entries as this violates the safety of the RAFT protocol.
check_and_append(Peer, Entries, Index) ->
    gen_server:call(logname(Peer), {check_and_append, Entries, Index}).

%% @doc append/2 gets called in the leader state only, and assumes a
%% truncated log.
append(Peer, Entries) ->
    gen_server:call(logname(Peer), {append, Entries}).

get_config(Peer) ->
    gen_server:call(logname(Peer), get_config).

get_last_index(Peer) ->
    gen_server:call(logname(Peer), get_last_index).

get_last_entry(Peer) ->
    gen_server:call(logname(Peer), get_last_entry).

get_last_term(Peer) ->
    case get_last_entry(Peer) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

get_metadata(Peer) ->
    gen_server:call(logname(Peer), get_metadata).

set_metadata(Peer, VotedFor, Term) ->
    gen_server:call(logname(Peer), {set_metadata, VotedFor, Term}).

get_entry(Peer, Index) ->
    gen_server:call(logname(Peer), {get_entry, Index}).

get_term(Peer, Index) ->
    case get_entry(Peer, Index) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Name, #rafter_opts{logdir = Logdir}]) ->
    LogName = Logdir++"/rafter_"++atom_to_list(Name)++".log",
    MetaName = Logdir++"/rafter_"++atom_to_list(Name)++".meta",
    {ok, LogFile} = file:open(LogName, [append, read, binary, raw]),
    {ok, #file_info{size=Size}} = file:read_file_info(LogName),
    {ok, Meta} = read_metadata(MetaName, Size),
    {ConfigLoc, Config, _Term, Index, WriteLocation, Version} = init_file(LogFile, Size),
    LastEntry = find_last_entry(LogFile, WriteLocation),
    HintsTable = list_to_atom("rafter_hints_" ++ atom_to_list(Name)),
    {ok, #state{logfile=LogFile,
                version=Version,
                meta_filename=MetaName,
                write_location=WriteLocation,
                index=Index,
                meta=Meta,
                config=Config,
                config_loc = ConfigLoc,
                last_entry=LastEntry,
                hints=ets:new(HintsTable, ?ETS_OPTS)}}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

%% Leader Append. Entries do NOT have Indexes, as they are unlogged entries as a
%% result of client operations. Appends are based on the current index of the log.
%% Just append to the next location in the log for each entry.
handle_call({append, Entries}, _From, #state{logfile=File}=State) ->
    NewState = append_entries(File, Entries, State),
    Index = NewState#state.index,
    {reply, {ok, Index}, NewState};

handle_call(get_config, _From, #state{config=Config}=State) ->
    {reply, Config, State};

handle_call(get_last_entry, _From, #state{last_entry=undefined}=State) ->
    {reply, {ok, not_found}, State};
handle_call(get_last_entry, _From, #state{last_entry=LastEntry}=State) ->
    {reply, {ok, LastEntry}, State};

handle_call(get_last_index, _From, #state{index=Index}=State) ->
    {reply, Index, State};

handle_call(get_metadata, _, #state{meta=Meta}=State) ->
    {reply, Meta, State};

handle_call({set_metadata, VotedFor, Term}, _, #state{meta_filename=Name}=S) ->
    Meta = #meta{voted_for=VotedFor, term=Term},
    ok = write_metadata(Name, Meta),
    {reply, ok, S#state{meta=Meta}};

%% Follower append. Logs may not match. Write the first entry at the given index
%% and reset the current index maintained in #state{}. Note that Entries
%% actually contain correct indexes, since they are sent from the leader.
%% Return the last index written.
handle_call({check_and_append, Entries, Index}, _From, #state{logfile=File,
                                                              hints=Hints}=S) ->
    Loc0 = closest_forward_offset(Hints, Index),
    {Loc, Count} = get_pos(File, Loc0, Index),
    State = update_counters(Count, 0, S),
    #state{index=NewIndex}=NewState = maybe_append(Loc, Entries, State),
    {reply, {ok, NewIndex}, NewState};

handle_call({get_entry, Index}, _From, #state{logfile=File,
                                              hints=Hints}=State0) ->
    Loc = closest_forward_offset(Hints, Index),
    {Res, NewState} =
    case find_entry(File, Loc, Index) of
        {not_found, Count} ->
            State = update_counters(Count, 0, State0),
            {not_found, State};
        {Entry, NextLoc, Count} ->
            Prunes = add_hint(Hints, Index, NextLoc),
            State = update_counters(Count, Prunes, State0),
            {Entry, State}
    end,
    {reply, {ok, Res}, NewState}.

-spec update_counters(offset(), non_neg_integer(), #state{}) -> #state{}.
update_counters(Distance, Prunes, #state{hint_prunes=Prunes0,
                                                   seek_counts=Dict0}
                                                   =State) ->
    Dict = dict:update_counter(Distance, 1, Dict0),
    State#state{hint_prunes=Prunes0 + Prunes, seek_counts=Dict}.

-spec closest_forward_offset(ets:tid(), index()) -> offset().
closest_forward_offset(Hints, Index) ->
    case ets:prev(Hints, Index) of
        '$end_of_table' ->
            ?FILE_HEADER_SIZE;
        Key ->
            [{Key, Loc0}] = ets:lookup(Hints, Key),
            Loc0
    end.

-spec add_hint(ets:tid(), index(), offset()) -> non_neg_integer().
add_hint(Hints, Index, Loc) ->
    {size, Size} = lists:keyfind(size, 1, ets:info(Hints)),
    case Size >= ?MAX_HINTS of
        true ->
            delete_hints(Hints),
            true = ets:insert(Hints, {Index, Loc}),
            1;
        false ->
            true = ets:insert(Hints, {Index, Loc}),
            0
    end.

%% Delete every 10th hint
delete_hints(Hints) ->
    L = ets:tab2list(Hints),
    {_, ToDelete} =
    lists:foldl(fun({Index, _}, {Count, Deleted}) when Count rem 10 =:= 0 ->
                       {Count+1, [Index | Deleted]};
                   ({_, _}, {Count, Deleted}) ->
                       {Count+1, Deleted}
                end, {0, []}, L),
    [true = ets:delete(Hints, Index) || Index <- ToDelete].

handle_cast(stop, #state{logfile=File}=State) ->
    ok = file:close(File),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal Functions
%%====================================================================

maybe_append(_, [], State) ->
    State;
maybe_append(eof, [Entry | Entries], State) ->
    NewState = write_entry(Entry, State),
    maybe_append(eof, Entries, NewState);
maybe_append(Loc, [Entry | Entries], State=#state{logfile=File}) ->
    #rafter_entry{index=Index, term=Term}=Entry,
    case read_entry(File, Loc) of
        {entry, Data, NewLocation} ->
            case binary_to_entry(Data) of
                %% We already have this entry in the log. Continue.
                #rafter_entry{index=Index, term=Term} ->
                    maybe_append(NewLocation, Entries, State);
                #rafter_entry{index=Index, term=_} ->
                    NewState = truncate_and_write(File, Loc, Entry, State),
                    maybe_append(eof, Entries, NewState)
            end;
        eof ->
            NewState = truncate_and_write(File, Loc, Entry, State),
            maybe_append(eof, Entries, NewState)
    end.

truncate_and_write(File, Loc, Entry, State0) ->
    ok = truncate(File, Loc),
    State1 = maybe_reset_config(File, Loc, State0),
    State2 = State1#state{write_location=Loc},
    write_entry(Entry, State2).

-spec maybe_reset_config(file:io_device(), non_neg_integer(), #state{}) ->
    #state{}.
maybe_reset_config(File, Loc, #state{config_loc=ConfigLoc}=State) ->
    case ConfigLoc >= Loc of
        true ->
            reset_config(File, Loc, State);
        false ->
            State
    end.

-spec reset_config(file:io_device(), non_neg_integer(), #state{}) -> #state{}.
reset_config(File, Loc, State) ->
    case Loc of
        ?FILE_HEADER_SIZE ->
            %% Empty file, so reset to blank config
            State#state{config_loc=0, config=#config{}};
        _ ->
            %% Get config from the previous trailer
            TrailerLoc = Loc - ?TRAILER_SIZE,
            {ok, Trailer} = file:pread(File, TrailerLoc, ?TRAILER_SIZE),
            <<CRC:32, Rest/binary>> = Trailer,
            %% validate checksum, fail fast.
            CRC = erlang:crc32(Rest),
            <<ConfigLoc:64, _/binary>> = Rest,
            case ConfigLoc of
                0 ->
                    State#state{config_loc=0, config=#config{}};
                _ ->
                    {ok, Config} = read_config(File, ConfigLoc),
                    State#state{config_loc=ConfigLoc, config=Config}
            end
    end.

logname({Name, _Node}) ->
    list_to_atom(atom_to_list(Name) ++ "_log");
logname(Me) ->
    list_to_atom(atom_to_list(Me) ++ "_log").

init_file(File, 0) ->
    {ok, Loc} = write_file_header(File),
    {0, #config{}, 0, 0, Loc, ?LATEST_VERSION};
init_file(File, Size) ->
    case repair_file(File, Size) of
        {ok, ConfigLoc, Term, Index, WriteLoc} ->
            {ok, Version} = read_file_header(File),
            {ok, Config} = read_config(File, ConfigLoc),
            {ConfigLoc, Config, Term, Index, WriteLoc, Version};
        empty_file ->
            {ok, Loc} = write_file_header(File),
            {0, #config{}, 0, 0, Loc, ?LATEST_VERSION}
    end.

read_file_header(File) ->
    {ok, <<Version:8>>} = file:pread(File, 0, ?FILE_HEADER_SIZE),
    {ok, Version}.

write_file_header(File) ->
    ok = file:write(File, <<?LATEST_VERSION:8>>),
    {ok, ?FILE_HEADER_SIZE}.

make_trailer(EntryStart, ConfigStart) ->
    T = <<ConfigStart:64, EntryStart:64, ?MAGIC/binary >>,
    Crc = erlang:crc32(T),
    <<Crc:32, T/binary>>.

append_entries(File, Entries, State) ->
    NewState = lists:foldl(fun append_entry/2, State, Entries),
    ok = file:sync(File),
    NewState.

%% Append an entry at the next location in the log. The entry does not yet have an
%% index, so add one.
append_entry(Entry, State=#state{index=Index}) ->
    NewIndex = Index + 1,
    NewEntry = Entry#rafter_entry{index=NewIndex},
    write_entry(NewEntry, State).

%% Precondition: each entry must have an index at this point.
write_entry(Entry, State) ->
    #rafter_entry{index=Index, type=Type, cmd=Cmd}=Entry,
    #state{write_location=Loc, config=Config, config_loc=ConfigLoc,
           logfile=File} = State,
    BinEntry = entry_to_binary(Entry),
    {NewConfigLoc, NewConfig} =
        maybe_update_config(Type, Loc, Cmd, ConfigLoc, Config),
    Trailer = make_trailer(Loc, NewConfigLoc),
    ok = file:write(File, <<BinEntry/binary, Trailer/binary>>),
    NewLoc = Loc + byte_size(BinEntry) + ?TRAILER_SIZE,
    State#state{index=Index,
            config=NewConfig,
            write_location=NewLoc,
            config_loc=NewConfigLoc,
            last_entry=Entry}.

maybe_update_config(config, NewConfigLoc, NewConfig, _, _) ->
    {NewConfigLoc, NewConfig};
maybe_update_config(_Type, _, _, CurConfigLoc, CurConfig) ->
    {CurConfigLoc, CurConfig}.

read_config(File, Loc) ->
    {entry, Data, _} = read_entry(File, Loc),
    #rafter_entry{type=config, cmd=Config} = binary_to_entry(Data),
    {ok, Config}.

%% TODO: Write to a tmp file then rename so the write is always atomic and the
%% metadata file cannot become partially written.
write_metadata(Filename, Meta) ->
    ok = file:write_file(Filename, term_to_binary(Meta)).

read_metadata(Filename, FileSize) ->
    case file:read_file(Filename) of
        {ok, Bin} ->
            {ok, binary_to_term(Bin)};
        {error, enoent} when FileSize =< ?FILE_HEADER_SIZE ->
            {ok, #meta{}};
        {error, Reason} ->
            io:format("Failed to open metadata file: ~p. Reason = ~p~n",
                [Filename, Reason]),
            {ok, #meta{}}
    end.

truncate(File, Pos) ->
    {ok, _} = file:position(File, Pos),
    file:truncate(File).

maybe_truncate(File, TruncateAt, FileSize) ->
    case TruncateAt < FileSize of
        true ->
            ok = truncate(File, TruncateAt);
        false ->
            ok
    end.

repair_file(File, Size) ->
    case scan_for_trailer(File, Size) of
        {ok, ConfigStart, EntryStart, TruncateAt} ->
            maybe_truncate(File, TruncateAt, Size),
            {entry, Data, _} = read_entry(File, EntryStart),
            #rafter_entry{term=Term, index=Index} = binary_to_entry(Data),
            {ok, ConfigStart, Term, Index, TruncateAt};
        not_found ->
            io:format("NOT FOUND: Size = ~p~n", [Size]),
            ok = truncate(File, 0),
            empty_file
    end.

scan_for_trailer(File, Loc) ->
    case find_magic_number(File, Loc) of
        {ok, MagicLoc} ->
            case file:pread(File, MagicLoc - (?TRAILER_SIZE-?MAGIC_SIZE), ?TRAILER_SIZE) of
                {ok, <<Crc:32, ConfigStart:64, EntryStart:64, _/binary >>} ->
                    case erlang:crc32(<<ConfigStart:64, EntryStart:64, ?MAGIC/binary >>) of
                        Crc ->
                            {ok, ConfigStart, EntryStart, MagicLoc + 8};
                        _ ->
                            scan_for_trailer(File, MagicLoc)
                    end;
                eof ->
                    not_found
            end;
        not_found ->
            not_found
    end.

read_block(File, Loc) ->
    case Loc < ?READ_BLOCK_SIZE of
        true ->
            {ok, Buffer} = file:pread(File, 0, Loc),
            {Buffer, 0};
        false ->
            Start = Loc - ?READ_BLOCK_SIZE,
            {ok, Buffer} = file:pread(File, Start, ?READ_BLOCK_SIZE),
            {Buffer, Start}
    end.

%% @doc Continuously read blocks from the file and search backwards until the
%% magic number is found or we reach the beginning of the file.
find_magic_number(File, Loc) ->
    {Block, Start} = read_block(File, Loc),
    case find_last_magic_number_in_block(Block) of
        {ok, Offset} ->
            io:format("Magic Number found at ~p~n", [Start+Offset]),
            {ok, Start+Offset};
        not_found ->
            case Start of
                0 ->
                    not_found;
                _ ->
                    %% Ensure we search the overlapping 8 bytes between blocks
                    find_magic_number(File, Start+8)
            end
    end.

-spec find_last_magic_number_in_block(binary()) ->
    {ok, non_neg_integer()} | not_found.
find_last_magic_number_in_block(Block) ->
    case string:rstr(binary_to_list(Block), binary_to_list(?MAGIC)) of
        0 ->
            not_found;
        Index ->
            %% We want the 0 based binary offset, not the 1 based list offset.
            {ok, Index - 1}
    end.

get_pos(File, Loc, Index) ->
    get_pos(File, Loc, Index, 0).

get_pos(File, Loc, Index, Count) ->
    case file:pread(File, Loc, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, Index:64, _DataSize:32>>} ->
            {Loc, Count};
        {ok, <<_:37/binary, DataSize:32>>} ->
            get_pos(File, next_entry_loc(Loc, DataSize), Index, Count+1);
        eof ->
            {eof, Count}
    end.

%% @doc Find an entry at the given index in a file. Search forward from Loc.
find_entry(File, Loc, Index) ->
    find_entry(File, Loc, Index, 0).

find_entry(File, Loc, Index, Count) ->
    case file:pread(File, Loc, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, Index:64, _DataSize:32>>=Header} ->
            case read_data(File, Loc + ?HEADER_SIZE, Header) of
                {entry, Entry, _} ->
                    {binary_to_entry(Entry), Loc, Count};
                eof ->
                    %% This should only occur if the entry is currently being written.
                    {not_found, Count}
            end;
        {ok, <<_:37/binary, DataSize:32>>} ->
            NextLoc = next_entry_loc(Loc, DataSize),
            find_entry(File, NextLoc, Index, Count+1);
        eof ->
            {not_found, Count}
    end.

next_entry_loc(Loc, DataSize) ->
    Loc + ?HEADER_SIZE + DataSize + ?TRAILER_SIZE.

find_last_entry(_File, WriteLocation) when WriteLocation =< ?FILE_HEADER_SIZE ->
    undefined;
find_last_entry(File, WriteLocation) ->
    {ok, <<_:32, _:64, EntryStart:64, _/binary>>} =
        file:pread(File, WriteLocation - ?TRAILER_SIZE, ?TRAILER_SIZE),
    {entry, Entry, _} = read_entry(File, EntryStart),
    binary_to_entry(Entry).

%% @doc This function reads the next entry from the log at the given location
%% and returns {entry, Entry, NewLocation}. If the end of file has been reached,
%% return eof to the client. Errors are fail-fast.
-spec read_entry(file:io_device(), non_neg_integer()) ->
    {entry, binary(), non_neg_integer()} | {skip, non_neg_integer()} | eof.
read_entry(File, Location) ->
    case file:pread(File, Location, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, _Index:64, _DataSize:32>>=Header} ->
            read_data(File, Location + ?HEADER_SIZE, Header);
        eof ->
            eof
    end.

-spec read_data(file:io_device(), non_neg_integer(), binary()) ->
    {entry, binary(), non_neg_integer()} | eof.
read_data(File, Location, <<Sha1:20/binary, Type:8, Term:64, Index:64, Size:32>>=H) ->
    case file:pread(File, Location, Size) of
        {ok, Data} ->
            %% Fail-fast Integrity check. TODO: Offer user repair options?
            Sha1 = crypto:hash(sha, <<Type:8, Term:64, Index:64, Size:32, Data/binary>>),
            NewLocation = Location + Size + ?TRAILER_SIZE,
            {entry, <<H/binary, Data/binary>>, NewLocation};
        eof ->
            eof
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(PEER, test).

cleanup() ->
    os:cmd("rm -rf /tmp/rafter_test*").

%% REGRESSION: - see https://github.com/andrewjstone/rafter/pull/32
log_overwrite_test() ->
    cleanup(),
    Opts = #rafter_opts{logdir="/tmp"},
    {ok, _Pid} = rafter_log:start_link(?PEER, Opts),
    assert_empty(),

    %% We are appending Entry1 as the leader, so it has no index.
    Entry1 = #rafter_entry{type=config, term=1, index=undefined,
                           cmd=#config{state=stable}},
    assert_leader_append(1, 1, Entry1),
    ConfigLoc0 = assert_stable_config(),

    Entry2 = #rafter_entry{type=noop, term=1, index=undefined, cmd=noop},
    assert_leader_append(2, 1, Entry2),
    ConfigLoc1 = assert_stable_config(),
    ?assertEqual(ConfigLoc0, ConfigLoc1),

    %% A new leader takes over and this log gets its entry overwritten.
    %% In reality index 1 will always be a #config{}, but this validates the
    %% test that config gets reset.
    Entry = #rafter_entry{type=noop, term=2, index=1, cmd=noop},
    assert_follower_append(Entry),
    assert_blank_config(),

    %% This peer becomes leader again and appends 2 configs
    Entry3 = #rafter_entry{type=config, term=3, cmd=#config{state=stable}},
    assert_leader_append(2, 3, Entry3),
    ConfigLoc2 = assert_stable_config(),

    Entry4 = #rafter_entry{type=config, term=3, cmd=#config{state=stable}},
    assert_leader_append(3, 3, Entry4),
    ConfigLoc3 = assert_stable_config(),
    ?assertNotEqual(ConfigLoc2, ConfigLoc3),

    %% A new leader takes over and truncates the last config
    Entry5 = #rafter_entry{type=noop, term=4, index=3, cmd=noop},
    assert_follower_append(Entry5),
    ConfigLoc4 = assert_stable_config(),
    ?assertEqual(ConfigLoc2, ConfigLoc4),
    Index = rafter_log:get_last_index(?PEER),
    ?assertEqual(Index, 3),
    {ok, Entry6} = rafter_log:get_last_entry(?PEER),
    ?assertEqual(Entry5, Entry6),

    %% A new leader takes over and truncates the last stable config
    %% New config is at position 0
    Entry7 = #rafter_entry{type=noop, term=5, index=2, cmd=noop},
    assert_follower_append(Entry7),
    assert_blank_config(),
    Index2 = rafter_log:get_last_index(?PEER),
    ?assertEqual(Index2, 2),
    {ok, Entry8} = rafter_log:get_last_entry(?PEER),
    ?assertEqual(Entry7, Entry8),

    rafter_log:stop(?PEER).

assert_leader_append(ExpectedIndex, ExpectedTerm, Entry) ->
    {ok, Index} = rafter_log:append(?PEER, [Entry]),
    ?assertEqual(ExpectedIndex, Index),
    {ok, Entry1} = rafter_log:get_entry(?PEER, Index),
    {ok, Entry1} = rafter_log:get_last_entry(?PEER),
    Index = rafter_log:get_last_index(?PEER),
    ?assertEqual(Entry1#rafter_entry.index, ExpectedIndex),
    ?assertEqual(Entry1#rafter_entry.term, ExpectedTerm).

assert_follower_append(Entry) ->
    %% Note that follower appends always have indexes since they are sent
    %% from the leader who has already written the entry to its log.
    Index = Entry#rafter_entry.index,
    {ok, Index} = rafter_log:check_and_append(?PEER, [Entry], Index),
    {ok, Entry1} = rafter_log:get_entry(?PEER, Index),
    ?assertEqual(Entry, Entry1).

assert_blank_config() ->
    Config = rafter_log:get_config(?PEER),
    ?assertEqual(blank, Config#config.state),
    State = sys:get_state(logname(?PEER)),
    ?assertEqual(State#state.config_loc, 0).

assert_stable_config() ->
    Config = rafter_log:get_config(?PEER),
    ?assertEqual(stable, Config#config.state),
    State = sys:get_state(logname(?PEER)),
    ConfigLoc = State#state.config_loc,
    ?assertNotEqual(ConfigLoc, 0),
    ConfigLoc.

assert_empty() ->
    ?assertEqual({ok, not_found}, rafter_log:get_last_entry(?PEER)),
    ?assertEqual(0, rafter_log:get_last_index(?PEER)),
    assert_blank_config().

-endif.
