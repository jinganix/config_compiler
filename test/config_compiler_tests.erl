
%% Copyright (c) JinGan <jg_513@163.com>

-module(config_compiler_tests).

-compile(export_all).

compile() ->
    Options = [
        {imports_dir, "config"},
        {code_dir, undefined},
        {ebin_dir, "ebin"},
        {load, true}
    ],
    config_compiler:scan_dir(Options).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).

all_test_() ->
    compile(),
    ?_assertEqual(data_sample:get(a), 1),
    ?_assertEqual(data_sample:get(1), {data_sample,1,a}),
    ?_assertEqual(data_sample:get(2), {anything,2,a,b,c}),
    ?_assertEqual(data_sample:get(anything), undefined),
    ?_assertEqual(data_sample:all(), [{data_sample, 1, a}, {anything, 2, a, b, c}, {a, 1}]),
    ?_assertEqual(data_sample:keys(), [a, 1, 2]),
    ?_assertEqual(data_sample:pall(), [{a, 1}]),
    ?_assertEqual(data_sample:pkeys(), [a]),
    ?_assertEqual(data_sample:rall(), [{data_sample, 1, a}, {anything, 2, a, b, c}]),
    ?_assertEqual(data_sample:rkeys(), [1, 2]).

-endif.
