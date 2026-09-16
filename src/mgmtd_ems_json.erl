%%%-------------------------------------------------------------------
%% @doc JSON encode/decode. Uses OTP `json` when present (OTP 27+),
%% otherwise jsx, returning maps with binary keys.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_json).

-export([encode/1, decode/1]).

-spec encode(term()) -> binary().
encode(Term) ->
    case otp_json() of
        true ->
            iolist_to_binary(json:encode(Term));
        false ->
            jsx:encode(Term)
    end.

-spec decode(binary()) -> {ok, term()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try
        Term = case otp_json() of
                   true ->
                       json:decode(Bin);
                   false ->
                       jsx:decode(Bin, [return_maps])
               end,
        {ok, Term}
    catch
        error:Reason ->
            {error, Reason}
    end.

otp_json() ->
    case code:ensure_loaded(json) of
        {module, json} ->
            erlang:function_exported(json, encode, 1)
                andalso erlang:function_exported(json, decode, 1);
        _ ->
            false
    end.
