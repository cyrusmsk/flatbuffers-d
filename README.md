# FlatBuffers for D

A D runtime for [FlatBuffers](https://flatbuffers.dev/), modeled on the Go and
C# implementations.

This directory contains the runtime library, verifier, integration tests, and
the generated-code test fixtures. The D backend lives in `src/idl_gen_dlang.cpp`
and is invoked through `flatc --dlang`.

## Requirements

- DMD 2.112+ or LDC 1.42+
- DUB

The DUB package is named `flatbuffers-d`:

```bash
dub add flatbuffers-d
```

The import name remains `flatbuffers`.

## Package layout

- `source/flatbuffers/base.d` - scalar types, sizes, endian-safe reads/writes,
  and root/identifier helpers
- `source/flatbuffers/table.d` - `Table` and `Struct` readers
- `source/flatbuffers/vector.d` - reusable scalar/string/table/struct vector ranges
- `source/flatbuffers/builder.d` - `FlatBufferBuilder`
- `source/flatbuffers/verifier.d` - bounded verifier for untrusted buffers
- `source/flatbuffers/flexbuffers/` - builder, zero-copy reader, and verifier
  for the schema-less FlexBuffers format
- `source/flatbuffers/package.d` - public imports
- `tests/generated/` - flatc-generated binary bindings used by the
  integration test
- `tests/generated_serialize/` - flatc-generated asdf bindings
- `tests/integration.d` - golden buffer and round-trip tests
- `tests/serialize.d` - asdf JSON shape and enum input tests
- `tests/conformance.d` - optional scalars, includes/no-namespace, and required strings
- `tests/flexbuffers.d` - FlexBuffers builder/reader/verifier tests and
  cross-language golden coverage

## Generating bindings

Build `flatc` from the repository root and generate the D bindings:

```bash
cmake -S . -B build -G Ninja \
  -DFLATBUFFERS_BUILD_TESTS=OFF \
  -DFLATBUFFERS_BUILD_FLATLIB=OFF \
  -DFLATBUFFERS_BUILD_FLATC=ON
cmake --build build --target flatc

./build/flatc --dlang -I tests/include_test \
  -o d/tests/generated tests/monster_test.fbs

./build/flatc --dlang --dlang-serialize -I tests/include_test \
  -o d/tests/generated_serialize tests/monster_test.fbs
```

`--dlang` emits one D module per schema type under the schema namespace.
`--dlang-serialize` adds asdf serialization for table and struct views and
asdf input support for enums. It does not generate table JSON deserialization.

## Building and testing

From this directory:

```bash
dub test
dub test --build=release
dub run --config=integration
dub run --config=serialize
dub run --config=conformance
dub run --config=matrix
dub run --config=flexbuffers
dub build --build=release
```

The binary configurations do not depend on asdf. The `serialize` configuration
adds asdf 0.8.0.

The integration and serialization tests read
`tests/data/monsterdata_test.mon`; the FlexBuffers test reads
`tests/data/gold_flexbuffer_example.bin`.

The runtime is also available as the Bazel target `//d:flatbuffers`:

```bash
bazel build //d:flatbuffers
```

## FlexBuffers

`flatbuffers.flexbuffers` implements the schema-less FlexBuffers format and is
wire-compatible with the C++ and Rust implementations:

```d
import flatbuffers.flexbuffers;

auto builder = Builder(256);
auto map = builder.startMap();
map.put("answer", 42);
map.putString("name", "D");
map.end();
builder.finish();

if (!verifyBuffer(builder.finishedBytes()))
    throw new Exception("invalid FlexBuffer");

auto root = getRoot(builder.finishedBytes());
auto mapView = root.asMap();
assert(mapView["answer"].asInt64 == 42);
assert(mapView["name"].asString == "D");
```

The builder supports maps, heterogeneous/typed/fixed vectors, strings, keys,
blobs, indirect values, key/string sharing, and value reuse. The reader is
zero-copy and `@nogc nothrow`; invalid or malformed input yields invalid
references or default values. The verifier is also `@nogc nothrow` and can use
an optional caller-provided reuse tracker:

```d
ubyte[] tracker = new ubyte[bytes.length];
if (!verifyBuffer(bytes, VerifierOptions.init, tracker))
    throw new Exception("invalid FlexBuffer");
```

The tracker must be at least as long as the buffer and is cleared for the
checked range before each verification run.

FlexBuffers support does not include JSON/asdf conversion, in-place mutation,
numeric-string casting, or key-vector sharing.

When importing both `flatbuffers` and `flatbuffers.flexbuffers`, qualify
`flatbuffers.flexbuffers.getRoot`, `Verifier`, and `VerifierOptions` to avoid
the same names in the schema-based runtime.

## Use

The runtime backs the generated D bindings. A generated builder flow looks
like this:

```d
import std.typecons : Nullable;

import flatbuffers;
import MyGame.Example.Monster;
import MyGame.Example.Vec3;

auto fbb = FlatBufferBuilder(1024);
const name = fbb.createString("MyMonster");

Monster.startMonster(fbb);
Monster.addName(fbb, name);
const root = Monster.endMonster(fbb);
Monster.finishMonsterBuffer(fbb, root);

const(ubyte)[] bytes = fbb.finishedBytes();
```

Reading is zero-copy:

```d
auto monster = Monster.getRootAsMonster(bytes);
string name = monster.name;          // null when absent
Nullable!Vec3 pos = monster.pos;     // Nullable!T for table/struct fields
auto inventory = monster.inventory(); // allocation-free range
```

The builder constructor takes an explicit initial capacity. Reuse a builder
with `reset()` to avoid reallocating its buffer. Do not copy a builder; create
one per buffer.

## Lifetime and allocation notes

- `finishedBytes()` aliases the builder's buffer. It remains valid until the
  builder grows again, is reset, or is collected.
- Strings, byte vectors, and generated vector ranges alias the input buffer.
  They do not allocate.
- The read and verify paths are `@nogc` where the generated bindings expose
  them.
- Table accessors bounds-check and return defaults or `null` for absent or
  malformed fields. Still verify untrusted input before relying on values.
- The builder allocates only for buffer growth and reusable bookkeeping. Use
  `createSharedString` to deduplicate strings within one buffer.

## JSON with asdf

`--dlang-serialize` emits a `serialize` method on table and struct views.
After adding asdf to your project, import it and call:

```d
import asdf : serializeToJson;

string json = serializeToJson(monster);
```

JSON uses schema field names and enum names. Unions are emitted as the
discriminator plus value (`test_type` and `test`). Pointer and vector fields that are absent
are omitted; scalar and enum fields are always emitted with their values or
defaults. Tables are not deserialized from JSON; enums can be read with asdf.

## Verifying untrusted input

Generated bindings expose a verifier entry point:

```d
if (!Monster.verifyMonsterBuffer(bytes))
    throw new Exception("invalid FlatBuffer");
```

The verifier checks bounds, vtable/object sizes, field alignment, string
termination, vectors, nested tables, and unions. It never throws on malformed
input; it returns `false`.
