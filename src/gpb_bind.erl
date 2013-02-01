%% Copyright (c) 2012-2013 Martin Donath <md@struct.cc>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to
%% deal in the Software without restriction, including without limitation the
%% rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
%% sell copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%% IN THE SOFTWARE.

-module(gpb_bind).
-author('Martin Donath <md@struct.cc>').

% Include necessary libraries.
-include_lib("kernel/include/file.hrl").
-include_lib("gpb/include/gpb.hrl").

% Public functions.
-export([file/2]).

%% ----------------------------------------------------------------------------
%% Macros
%% ----------------------------------------------------------------------------

% Current version of this module.
-define(VERSION, "0.1.5").

% Subdirectory for modules that handle conversion of records from and to
% Protobuf binaries, as well as pre- and suffixes of the generated modules.
-define(PB_SUBDIR, "pb").
-define(PB_PREFIX, "").
-define(PB_SUFFIX, "_pb").

% Subdirectory for modules that contain bindings for the records generated by
% gpb, as well as pre- and suffixes of the generated modules.
-define(PB_BIND_SUBDIR, "pb_bind").
-define(PB_BIND_PREFIX, "").
-define(PB_BIND_SUFFIX, "").

%% ----------------------------------------------------------------------------
%% Public functions
%% ----------------------------------------------------------------------------

% Extract the message definitions from the given Protobuf file and compile them
% to record definitions. Then, analyze those message definitions to find out
% which messages reference each other in order to find the roots, which are
% simply the top-level messages in the Protobuf file.
file(File, Opts) ->
  case gpb_compile:file(File, [to_msg_defs | Opts]) of
    { ok, Defs } ->
      Filename = filename:basename(File, filename:extension(File)),
      Output   = proplists:get_value(o, Opts, filename:dirname(File)),
      case directory(Output, ?PB_SUBDIR) of
        { error, Reason } ->
          { error, Reason };
        Path ->
          Module = filename(?PB_PREFIX ++ Filename ++ ?PB_SUFFIX),
          gpb_compile:msg_defs(list_to_atom(Module), Defs,
            [{ f, File }, { o, Path } | proplists:delete(o, Opts)]),
          each(roots(Defs), Defs, [{ m, Module } | Opts])
      end;
    { error, Reason } ->
      { error, Reason }
  end.

%% ----------------------------------------------------------------------------
%% Top-level generators
%% ----------------------------------------------------------------------------

% Iterate through the given list of root message type definitions, and generate
% bindings for each of them. If successful, return them.
each([], Defs, _Opts) ->
  { ok, Defs };
each([{ { msg, Type }, Fields } | Roots], Defs, Opts) ->
  case generate(Type, Defs, Fields, Opts) of
    { error, Reason } ->
      { error, Reason };
    _ ->
      each(Roots, Defs, Opts)
  end.

% Generate the source code for the provided base and all of its nested message
% types, and save the contents to a file in the bindings subdirectory.
generate(Base, Defs, Fields, Opts) ->
  Filename = ?PB_BIND_PREFIX ++ filename(Base) ++ ?PB_BIND_SUFFIX,
  Output   = proplists:get_value(o, Opts,
    filename:dirname(proplists:get_value(f, Opts))),
  case directory(Output, ?PB_BIND_SUBDIR) of
    { error, Reason } ->
      { error, Reason };
    Path ->
      [ file:write_file(f("~s~s.erl", [Path, Filename]), [
        f("~s~n", [head(Base, Defs, Fields, Opts)]),
        f("~s",   [body(Base, Defs, Fields, Opts, [])]) ])
      || proplists:is_defined({ msg, Base }, Defs) ]
  end.

% Generate the function bodies of the source file for the provided set of
% message types and do this recursively for nested definitions and circles.
body(_Base, _Defs, [], _Opts, _Parents) ->
  [];
body(Base, Defs, [Field = #field{} | Fields], Opts, Parents) ->  
  case { Field#field.type, Field#field.occurrence } of
    { { msg, Type }, repeated } ->
      Children = proplists:get_value({ msg, Type }, Defs),
      [ generate(Type, Defs, Children, Opts) || not circular(Type, Defs) ],
      [ f("~s~2n", [function_get(Base, [Field#field{ type = Type } | Parents])]),
        f("~s~2n", [function_set(Base, [Field#field{ type = Type } | Parents])]),
        f("~s~2n", [function_add(Base, [Field#field{ type = Type } | Parents])]) |
        body(Base, Defs, Fields, Opts, Parents) ];
    { { msg, Type }, _ } ->
      Children = proplists:get_value({ msg, Type }, Defs),
      case circular(Type, Defs) or not is_tree([Base, Type]) of
        false ->
          body(Base, Defs, Children, Opts, [Field | Parents]);
        true  ->
          [ f("~s~2n", [function_get(Base, [Field#field{ type = Type } | Parents])]),
            f("~s~2n", [function_set(Base, [Field#field{ type = Type } | Parents])]) ]
      end ++ body(Base, Defs, Fields, Opts, Parents);
    { _, repeated } ->
      [ f("~s~2n", [function_get(Base, [Field | Parents])]),
        f("~s~2n", [function_set(Base, [Field | Parents])]),
        f("~s~2n", [function_add(Base, [Field | Parents])]) |
        body(Base, Defs, Fields, Opts, Parents) ];
    _ ->
      [ f("~s~2n", [function_get(Base, [Field | Parents])]),
        f("~s~2n", [function_set(Base, [Field | Parents])]) |
        body(Base, Defs, Fields, Opts, Parents) ]
  end.

% Generate the head section of the source file for the provided base/definition
% combination, including exports and functions for encoding and decoding.
head(Base, Defs, Fields, Opts) ->
  Module = proplists:get_value(m, Opts),
  [ f("%% Automatically generated, do not edit~n"),
    f("%% Generated by ~s version ~s on ~p~n", [
      ?MODULE, ?VERSION, calendar:local_time()]),
    f("-module(~s).~2n", [?PB_BIND_PREFIX ++
      filename(Base) ++ ?PB_BIND_SUFFIX]),

    % Generic and specific exports.
    f("-export([new/0]).~n"),
    f("-export([encode/1, encode/2]).~n"),
    f("-export([decode/1]). ~2n"),
    f("~s~n", [exports(Base, Defs, Fields)]),

    % Include record definitions.
    f("-include(\"../~s/~s.hrl\").~2n", [?PB_SUBDIR, Module]),

    % Record creation.
    f("% Create new ~s.~n", [variable(Base)]),
    f("new()->~n"),
    f("  #~p{}.~2n", [Base]),

    % Record encoding.
    f("% Record -> Binary.~n"),
    f("encode(~s)->~n", [variable(Base)]),
    f("  encode(~s, [verify]).~n", [variable(Base)]),
    f("encode(~s, Opts)->~n", [variable(Base)]),
    f("  ~s:encode_msg(~s, Opts).~2n", [Module, variable(Base)]),

    % Record decoding.
    f("% Binary -> Record.~n"),
    f("decode(Binary)->~n"),
    f("  ~s:decode_msg(Binary, ~p).~n", [Module, Base]) ].

% Generate export statements for the provided list of field definitions. For
% each field, there are get-/set-(and maybe add-)functions to be exported.
exports(Base, Defs, Fields) ->
  exports(Base, Defs, Fields, []).

exports(_Base, _Defs, [], _Parents) ->
  [];
exports(Base, Defs, [Field | Fields], Parents) ->
  case { Field#field.type, Field#field.occurrence } of
    { _, repeated } ->
      [ f("-export([~s_get/1]).~n", [function_name([Field | Parents])]),
        f("-export([~s_set/2]).~n", [function_name([Field | Parents])]),
        f("-export([~s_add/2]).~n", [function_name([Field | Parents])]) |
        exports(Base, Defs, Fields, Parents) ];
    { { msg, Type }, _ } ->
      Children = proplists:get_value({ msg, Type }, Defs),
      case circular(Type, Defs) or not is_tree([Base, Type]) of
        false ->
          exports(Base, Defs, Children, [Field | Parents]);
        true  ->
          [ f("-export([~s_get/1]).~n", [function_name([Field | Parents])]),
            f("-export([~s_set/2]).~n", [function_name([Field | Parents])]) ]
      end ++ exports(Base, Defs, Fields, Parents);
    _ ->
      [ f("-export([~s_get/1]).~n", [function_name([Field | Parents])]),
        f("-export([~s_set/2]).~n", [function_name([Field | Parents])]) |
        exports(Base, Defs, Fields, Parents) ]
  end.

%% ----------------------------------------------------------------------------
%% Get generators
%% ----------------------------------------------------------------------------

% Generate the head of a function to retrieve a certain field. Furthermore,
% quote the respective section in the proto file for reference.
function_get_head(Base, Fields) ->
  [ f("~s~n", [function_comment(Base, Fields)]),
    f("~s_get(~s) ->", [function_name(Fields), variable(Base)]) ].

% Generate the body of a function to retrieve a certain field. If any of the
% parent records is missing, undefined is returned.
function_get_body(Base, Fields, 0, _Value) ->
  [ f("~s", [record_get(Base, Fields)]) ];
function_get_body(Base, Fields, Layer, Value) ->
  [ f("case ~s of~n", [record_get(Base, drop(Fields, Layer))]),
    f("  ~p ->~n", [undefined(Fields, Layer)]),
    f("    ~p;~n", [undefined(Fields, Layer)]),
    f("  _ ->~n"),
    f("    ~s~n", [Value]),
    f("end") ].

% Generate a get function for the provided base and field list, including a
% header and nested/inlined function bodies for each field layer.
function_get(Base, Fields) ->
  function_get(Base, Fields, record_get(Base, Fields)).

function_get(Base, Fields, Value) ->
  function_get(Base, Fields, 0, Value).

function_get(Base, Fields, Layer, Value) ->
  case length(Fields) of
    Layer ->
      lists:concat([
        f("~s~n", [lists:concat(function_get_head(Base, Fields))]),
        f("~s~s.", [indent(1), Value])]);
    _ ->
      function_get(Base, Fields, Layer + 1,
        inline(function_get_body(Base, Fields, Layer, Value), Fields, Layer))
  end.

%% ----------------------------------------------------------------------------
%% Set generators
%% ----------------------------------------------------------------------------

% Generate the head of a function to persist a value to a certain field. Also,
% quote the respective section in the proto file for reference.
function_set_head(Base, Fields) ->
  [ f("~s~n", [function_comment(Base, Fields)]),
    f("~s_set(~s, Value) when Value == ~p; ~s ->",
    [ function_name(Fields), variable(Base), undefined(Fields, 0),
      function_guards(hd(Fields)) ]) ].

% Generate the body of a function to persist a value to a certain field. Parent
% records are initialized transparently.
function_set_body(Base, Fields, 0, _Value) ->
  [ f("~s", [record_set(Base, Fields, 1)]) ];
function_set_body(Base, Fields, Layer, Value) ->
  [ f("case ~s of~n", [record_get(Base, drop(Fields, Layer))]),
    f("  ~p ->~n", [undefined(Fields, Layer)]),
    f("    ~s;~n", [record_set(Base, Fields, Layer + 1)]),
    f("  ~s ->~n", [[$A + length(Fields) - Layer - 1]]),
    f("    ~s~n", [Value]),
    f("end") ].

% Generate a function footer, returning an argument error, in case the value
% does not pass through the respective guards.
function_set_foot(Base, Fields) ->
  [ f("~s_set(_~s, _Value) ->~n", [function_name(Fields), variable(Base)]),
    f("  { error, badarg }") ].

% Generate a set function for the provided base and field list, including a
% header and nested/inlined function bodies for each field layer.
function_set(Base, Fields) ->
  function_set(Base, Fields, record_set(Base, Fields, length(Fields) - 1)).

function_set(Base, Fields, Value) ->
  function_set(Base, Fields, 0, Value).

function_set(Base, Fields, Layer, Value) ->
  case length(Fields) of
    Layer ->
      lists:concat([
        f("~s~n", [lists:concat(function_set_head(Base, Fields))]),
        f("~s~s;~n", [indent(1), Value]),
        f("~s.", [lists:concat(function_set_foot(Base, Fields))])
      ]);
    _ ->
      function_set(Base, Fields, Layer + 1,
        inline(function_set_body(Base, Fields, Layer, Value), Fields, Layer))
  end.

%% ----------------------------------------------------------------------------
%% Add generators
%% ----------------------------------------------------------------------------

% Generate the head of a function to prepend a value to a certain field. Also,
% quote the respective section in the proto file for reference.
function_add_head(Base, Fields = [Field | _]) ->
  [ f("~s~n", [function_comment(Base, Fields)]),
    f("~s_add(~s, Value) when ~s ->",
    [ function_name(Fields), variable(Base),
      function_guards(Field#field{ occurrence = undefined }) ]) ].

% Generate the body of a function to prepend a value to a certain field. Parent
% records are initialized transparently.
function_add_body(Base, Fields, 0, _Value) ->
  [ f("case ~s of~n", [record_get(Base, Fields)]),
    f("  ~p ->~n", [undefined(Fields, 1)]),
    f("    ~s;~n", [record_set(Base, Fields, 1, "[Value]")]),
    f("  V ->~n"),
    f("    ~s~n", [record_set(Base, Fields, 1, "[Value | V]")]),
    f("end") ];
function_add_body(Base, Fields, Layer, Value) ->
  [ f("case ~s of~n", [record_get(Base, drop(Fields, Layer))]),
    f("  ~p ->~n", [undefined(Fields, Layer)]),
    f("    ~s;~n", [record_set(Base, Fields, Layer + 1, "[Value]")]),
    f("  ~s ->~n", [[$A + length(Fields) - Layer - 1]]),
    f("    ~s~n", [Value]),
    f("end") ].

% Generate a function footer, returning an argument error, in case the value
% does not pass through the respective guards.
function_add_foot(Base, Fields) ->
  [ f("~s_add(_~s, _Value) ->~n", [function_name(Fields), variable(Base)]),
    f("  { error, badarg }") ].

% Generate an add function for the provided base and field list, including a
% header and nested/inlined function bodies for each field layer.
function_add(Base, Fields) ->
  function_add(Base, Fields, record_set(Base, Fields, length(Fields) - 1)).

function_add(Base, Fields, Value) ->
  function_add(Base, Fields, 0, Value).

function_add(Base, Fields, Layer, Value) ->
  case length(Fields) of
    Layer ->
      lists:concat([
        f("~s~n", [lists:concat(function_add_head(Base, Fields))]),
        f("~s~s;~n", [indent(1), Value]),
        f("~s.", [lists:concat(function_add_foot(Base, Fields))])]);
    _ ->
      function_add(Base, Fields, Layer + 1,
        inline(function_add_body(Base, Fields, Layer, Value), Fields, Layer))
  end.

%% ----------------------------------------------------------------------------
%% Signature generators
%% ----------------------------------------------------------------------------

% Generate a comment section for the provided base and field list which
% references the respective definition in the proto file.
function_comment(Base, [First = #field{ type = { _, Type }} | Fields]) ->
  function_comment(Base, [First#field{ type = Type } | Fields]);
function_comment(_Base, [First, #field{ type = { msg, Type } } | _]) ->
  f("% ~s { ~p ~s ~p = ~p; }", [atom_to_list(Type), First#field.occurrence,
    atom_to_list(First#field.type), First#field.name, First#field.fnum]);
function_comment(Base, [First | _]) ->
  f("% ~s { ~p ~s ~p = ~p; }", [atom_to_list(Base), First#field.occurrence,
    atom_to_list(First#field.type), First#field.name, First#field.fnum]).

% Generate a function name for the provided field list which is basically
% just the identifiers concatenated with an underscore.
function_name(Fields) ->
  string:join([ atom_to_list(Field#field.name) ||
    Field <- lists:reverse(Fields)], "_").

% Generate guard(s) for the provided field, whereas the Protobuf types have to
% be mapped to their Erlang representations.
function_guards(#field{ occurrence = repeated }) ->
  "is_list(Value)";
function_guards(#field{ type = int32 }) ->
  "is_integer(Value)";
function_guards(#field{ type = int64 }) ->
  "is_integer(Value)";
function_guards(#field{ type = uint32 }) ->
  "is_integer(Value), Value >= 0";
function_guards(#field{ type = uint64 }) ->
  "is_integer(Value), Value >= 0";
function_guards(#field{ type = sint32 }) ->
  "is_integer(Value)";
function_guards(#field{ type = sint64 }) ->
  "is_integer(Value)";
function_guards(#field{ type = fixed32 }) ->
  "is_integer(Value)";
function_guards(#field{ type = fixed64 }) ->
  "is_integer(Value)";
function_guards(#field{ type = sfixed32 }) ->
  "is_integer(Value)";
function_guards(#field{ type = sfixed64 }) ->
  "is_integer(Value)";
function_guards(#field{ type = bool }) ->
  "is_boolean(Value)";
function_guards(#field{ type = float }) ->
  "is_float(Value)";
function_guards(#field{ type = double }) ->
  "is_float(Value)";
function_guards(#field{ type = string }) ->
  "is_list(Value)";
function_guards(#field{ type = bytes }) ->
  "is_binary(Value)";
function_guards(#field{ type = { enum, _Type } }) ->
  "is_atom(Value)";
function_guards(#field{ type = Type }) ->
  f("is_record(Value, ~p)", [Type]);
function_guards(_Field) ->
  "is_list(Value)".

%% ----------------------------------------------------------------------------
%% Record qualifiers
%% ----------------------------------------------------------------------------

% Qualify a nested record chain by resolving each field, in order to get the
% current type, and append the already qualified string.
record_get(Base, Fields) ->
  record_get(Base, Fields, "").

record_get(Base, [], Value) ->
  f("~s#~p~s", [variable(Base), Base, Value]);
record_get(Base, [Field | Fields], Value) ->
  record_get(Base, Fields, case { Field#field.type, Value } of
    { { msg, _ }, "" } ->
      f(".~p", [Field#field.name]);
    { { msg, Type }, _ } ->
      f(".~p#~p~s", [Field#field.name, Type, Value]);
    _ ->
      f(".~p~s", [Field#field.name, Value])
  end).

% Qualify a nested record chain by resolving each field, in order to set the
% current type, and append the already qualified string.
record_set(Base, Fields, Layer) ->
  record_set(Base, Fields, Layer, "Value").

record_set(Base, [], _Layer, Value) ->
  f("~s#~p~s", [variable(Base), Base, Value]);
record_set(Base, [Field = #field{ name = Name } | Fields], Layer, Value) ->
  record_set(Base, Fields, Layer - 1, case Field#field.type of
    { msg, Type } when Layer =< 0 ->
      f("{ ~p = ~s#~p~s }", [Name, [$A + length(Fields)], Type, Value]);
    { msg, Type } when Layer  > 0 ->
      f("{ ~p = #~p~s }", [Name, Type, Value]);
    _ ->
      f("{ ~p = ~s }", [Name, Value])
  end).

% Determine the type-specific value in case that no value is set for the
% provided nested record chain.
undefined(Fields, Layer) when length(Fields) == Layer ->
  undefined;
undefined(Fields, Layer) ->
  case (hd(drop(Fields, Layer)))#field.occurrence of
    repeated -> [];
    _        -> undefined
  end.

%% ----------------------------------------------------------------------------
%% Helper functions
%% ----------------------------------------------------------------------------

% Iterate through the provided list of definitions and obtain only those which
% are circular or not referenced by others, as these are our root definitions.
roots(Defs) ->
  Roots =  roots(Defs, Defs, []),
  Roots ++ [ { Type, Fields } || { Type, Fields } <- circular(Defs),
    none == proplists:lookup(Type, Roots) ].

roots(Defs, [], []) ->
  Defs;
roots(Defs, [{ Type, [] } | Messages], []) ->
  roots(proplists:delete(Type, Defs), Messages, []);
roots(Defs, [{ Type, Fields } | Messages], []) ->
  case Type of
    { msg, Root } ->
      roots(Defs, Messages, [ Field || Field <- Fields,
        { msg, Node } <- [Field#field.type], is_tree([Root, Node]) ]);
    _ ->
      roots(proplists:delete(Type, Defs), Messages, [])
  end;
roots(Defs, Messages, [Field | Fields]) ->
  roots(proplists:delete(Field#field.type, Defs), Messages, Fields).

% Check, if a field is the join-point of a circular reference, as we must
% generate a separate module for such a reference.
%
% This function either takes a list of definitions and filters out all those
% that are not referenced in a circular way, or takes a specific message type
% and returns, whether this specific message type is at the join-point (and not
% in the middle) of a circular reference.
circular(Defs) ->
  [ { { Type, Base }, Fields } ||
    { { Type, Base }, Fields } <- Defs, Type == msg, circular(Base, Defs) ].

circular(Base, Defs) ->
  Fields = proplists:get_value({ msg, Base }, Defs),
  circular(Defs, Fields, [Base]).

circular(_Defs, [], _Path) ->
  false;
circular(Defs, [Field | Fields], Path) ->
  case Field#field.type of
    { msg, Type } ->
      case lists:member(Type, Path) of
        false ->
          Children = proplists:get_value({ msg, Type }, Defs),
          case circular(Defs, Children, [Type | Path]) of
            false -> circular(Defs, Fields, Path);
            true  -> true
          end;
        true ->
          Type == lists:last(Path) andalso
            (length(Path) == 1 orelse not is_tree(Path))
      end;
    _ ->
      circular(Defs, Fields, Path)
  end.

% Check, if the provided path is a tree within the schema, and not a circle,
% so each node is the successor of the preceeding node in the provided path.
is_tree([_ | []]) ->
  true;
is_tree([Branch | Path]) ->
  lists:prefix(
    string:tokens(atom_to_list(Branch), "."),
    string:tokens(atom_to_list(hd(Path)), ".")
  ) andalso Branch /= hd(Path) andalso is_tree(Path).

% Helper function to drop the first N elements of a list. The trivial case of
% dropping 0 elements is implemented for convenience.
drop(List, 0) ->
  List;
drop([_ | List], N) ->
  drop(List, N - 1).

% Emit the given amount of whitespaces for indentation of strings, whereas the
% provided number is multiplied by 2 for nice code formatting.
indent(N) ->
  lists:flatten(lists:duplicate(N * 2, " ")).

% Given a list of fields, indent all of them except the first by the correct
% amount applicable for the given layer.
inline([Head | Tail], Fields, Layer) ->
  lists:concat([Head | [ f("~s~s", [
    indent((length(Fields) - Layer) * 2 - 1), Line]) || Line <- Tail ]]).

% Split the atom (Noisiaaa!) at dots and return the last part as a string.
% This is necessary for resolving the variable name of the given base.
variable(Base) ->
  lists:last(string:tokens(atom_to_list(Base), ".")).

% Convert an atom or list to a filename representation, replacing dots by
% underscores and downcasing the whole string.
filename(Base) when is_atom(Base) ->
  filename(atom_to_list(Base));
filename(Base) ->
  string:to_lower(string:join(string:tokens(Base, "."), "_")).

% Check if the given base directory exists, create a sub-directory for the
% provided identifier and return its name.
directory(Base, Sub) ->
  case filelib:is_dir(Base) of
    true  ->
      Path = Base ++ "/" ++ Sub ++ "/",
      filelib:ensure_dir(Path), Path;
    false ->
      { error, enodir }
  end.

% Wrapper for io_lib:format/2, which formats a string and (optionally) inserts
% values that can be provide as arguments.
f(String) ->
  f(String, []).

f(String, Args) ->
  io_lib:format(String, Args).