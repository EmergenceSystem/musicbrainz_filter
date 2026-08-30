%%%-------------------------------------------------------------------
%%% @doc MusicBrainz music metadata search agent.
%%%
%%% Searches the MusicBrainz open music encyclopedia for artists and
%%% returns embryos with name, disambiguation, and profile URL.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(musicbrainz_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(ARTIST_URL,
    "https://musicbrainz.org/ws/2/artist"
    "?fmt=json&limit=10&query=").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"musicbrainz">>, <<"music">>,
                                      <<"artists">>, <<"albums">>,
                                      <<"songs">>, <<"metadata">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_Type, _Args) ->
    case musicbrainz_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(musicbrainz_filter_query_listener),
    catch em_pop_sup:stop_node(musicbrainz_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(musicbrainz_filter, pop_port,   9538),
    QueryPort = application:get_env(musicbrainz_filter, query_port, 9539),
    Seeds     = application:get_env(musicbrainz_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(musicbrainz_filter),
    catch cowboy:stop_listener(musicbrainz_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(musicbrainz_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => musicbrainz_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(musicbrainz_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[musicbrainz_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Query, Timeout} = extract_params(JsonBinary),
    fetch_results(Query, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Query   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map,
                          maps:get(<<"artist">>, Map, <<"">>)))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Query, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

fetch_results("", _) -> [];
fetch_results(Query, Timeout) ->
    Url = lists:flatten(io_lib:format("~s~s", [?ARTIST_URL, uri_string:quote(Query)])),
    %% MusicBrainz requires a descriptive User-Agent
    Headers = [{"User-Agent", "musicbrainz_filter/1.0 (EmergenceSystem)"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_results(Body);
        _ ->
            []
    end.

parse_results(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"artists">> := Artists} when is_list(Artists) ->
            lists:filtermap(fun build_embryo/1, Artists);
        _ ->
            []
    catch
        _:_ -> []
    end.

build_embryo(#{<<"id">> := Id, <<"name">> := Name} = Artist) ->
    Disambig = maps:get(<<"disambiguation">>, Artist, <<"">>),
    AType    = maps:get(<<"type">>,           Artist, <<"">>),
    Url      = lists:flatten(io_lib:format(
        "https://musicbrainz.org/artist/~s", [binary_to_list(Id)])),
    Resume   = format_resume(AType, Disambig),
    {true, #{
        <<"properties">> => #{
            <<"url">>    => unicode:characters_to_binary(Url),
            <<"resume">> => Resume,
            <<"title">>  => Name,
            <<"mbid">>   => Id,
            <<"source">> => <<"musicbrainz.org">>
        }
    }};
build_embryo(_) ->
    false.

format_resume(Type, Disambig) ->
    T = if is_binary(Type),    byte_size(Type)    > 0 -> binary_to_list(Type);    true -> "" end,
    D = if is_binary(Disambig),byte_size(Disambig)> 0 -> binary_to_list(Disambig);true -> "" end,
    case {T, D} of
        {"", ""}  -> <<"">>;
        {T2, ""}  -> unicode:characters_to_binary(T2);
        {"", D2}  -> unicode:characters_to_binary(D2);
        {T2, D2}  -> unicode:characters_to_binary(T2 ++ " — " ++ D2)
    end.
