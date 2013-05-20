# Google Protocol Buffer Bindings

This module generates bindings for Google Protocol Buffer definitions, which
make it very easy to persist and retrieve values from and to Protobuf messages
in Erlang. It depends on [gpb][], a Google Protocol Buffers implementation
developed by Tomas Abrahamsson, and is a drop-in replacement as it wraps and
integrates the gpb compiler.

The [gpb][] module is an elegant and efficient Protobuf parser which translates
Protobuf's messages to Erlang's records. However, when working with nested
records originating from nested Protobuf messages, things start to get really
ugly, e.g. for changing the value of a field within a nested record, the full
path has to be qualified. Every time. Furthermore, deeper nested records may or
may not be initialized, so this has to be checked, too.

The bindings this module generates will do this for you.

## Installation

Using [Rebar][] for dependency management, the following lines must be added to
the `rebar.config` residing in the application's root:

``` erlang
{ deps, [
  { gpb_bind, ".*",
    { git, "git://github.com/squidfunk/gpb-bindings.git", "master" }
  }
}.
```

Then fetch dependencies with `rebar get-deps` and compile them with
`rebar compile`. That's it.

## Usage

This module is a wrapper for the [gpb][] compiler, so you can use it exactly
like the compiler. Custom options are not available at the moment, but may
follow in the future. If we want to compile a file called `jobs.proto`, which
resides in the directory `./include`, and save the compiled source files to
`./src/cache`, we call it in the following way:

``` erlang
{ ok, Defs } = gpb_bind:file("jobs.proto", [
  { i, "./include" }, { o, "./src/cache" },
strings_as_binaries]),
```

Further options like `strings_as_binaries` or `include_as_lib`, which is
necessary for dependency management via [Rebar][], can be included and get
handed to the original Protobuf compiler. On success, the message definitions
are returned.

## Features

Let's assume we have a simple set of Protobuf message definitions, specifying
a person with an address and a company which offers jobs. Those messages
aren't even nested, but the records that get generated from them are:

``` javascript
message Address {
  required string street = 1;
  required string city = 2;
}

message Person {
  required string name = 1;
  required Address address = 2;
}

message Job {
  required string title = 1;
  required string description = 2;
}

message Company {
  required string name = 1;
  repeated Job jobs = 2;
}
```

When [gpb][] translates those message definitions into records, we can operate
on them using Erlang's record syntax. However, even for this simple example,
the usage is not very convenient as the following example demonstrates:

``` erlang
% Initializing a person with an empty address.
Person = #'Person'{ address = #'Address'{} },

% Setting the street within a person's address.
Person#'Person'.address#'Address'{ street = ... },

% Accessing the street within a person's address.
Person#'Person'.address#'Address'.street.
```

Hmm, very verbose and somehow not nice, but this is an inherent problem of
Erlang's record compile-time trickery. We can do better. For this reason,
this module generates simple bindings for a more elegant use of Google
Protocol Buffers with Erlang.

### Roots and Inlining

Of those four message definitions, only Person and Company are roots, as they
are not referenced in other messages. Job and Address are referenced in Company
and Person, so they are not considered of being a root. For each of those
root messages, bindings are generated, e.g. for Person, those bindings are:

``` erlang
name_get/1,                 % person:name_get(Person)
name_set/2,                 % person:name_set(Person, Value)
address_street_get/1        % person:address_street_get(Person)
address_street_set/2        % person:address_street_set(Person, Value)
address_city_get/1          % person:address_city_get(Person)
address_city_set/2          % person:address_city_set(Person, Value)
```

Now it is very easy to retrieve and persist values. Even more convenient,
nested records are always initialized in a lazy way:

``` erlang
% Initializing a person with an empty address.
Person = person:new(),

% Setting the street within a person's address.
person:address_street_set(Person, ...),

% Accessing the street within a person's address.
person:address_street_get(Person).
```

Messages which are referenced inside other messages and marked as `optional`
or `required` get inlined, thus able to represent deeply nested hierarchies.
This is where this module really shines, as Erlang's syntax on nested
records is really, really ugly!

### Repeated Messages

If a message can contain many instances of another message, thus its
occurrence is declared `repeated`, a separate module is declared. As in our
example, a company can offer many jobs, so a set of bindings is generated which
is split across two modules:

``` erlang
% Job
title_get/1,                % job:title_get(Job)
title_set/2,                % job:title_set(Job, Value)
description_get/1,          % job:description_get(Job)
description_set/2,          % job:description_set(Job, Value)

% Company
name_get/1,                 % company:name_get(Company)
name_set/2,                 % company:name_set(Company, Value)
jobs_get/1,                 % company:jobs_get(Company)
jobs_set/2,                 % company:jobs_set(Company, Job)
jobs_add/2,                 % company:jobs_add(Company, Job)
```

Thus, retrieving a `repeated` field, a list of job records is returned. Those
job records can then be manipulated individually with a separate module, and
persisted within the referencing message with a simple set operation. A third
method to add (prepend) a new nested record is also provided.

These separate declarations are also generated for nested messages which are
marked as `repeated`, e.g.:

``` javascript
message Company {
  message Job {
    required string title = 1;
    required string description = 2;
  }
  required string name = 1;
  repeated Job jobs = 2
}
```

This will expand to the same definitions as describes above, except that the
names of the modules are also nested, resulting in `company.erl` and
`company_job.erl`, in order to avoid clashing namespaces across definitions
with the same names.

### Circular References

As for repeated messages, a separate module is generated for each circular
reference. This is necessary, because inlining a circular reference would
result in an infinite loop.

### Encoding and Decoding

Beside those bindings, three functions for creating, encoding and decoding
records are generated. For our person example, those are:

``` erlang
new/0,                      % person:new()
encode/1, encode/2          % person:encode(Person[, Opts])
decode/1,                   % person:decode(Person)
```

The modules generated by [gpb][] which handle the conversion of records from
and to binaries, and those generated by this module are stored in separate
subdirectories. The former are named after the Protobuf file, the names of
the latter are expanded from the message definitions. The directory where
to store the generated files is taken from the options passed to [gpb][].

## License

Copyright (c) 2012-2013 Martin Donath

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

[gpb]: https://github.com/tomas-abrahamsson/gpb
[Rebar]: https://github.com/basho/rebar