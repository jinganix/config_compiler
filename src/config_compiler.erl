
%% Copyright (c) JinGan <jg_513@163.com>

-module(config_compiler).

%% External API
-export([
    scan_dir/0,
    scan_dir/1,
    scan_file/1,
    scan_file/2
]).

-define(DEFAULT_OPTS, [
    {imports_dir, "config"},
    {code_dir, "src/config"},
    {ebin_dir, "ebin"},
    {load, true},
    {converter, []}
]).

-record(collect, {
    module,
    props = [],
    records = []
}).

-record(state, {collect}).

%% External API
scan_dir() ->
    scan_dir([]).

scan_dir(Options) ->
    Options0 = init_options(Options, ?DEFAULT_OPTS),
    ImportPath = proplists:get_value(imports_dir, Options0),
    Collects0 = collect_dir(ImportPath),
    check_collects(Collects0),
    Collects = convert_collects(Collects0, Options0),
    Forms = init_forms(),
    lists:foreach(fun(Collect) ->
        output(Collect, Forms, Options0)
    end, Collects).

scan_file(FileName) ->
    scan_file(FileName, []).

scan_file(Module, Options) when is_atom(Module) ->
    Filename = erlang:atom_to_list(Module) ++ ".config",
    scan_file(Filename, Options);
scan_file(Filename, Options) ->
    Options0 = init_options(Options, ?DEFAULT_OPTS),
    ImportPath = proplists:get_value(imports_dir, Options0),
    Filename0 =
        case filename:absname(Filename) of
            Filename ->
                Filename;
            _ ->
                filename:absname(Filename, ImportPath)
        end,
    Collects = collect_file(Filename0),
    check_collects(Collects),
    Collects0 = convert_collects(Collects, Options0),
    Forms = init_forms(),
    lists:foreach(fun(Collect) ->
        output(Collect, Forms, Options0)
    end, Collects0).

%% Internal API
init_forms() ->
    Strings = [
        "-module(xt_conf).",
        "-export([get/1, all/0, keys/0, pall/0, pkeys/0, rall/0, rkeys/0]).",
        "get(_) -> undefined.",
        "all() -> [].",
        "keys() -> [].",
        "pall() -> [].",
        "pkeys() -> [].",
        "rall() -> [].",
        "rkeys() -> []."
    ],
    [begin
        {ok, Tokens, _} = erl_scan:string(String),
        {ok, Form} = erl_parse:parse_form(Tokens),
        Form
    end || String <- Strings].

init_options(Options, Default) ->
    lists:foldl(fun({Key, Value0}, Acc) ->
        case proplists:is_defined(Key, Options) of
            true ->
                [{Key, proplists:get_value(Key, Options)} | Acc];
            false ->
                [{Key, Value0} | Acc]
        end
    end, [], Default).

output(Collect, Forms0, Options) ->
    Module = Collect#collect.module,
    State = #state{collect = Collect},
    {Forms, _State} = filter_forms(Forms0, State),
    output_code(Module, Forms, Options),
    output_ebin(Module, Forms, Options).

output_code(Module, Forms, Options) ->
    case proplists:get_value(code_dir, Options) of
        CodeDir when is_list(CodeDir) ->
            filelib:ensure_dir(filename:absname(CodeDir) ++ "/"),
            Filename = filename:join(CodeDir, atom_to_list(Module)) ++ ".erl",
            file:write_file(Filename, erl_prettypr:format(erl_syntax:form_list(Forms)));
        _ ->
            ok
    end.

output_ebin(Module, Forms, Options) ->
    Binary =
        case compile:forms(Forms) of
            {ok, Module, Binary0} ->
                Binary0;
            {ok, Module, Binary0, _Warnings} ->
                Binary0
        end,
    case proplists:get_value(load, Options) of
        false ->
            ok;
        _ ->
            code:load_binary(Module, atom_to_list(Module) ++ ".erl", Binary)
    end,
    case proplists:get_value(ebin_dir, Options) of
        EbinDir when is_list(EbinDir) ->
            Filename = filename:join(EbinDir, atom_to_list(Module)) ++ ".beam",
            file:write_file(Filename, Binary);
        _ ->
            ok
    end.

collect_dir(Path) ->
    filelib:fold_files(Path, ".+\.config", true, fun(Filename, Acc) ->
        Basename = filename:basename(Filename, ".config"),
        Module = atomize(Basename),
        case file:consult(Filename) of
            {ok, Terms} ->
                collect_terms(Terms, Module, Acc);
            {error, Reason} ->
                exit(error, {Reason, Filename})
        end
    end, []).

collect_file(Filename) ->
    Basename = filename:basename(Filename, ".config"),
    Module = atomize(Basename),
    case file:consult(Filename) of
        {ok, Terms} ->
            collect_terms(Terms, Module, []);
        {error, Reason} ->
            exit(error, {Reason, Filename})
    end.

check_collects(Collects) ->
    lists:foreach(fun
        (#collect{props = Props, records = Records}) ->
            Keys = [Key || {Key, _} <- Props] ++ [element(2, Record) || Record <- Records],
            check_duplicate(Keys);
        (Collect) ->
            exit({bad_collect, Collect})
    end, Collects).

convert_collects(Collects, Options) ->
    case proplists:get_value(converter, Options) of
        Converters when is_list(Converters), Converters =/= [] ->
            lists:foldl(fun
                (#collect{module = Module, props = Props, records = Records} = Collect0, Acc) ->
                    case proplists:get_value(Module, Converters) of
                        undefined ->
                            [Collect0 | Acc];
                        Func ->
                            Pairs0 = Func(Props),
                            Records0 = Func(Records),
                            [Collect0#collect{props = Pairs0, records = Records0} | Acc]
                    end;
                (Collect, _Acc) ->
                    exit({bad_collect, Collect})
            end, [], Collects);
        _ ->
            Collects
    end.

check_duplicate(List) ->
    Set = sets:from_list(List),
    case length(List) =:= sets:size(Set) of
        true ->
            ok;
        false ->
            Duplicate = List -- sets:to_list(Set),
            exit({duplicate, Duplicate})
    end.

collect_terms([{Key, Value} | Tail], Module, Acc) ->
    Collect =
        case lists:keyfind(Module, #collect.module, Acc) of
            #collect{props = Props} = Collect0 ->
                Collect0#collect{props = [{Key, Value} | Props]};
            _ ->
                #collect{module = Module, props = [{Key, Value}], records = []}
        end,
    Collects = lists:keystore(Collect#collect.module, #collect.module, Acc, Collect),
    collect_terms(Tail, Module, Collects);
collect_terms([Head | Tail], Module, Acc) ->
    Collect =
        if
            is_tuple(Head), tuple_size(Head) >= 3 ->
                case lists:keyfind(Module, #collect.module, Acc) of
                    #collect{records = Records} = Collect0 ->
                        Collect0#collect{records = [Head | Records]};
                    _ ->
                        #collect{module = Module, props = [], records = [Head]}
                end;
            true ->
                exit({bad_config, {Module, Head}})
        end,
    Collects = lists:keystore(Collect#collect.module, #collect.module, Acc, Collect),
    collect_terms(Tail, Module, Collects);
collect_terms([], _Module, Acc) ->
    Acc.

filter_forms([Form0 | Forms0], State0) ->
    case filter_form(erl_syntax:type(Form0), Form0, State0) of
        {undefined, State1} ->
            {Forms, State} = filter_forms(Forms0, State1),
            {Forms, State};
        {Form, State1} ->
            {Forms, State} = filter_forms(Forms0, State1),
            {[erl_syntax:revert(Form) | Forms], State}
    end;
filter_forms([], State) ->
    {[], State}.

filter_form(attribute, Form, #state{collect = Collect} = State) ->
    AttrName = erl_syntax:attribute_name(Form),
    case erl_syntax:atom_value(AttrName) of
        module ->
            #collect{module = Module} = Collect,
            AttrArgs = [erl_syntax:atom(Module)],
            {erl_syntax:attribute(AttrName, AttrArgs), State};
        export ->
            {Form, State};
        _ ->
            {undefined, State}
    end;
filter_form(function, Form, #state{collect = Collect} = State) ->
    Name = erl_syntax:function_name(Form),
    #collect{props = Props, records = Records} = Collect,
    case erl_syntax:atom_value(Name) of
        get ->
            Form0 = function_get(Form, Props, Records),
            {Form0, State};
        all ->
            Form0 = function_all(Props, Records),
            {Form0, State};
        keys ->
            Form0 = function_keys(Props, Records),
            {Form0, State};
        pall ->
            Form0 = function_pall(Props),
            {Form0, State};
        pkeys ->
            Form0 = function_pkeys(Props),
            {Form0, State};
        rall ->
            Form0 = function_rall(Records),
            {Form0, State};
        rkeys ->
            Form0 = function_rkeys(Records),
            {Form0, State};
        _ ->
            {undefined, State}
    end;
filter_form(_, Form, State) ->
    {Form, State}.

function_get(Form, Props, Records) ->
    PClauses =
        [begin
            Pattern = [erl_syntax:abstract(Key)],
            Body = [erl_syntax:abstract(Value)],
            erl_syntax:clause(Pattern, none, Body)
        end || {Key, Value} <- lists:keysort(1, Props)],
    TClauses =
        [begin
            Pattern = [erl_syntax:abstract(element(2, Tuple))],
            Body = [erl_syntax:abstract(Tuple)],
            erl_syntax:clause(Pattern, none, Body)
        end || Tuple <- lists:keysort(2, Records)],
    Defaults = erl_syntax:function_clauses(Form),
    Clauses = PClauses ++ TClauses ++ Defaults,
    erl_syntax:function(erl_syntax:atom(get), Clauses).

function_all(Props, Records) ->
    Tuples = lists:keysort(2, Records) ++ lists:keysort(1, Props),
    Body = [erl_syntax:abstract(Tuples)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(all), [Clause]).

function_keys(Props, Records) ->
    Keys = lists:sort([element(2, Record) || Record <- Records]),
    Keys0 = lists:sort([Key || {Key, _Value} <- Props]) ++ Keys,
    Body = [erl_syntax:abstract(Keys0)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(keys), [Clause]).

function_pall(Props) ->
    Tuples = lists:keysort(1, Props),
    Body = [erl_syntax:abstract(Tuples)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(pall), [Clause]).

function_pkeys(Props) ->
    Keys = lists:sort([Key || {Key, _Value} <- Props]),
    Body = [erl_syntax:abstract(Keys)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(pkeys), [Clause]).

function_rall(Records) ->
    Tuples = lists:keysort(2, Records),
    Body = [erl_syntax:abstract(Tuples)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(rall), [Clause]).

function_rkeys(Records) ->
    Keys = lists:sort([element(2, Record) || Record <- Records]),
    Body = [erl_syntax:abstract(Keys)],
    Clause = erl_syntax:clause([], none, Body),
    erl_syntax:function(erl_syntax:atom(rkeys), [Clause]).

atomize([String]) when is_list(String) ->
    atomize(String);
atomize([String | [_Rest]]) when is_list(String) ->
    atomize(String);
atomize(String) ->
    list_to_atom(head_lower(String)).

head_lower([H | T]) ->
    [string:to_lower(H) | T].
