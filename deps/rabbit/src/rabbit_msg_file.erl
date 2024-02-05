%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_msg_file).

-export([scan/4,
         scan_ids/3]).

-export([test/1,
         test_orig/1]).

%%----------------------------------------------------------------------------

-define(INTEGER_SIZE_BYTES,      8).
-define(INTEGER_SIZE_BITS,       (8 * ?INTEGER_SIZE_BYTES)).
-define(WRITE_OK_SIZE_BITS,      8).
-define(WRITE_OK_MARKER,         255).
-define(FILE_PACKING_ADJUSTMENT, (1 + ?INTEGER_SIZE_BYTES)).
-define(MSG_ID_SIZE_BYTES,       16).
-define(MSG_ID_SIZE_BITS,        (8 * ?MSG_ID_SIZE_BYTES)).
-define(SCAN_BLOCK_SIZE,         4194304). %% 4MB

%%----------------------------------------------------------------------------

-type io_device() :: any().
-type position() :: non_neg_integer().
-type msg_size() :: non_neg_integer().
-type file_size() :: non_neg_integer().
-type message_accumulator(A) ::
        fun (({rabbit_types:msg_id(), msg_size(), position(), binary()}, A) ->
            A).

%%----------------------------------------------------------------------------
test(File) ->
    {ok, Fd} = file:open(File, [read, binary]),
    try
        scan_ids(Fd, filelib:file_size(File), [])
    after
        file:close(Fd)
    end.

test_orig(File) ->
    {ok, Fd} = file:open(File, [read, binary]),
    try
        scan(Fd, filelib:file_size(File),
             fun({MsgId,  TotalSize, Offset, _Msg}, Acc) ->
                     [{MsgId, TotalSize, Offset} | Acc]
             end,
             [])
    after
        file:close(Fd)
    end.


scan_ids(FileHdl, FileSize, Acc) ->
    scan_ids(FileHdl, FileSize, <<>>, 0, 0, Acc).


scan_ids(_FileHdl, FileSize, _Data, FileSize, ScanOffset, Acc) ->
    {ok, Acc, ScanOffset};
scan_ids(FileHdl, _FileSize, _Data, _ReadOffset, ScanOffset, Acc) ->
    %%Read = lists:min([?SCAN_BLOCK_SIZE, (FileSize - ReadOffset)]),
    case read_file(FileHdl) of
        {ok, Data1} ->
            scan_header(Data1, ScanOffset, Acc, FileHdl);
        _KO ->
            {ok, Acc, ScanOffset, _KO, ?FUNCTION_NAME}
    end.

scan_header(<<>>, Offset, Acc, _FileHdl) ->
    {ok, Acc, Offset, eof};
scan_header(<<0:?INTEGER_SIZE_BITS, _Rest/binary>>, Offset, Acc, _FileHdl) ->
    {ok, Acc, Offset, zero}; %% Nothing to do other than stop.
scan_header(<<Size:?INTEGER_SIZE_BITS, MsgIdNum:?MSG_ID_SIZE_BITS, Rest/binary>>, Offset, Acc, FileHdl) ->
    <<MsgId:?MSG_ID_SIZE_BYTES/binary>> =
                <<MsgIdNum:?MSG_ID_SIZE_BITS>>,
    TotalSize = Size + ?FILE_PACKING_ADJUSTMENT,
    MsgSize = Size - ?MSG_ID_SIZE_BYTES,
    skip_body(Rest, MsgSize, {MsgId, TotalSize, Offset}, Acc, FileHdl);
scan_header(Rest, Offset, Acc, FileHdl) ->
    MissingSize = ?INTEGER_SIZE_BYTES + ?MSG_ID_SIZE_BYTES - byte_size(Rest),
    case read_file(FileHdl) of
        %%{ok, Data} when byte_size(Data) >= MissingSize ->
        {ok, Data} when byte_size(Data) >= 0 ->
            %% FIXME subbinary?
            <<Header2:MissingSize, Rest2/binary>> = Data,
            %% Missig size =< 8+16-1
            <<Size:?INTEGER_SIZE_BITS, MsgIdNum:?MSG_ID_SIZE_BITS>> = <<Rest/binary, Header2/binary>>,
            TotalSize = Size + ?FILE_PACKING_ADJUSTMENT,
            MsgSize = Size - ?MSG_ID_SIZE_BYTES,
            <<MsgId:?MSG_ID_SIZE_BYTES/binary>> =
                <<MsgIdNum:?MSG_ID_SIZE_BITS>>,
            skip_body(Rest2, MsgSize, {MsgId, TotalSize, Offset}, Acc, FileHdl);
%%            scan_header(<<Rest/binary, Data/binary>>, Offset, Acc, FileHdl);
        _KO ->
            {ok, Acc, Offset, _KO, ?FUNCTION_NAME}
    end.

skip_body(Data, MsgSize, Entry, Acc, FileHdl) ->
    case Data of
        <<_:MsgSize/binary, Rest/binary>> ->
            scan_write_marker(Rest, Entry, Acc, FileHdl);
        _ ->
            %% need more data
            MissingSize = MsgSize - byte_size(Data),
            case read_file(FileHdl) of
                {ok, Data2} when byte_size(Data) > 0 ->
                    skip_body(Data2, MissingSize, Entry, Acc, FileHdl);
                _KO ->
                    {_MsgId, _TotalSize, Offset} = Entry,
                    {ok, Acc, Offset, _KO, ?FUNCTION_NAME}
            end
    end.

scan_write_marker(<<WriteMarker:?WRITE_OK_SIZE_BITS, Rest/binary>>, Entry, Acc, FileHdl) ->
    Acc2 =
        case WriteMarker of
            ?WRITE_OK_MARKER ->
                %% full entry available
                [Entry|Acc];
            _ ->
                Acc
        end,
    {_MsgId, TotalSize, Offset} = Entry,
    scan_header(Rest, Offset + TotalSize, Acc2, FileHdl);
scan_write_marker(<<>>, Entry, Acc, FileHdl) ->
    %% 1 byte missing
    case read_file(FileHdl) of
        {ok, Data} when byte_size(Data) > 0 ->
            scan_write_marker(Data, Entry, Acc, FileHdl);
        _KO ->
            {_MsgId, _TotalSize, Offset} = Entry,
            {ok, Acc, Offset, _KO, ?FUNCTION_NAME}
    end.

read_file(FileHdl) ->
    read_file(FileHdl, ?SCAN_BLOCK_SIZE).

read_file(FileHdl, Size) ->
    %%file_handle_cache:read(FileHdl, Size)
    file:read(FileHdl, Size).


-spec scan(io_device(), file_size(), message_accumulator(A), A) ->
          {'ok', A, position()}.

scan(FileHdl, FileSize, Fun, Acc) when FileSize >= 0 ->
    scan(FileHdl, FileSize, <<>>, 0, 0, Fun, Acc).

scan(_FileHdl, FileSize, _Data, FileSize, ScanOffset, _Fun, Acc) ->
    {ok, Acc, ScanOffset};
scan(FileHdl, FileSize, Data, ReadOffset, ScanOffset, Fun, Acc) ->
    Read = lists:min([?SCAN_BLOCK_SIZE, (FileSize - ReadOffset)]),
    case read_file(FileHdl, Read) of
        {ok, Data1} ->
            {Data2, Acc1, ScanOffset1} =
                scanner(<<Data/binary, Data1/binary>>, ScanOffset, Fun, Acc),
            ReadOffset1 = ReadOffset + size(Data1),
            scan(FileHdl, FileSize, Data2, ReadOffset1, ScanOffset1, Fun, Acc1);
        _KO ->
            {ok, Acc, ScanOffset}
    end.

scanner(<<>>, Offset, _Fun, Acc) ->
    {<<>>, Acc, Offset};
scanner(<<0:?INTEGER_SIZE_BITS, _Rest/binary>>, Offset, _Fun, Acc) ->
    {<<>>, Acc, Offset}; %% Nothing to do other than stop.
scanner(<<Size:?INTEGER_SIZE_BITS, MsgIdAndMsg:Size/binary,
          WriteMarker:?WRITE_OK_SIZE_BITS, Rest/binary>>, Offset, Fun, Acc) ->
    TotalSize = Size + ?FILE_PACKING_ADJUSTMENT,
    case WriteMarker of
        ?WRITE_OK_MARKER ->
            %% Here we take option 5 from
            %% https://www.erlang.org/cgi-bin/ezmlm-cgi?2:mss:1569 in
            %% which we read the MsgId as a number, and then convert it
            %% back to a binary in order to work around bugs in
            %% Erlang's GC.
            <<MsgIdNum:?MSG_ID_SIZE_BITS, Msg/binary>> =
                <<MsgIdAndMsg:Size/binary>>,
            <<MsgId:?MSG_ID_SIZE_BYTES/binary>> =
                <<MsgIdNum:?MSG_ID_SIZE_BITS>>,
            scanner(Rest, Offset + TotalSize, Fun,
                    Fun({MsgId, TotalSize, Offset, Msg}, Acc));
        _ ->
            scanner(Rest, Offset + TotalSize, Fun, Acc)
    end;
scanner(Data, Offset, _Fun, Acc) ->
    {Data, Acc, Offset}.
