%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_plugin).
-include("rabbit.hrl").

-export([start/0, stop/0]).

-define(COMPACT_OPT, "-c").

-record(plugin, {name,          %% atom()
                 version,       %% string()
                 description,   %% string()
                 dependencies,  %% [{atom(), string()}]
                 location}).    %% string()

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start/0 :: () -> no_return()).
-spec(stop/0 :: () -> 'ok').

-endif.

%%----------------------------------------------------------------------------

start() ->
    {ok, [[PluginsDir|_]|_]} = init:get_argument(plugins_dir),
    {ok, [[PluginsDistDir|_]|_]} = init:get_argument(plugins_dist_dir),
    {[Command0 | Args], Opts} =
        case rabbit_misc:get_options([{flag, ?COMPACT_OPT}],
                                     init:get_plain_arguments()) of
            {[], _Opts}    -> usage();
            CmdArgsAndOpts -> CmdArgsAndOpts
        end,
    Command = list_to_atom(Command0),

    case catch action(Command, Args, Opts, PluginsDir, PluginsDistDir) of
        ok ->
            rabbit_misc:quit(0);
        {'EXIT', {function_clause, [{?MODULE, action, _} | _]}} ->
            print_error("invalid command '~s'",
                        [string:join([atom_to_list(Command) | Args], " ")]),
            usage();
        {error, Reason} ->
            print_error("~p", [Reason]),
            rabbit_misc:quit(2);
        Other ->
            print_error("~p", [Other]),
            rabbit_misc:quit(2)
    end.

stop() ->
    ok.

print_error(Format, Args) ->
    rabbit_misc:format_stderr("Error: " ++ Format ++ "~n", Args).

usage() ->
    io:format("~s", [rabbit_plugin_usage:usage()]),
    rabbit_misc:quit(1).

%%----------------------------------------------------------------------------

action(list, [], Opts, PluginsDir, PluginsDistDir) ->
    action(list, [".*"], Opts, PluginsDir, PluginsDistDir);
action(list, [Pattern], Opts, PluginsDir, PluginsDistDir) ->
    format_plugins(PluginsDir, PluginsDistDir, Pattern,
                   proplists:get_bool(?COMPACT_OPT, Opts));

action(enable, ToEnable0, _Opts, PluginsDir, PluginsDistDir) ->
    AllPlugins = find_plugins(PluginsDistDir),
    Enabled = read_enabled_plugins(PluginsDir),
    EnabledPlugins = lookup_plugins(Enabled, AllPlugins),
    ToEnable = [list_to_atom(Name) || Name <- ToEnable0],
    ToEnablePlugins = lookup_plugins(ToEnable, AllPlugins),
    Missing = ToEnable -- plugin_names(ToEnablePlugins),
    case Missing of
        [] -> ok;
        _  -> io:format("Warning: the following plugins could not be found: ~p~n",
                        [Missing])
    end,
    NewEnabledPlugins = merge_plugin_lists(EnabledPlugins, ToEnablePlugins),
    EnableOrder = calculate_required_plugins(plugin_names(NewEnabledPlugins),
                                             AllPlugins),
    EnableOrder1 = EnableOrder -- plugin_names(find_plugins(PluginsDir)),
    case EnableOrder1 of
        [] -> io:format("No plugins to enable.~n");
        _  -> io:format("Will enable: ~p~n", [EnableOrder1]),
              ok = lists:foldl(
                     fun (Plugin, ok) -> enable_one_plugin(Plugin, PluginsDir) end,
                     ok, lookup_plugins(EnableOrder1, AllPlugins)),
              update_enabled_plugins(PluginsDir, plugin_names(NewEnabledPlugins)),
              action(prune, [], {}, PluginsDir, PluginsDistDir)
    end;

action(prune, [], _Opts, PluginsDir, PluginsDistDir) ->
    ExplicitlyEnabledPlugins = read_enabled_plugins(PluginsDir),
    AllPlugins = find_plugins(PluginsDistDir),
    Required = calculate_required_plugins(ExplicitlyEnabledPlugins, AllPlugins),
    AllEnabledPlugins = find_plugins(PluginsDir),
    ToDisablePlugins =
        AllEnabledPlugins -- lookup_plugins(Required, AllEnabledPlugins),
    case ToDisablePlugins of
        [] ->
            io:format("No unnecessary plugins found.~n");
        _ ->
            io:format("Disabling unnecessary plugins: ~p~n",
                      [plugin_names(ToDisablePlugins)]),
            ok = lists:foldl(fun (Plugin, ok) -> disable_one_plugin(Plugin) end,
                             ok, ToDisablePlugins)
    end;

action(disable, ToDisable0, _Opts, PluginsDir, PluginsDistDir) ->
    ToDisable = [list_to_atom(Name) || Name <- ToDisable0],
    EnabledPlugins = find_plugins(PluginsDir),
    ToDisablePlugins = lookup_plugins(ToDisable, EnabledPlugins),
    Missing = ToDisable -- plugin_names(ToDisablePlugins),
    case Missing of
        [] -> ok;
        _  -> io:format("Warning: the following plugins could not be found: ~p~n",
                        [Missing])
    end,
    ExplicitlyEnabled = read_enabled_plugins(PluginsDir),
    DisableOrder = calculate_requires_plugins(plugin_names(ToDisablePlugins),
                                              EnabledPlugins),
    ExplicitlyDisabled = sets:to_list(
                           sets:intersection(sets:from_list(DisableOrder),
                                             sets:from_list(ExplicitlyEnabled))),
    io:format("Will disable: ~p~n", [ExplicitlyDisabled]),
    update_enabled_plugins(PluginsDir, ExplicitlyEnabled -- DisableOrder),
    action(prune, [], {}, PluginsDir, PluginsDistDir).

%%----------------------------------------------------------------------------

%% Get the #plugin{}s from the .ezs in the given directory.
find_plugins(PluginsDistDir) ->
    EZs = filelib:wildcard("*.ez", PluginsDistDir),
    {Plugins, Problems} =
        lists:foldl(fun ({error, EZ, Reason}, {Plugins1, Problems1}) ->
                            {Plugins1, [{EZ, Reason} | Problems1]};
                        (Plugin = #plugin{}, {Plugins1, Problems1}) ->
                            {[Plugin|Plugins1], Problems1}
                    end, {[], []},
                    [get_plugin_info(filename:join([PluginsDistDir, EZ]))
                     || EZ <- EZs]),
    case Problems of
        [] -> ok;
        _  -> io:format("Warning: Problem reading some plugins: ~p~n", [Problems])
    end,
    Plugins.

%% Get the #plugin{} from an .ez.
get_plugin_info(EZ) ->
    case read_app_file(EZ) of
        {application, Name, Props} ->
            Version = proplists:get_value(vsn, Props, "0"),
            Description = proplists:get_value(description, Props, ""),
            Dependencies =
                filter_applications(proplists:get_value(applications, Props, [])),
            #plugin{name = Name, version = Version, description = Description,
                    dependencies = Dependencies, location = EZ};
        {error, Reason} ->
            {error, EZ, Reason}
    end.

%% Read the .app file from an ez.
read_app_file(EZ) ->
    case zip:list_dir(EZ) of
        {ok, [_|ZippedFiles]} ->
            case find_app_files(ZippedFiles) of
                [AppPath|_] ->
                    {ok, [{AppPath, AppFile}]} =
                        zip:extract(EZ, [{file_list, [AppPath]}, memory]),
                    parse_binary(AppFile);
                [] ->
                    {error, no_app_file}
            end;
        {error, Reason} ->
            {error, {invalid_ez, Reason}}
    end.

%% Return the path of the .app files in ebin/.
find_app_files(ZippedFiles) ->
    {ok, RE} = re:compile("^.*/ebin/.*.app$"),
    [Path || {zip_file, Path, _, _, _, _} <- ZippedFiles,
             re:run(Path, RE, [{capture, none}]) =:= match].

%% Parse a binary into a term.
parse_binary(Bin) ->
    try
        {ok, Ts, _} = erl_scan:string(binary:bin_to_list(Bin)),
        {ok, Term} = erl_parse:parse_term(Ts),
        Term
    catch
        Err -> {error, {invalid_app, Err}}
    end.

%% Pretty print a list of plugins.
format_plugins(PluginsDir, PluginsDistDir, Pattern, Compact) ->
    AvailablePlugins = find_plugins(PluginsDistDir),
    EnabledExplicitly = read_enabled_plugins(PluginsDir),
    EnabledPlugins = find_plugins(PluginsDir),
    EnabledImplicitly = plugin_names(EnabledPlugins) -- EnabledExplicitly,
    {ok, RE} = re:compile(Pattern),
    [ format_plugin(P, EnabledExplicitly, EnabledImplicitly, Compact)
     || P = #plugin{name = Name} <- usort_plugins(EnabledPlugins ++
                                                  AvailablePlugins),
        re:run(atom_to_list(Name), RE, [{capture, none}]) =:= match],
    ok.

format_plugin(#plugin{name = Name, version = Version, description = Description,
                      dependencies = Dependencies},
              EnabledExplicitly, EnabledImplicitly, Compact) ->
    Glyph = case {lists:member(Name, EnabledExplicitly),
                  lists:member(Name, EnabledImplicitly)} of
                {true, false} -> "[E]";
                {false, true} -> "[e]";
                _             -> "[A]"
            end,
    case Compact of
        true ->
            io:format("~s ~w-~s: ~s~n", [Glyph, Name, Version, Description]);
        false ->
            io:format("~s ~w~n", [Glyph, Name]),
            io:format("    Version:    \t~s~n", [Version]),
            case Dependencies of
                [] -> ok;
                _  -> io:format("    Dependencies:\t~p~n", [Dependencies])
            end,
            io:format("    Description:\t~s~n", [Description]),
            io:format("~n")
    end.

usort_plugins(Plugins) ->
    lists:usort(fun plugins_cmp/2, Plugins).

%% Merge two plugin lists.  In case of duplicates, only keep highest
%% version.
merge_plugin_lists(Ps1, Ps2) ->
    filter_duplicates(usort_plugins(Ps1 ++ Ps2)).

filter_duplicates([P1 = #plugin{name = N, version = V1},
                   P2 = #plugin{name = N, version = V2} | Ps]) ->
    if V1 < V2 -> filter_duplicates([P2 | Ps]);
       true    -> filter_duplicates([P1 | Ps])
    end;
filter_duplicates([P | Ps]) ->
    [P | filter_duplicates(Ps)];
filter_duplicates(Ps) ->
    Ps.

plugins_cmp(#plugin{name = N1, version = V1}, #plugin{name = N2, version = V2}) ->
    {N1, V1} =< {N2, V2}.

%% Filter applications that can be loaded *right now*.
filter_applications(Applications) ->
    [Application || Application <- Applications,
                    case application:load(Application) of
                        {error, {already_loaded, _}} -> false;
                        ok -> application:unload(Application),
                              false;
                        _  -> true
                    end].

%% Return the names of the given plugins.
plugin_names(Plugins) ->
    [Name || #plugin{name = Name} <- Plugins].

%% Find plugins by name in a list of plugins.
lookup_plugins(Names, AllPlugins) ->
    AllPlugins1 = filter_duplicates(usort_plugins(AllPlugins)),
    [P || P = #plugin{name = Name} <- AllPlugins1, lists:member(Name, Names)].

%% Read the enabled plugin names from disk.
read_enabled_plugins(PluginsDir) ->
    FileName = enabled_plugins_filename(PluginsDir),
    case rabbit_misc:read_term_file(FileName) of
        {ok, [Plugins]} -> Plugins;
        {error, enoent} -> [];
        {error, Reason} -> throw({error, {cannot_read_enabled_plugins_file,
                                          FileName, Reason}})
    end.

%% Update the enabled plugin names on disk.
update_enabled_plugins(PluginsDir, Plugins) ->
    FileName = enabled_plugins_filename(PluginsDir),
    case rabbit_misc:write_term_file(FileName, [Plugins]) of
        ok              -> ok;
        {error, Reason} -> throw({error, {cannot_write_enabled_plugins_file,
                                          FileName, Reason}})
    end.

enabled_plugins_filename(PluginsDir) ->
    filename:join([PluginsDir, "enabled_plugins"]).

%% Return a list of plugins that must be enabled when enabling the
%% ones in ToEnable.  I.e. calculates dependencies.
calculate_required_plugins(ToEnable, AllPlugins) ->
    AllPlugins1 = filter_duplicates(usort_plugins(AllPlugins)),
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun (App, _Deps) -> [{App, App}] end,
                fun (App,  Deps) -> [{App, Dep} || Dep <- Deps] end,
                [{Name, Deps}
                 || #plugin{name = Name, dependencies = Deps} <- AllPlugins1]),
    EnableOrder = digraph_utils:reachable(ToEnable, G),
    true = digraph:delete(G),
    EnableOrder.

%% Return a list of plugins that must be disabled when disabling the
%% ones in ToDisable.  I.e. calculates *reverse* dependencies.
calculate_requires_plugins(ToDisable, AllPlugins) ->
    AllPlugins1 = filter_duplicates(usort_plugins(AllPlugins)),
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun (App, _Deps) -> [{App, App}] end,
                fun (App,  Deps) -> [{Dep, App} || Dep <- Deps] end,
                [{Name, Deps}
                 || #plugin{name = Name, dependencies = Deps} <- AllPlugins1]),
    DisableOrder = digraph_utils:reachable(ToDisable, G),
    true = digraph:delete(G),
    DisableOrder.

%% Enable one plugin by copying it to the PluginsDir.
enable_one_plugin(#plugin{name = Name, version = Version, location = Path},
                  PluginsDir) ->
    io:format("Enabling ~w-~s~n", [Name, Version]),
    TargetPath = filename:join(PluginsDir, filename:basename(Path)),
    ok = rabbit_misc:ensure_parent_dirs_exist(TargetPath),
    case file:copy(Path, TargetPath) of
        {ok, _Bytes} -> ok;
        {error, Err} -> io:format("Error enabling ~p (~p)~n",
                                  [Name, {cannot_enable_plugin, Path, Err}]),
                        rabbit_misc:quit(2)
    end.

%% Disable the given plugin by deleting it.
disable_one_plugin(#plugin{name = Name, version = Version, location = Path}) ->
    io:format("Disabling ~w-~s~n", [Name, Version]),
    case file:delete(Path) of
        ok              -> ok;
        {error, enoent} -> ok;
        {error, Err}    -> io:format("Error disabling ~p (~p)~n",
                                     [Name, {cannot_delete_plugin, Path, Err}]),
                           rabbit_misc:quit(2)
    end.
