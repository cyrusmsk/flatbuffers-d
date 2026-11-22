/*
 * Copyright 2026 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module flexbuffers_test;

import std.exception : assertThrown;
import std.file : read;
import std.path : buildPath, dirName;

import flatbuffers.flexbuffers;

private string goldenPath()
{
    return buildPath(dirName(__FILE_FULL_PATH__), "data",
        "gold_flexbuffer_example.bin");
}

private void expectBytes(const(ubyte)[] actual, const(ubyte)[] expected)
{
    assert(actual == expected);
}

private ubyte[] buildGolden()
{
    auto opts = BuilderOptions();
    opts.shareStrings = true;
    auto b = Builder(512, opts);
    auto root = b.startMap();

    auto vec = root.startVector("vec");
    vec.push(-100);
    vec.pushString("Fred");
    vec.pushIndirectFloat(4.0);
    auto reused = vec.lastValue();
    vec.pushBlob(cast(const(ubyte)[]) [77]);
    vec.push(false);
    vec.reuseValue(reused);
    vec.end();

    auto bar = root.startTypedVector("bar");
    bar.pushInt32(1); bar.pushInt32(2); bar.pushInt32(3);
    bar.end();

    auto bar3 = root.startFixedTypedVector("bar3", 3);
    bar3.pushInt32(1); bar3.pushInt32(2); bar3.pushInt32(3);
    bar3.end();

    auto bools = root.startTypedVector("bools");
    bools.push(true); bools.push(false); bools.push(true); bools.push(false);
    bools.end();

    root.put("bool", true);
    root.put("foo", 100.0);
    auto mymap = root.startMap("mymap");
    mymap.putString("foo", "Fred");
    mymap.end();
    root.end();
    b.finish();
    return b.finishedBytes().dup;
}

private void buildNestedInto(ref VectorBuilder parent, uint depth)
{
    if (depth == 0)
        return;
    auto inner = parent.startVector();
    buildNestedInto(inner, depth - 1);
    inner.end();
}

private ubyte[] buildNested(uint depth)
{
    auto builder = Builder();
    auto root = builder.startVector();
    buildNestedInto(root, depth == 0 ? 0 : depth - 1);
    root.end();
    builder.finish();
    return builder.finishedBytes().dup;
}

static assert(__traits(compiles, { Map map; }));
static assert(__traits(compiles, { Vector vector; }));
static assert(__traits(compiles, { Blob blob; }));

void main()
{
    assert(bitWidthBytes(BitWidth.w8) == 1);
    assert(bitWidthBytes(BitWidth.w64) == 8);
    assert(bitWidthFromBits(2) == BitWidth.w32);
    assert(packedType(FlexBufferType.intValue, BitWidth.w8) == 4);
    assert(packedType(FlexBufferType.vector, BitWidth.w8) == 40);
    assert(isInline(FlexBufferType.intValue));
    assert(isTypedVector(FlexBufferType.vectorInt));
    assert(isFixedTypedVector(FlexBufferType.vectorFloat3));
    assert(fixedVectorLength(FlexBufferType.vectorInt3) == 3);
    assert(hasLengthSlot(FlexBufferType.string));
    assert(!hasLengthSlot(FlexBufferType.vectorInt3));
    assert(isVectorType(FlexBufferType.map));

    {
        auto b = Builder();
        b.intValue(13);
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [13, 4, 1]);
    }
    {
        auto b = Builder();
        b.uintValue(250);
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [250, 8, 1]);
    }
    {
        auto b = Builder();
        b.boolValue(true);
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [1, 104, 1]);
    }
    {
        auto b = Builder();
        b.nullValue();
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [0, 0, 1]);
    }
    {
        auto b = Builder();
        b.floatValue(4.0f);
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [0, 0, 128, 64, 14, 4]);
    }
    {
        auto b = Builder();
        b.doubleValue(3.14159);
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [110, 134, 27, 240, 249, 33, 9, 64, 15, 8]);
    }
    {
        auto b = Builder();
        b.stringValue("Fred");
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [4, 70, 114, 101, 100, 0, 5, 20, 1]);
    }
    {
        auto b = Builder();
        b.blobValue(cast(const(ubyte)[]) [77]);
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [1, 77, 1, 100, 1]);
    }
    {
        auto b = Builder();
        b.alignedBlobValue(
            cast(const(ubyte)[]) [88, 0, 0, 0, 99, 0, 0, 0],
            BitWidth.w32);
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [8, 0, 0, 0, 88, 0, 0, 0, 99, 0, 0, 0,
                8, 102, 1]);
    }
    {
        auto b = Builder();
        b.indirectInt(-100);
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [156, 1, 24, 1]);
    }
    {
        auto b = Builder();
        b.indirectUInt(250);
        b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [250, 1, 28, 1]);
    }
    {
        auto b = Builder();
        b.indirectFloat(4.0);
        b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [0, 0, 128, 64, 4, 34, 1]);
    }
    {
        auto b = Builder();
        assertThrown!FlexBufferException(b.finish());
        b.intValue(1);
        assertThrown!FlexBufferException(b.finishedBytes());
        b.finish();
        b.reset();
        b.intValue(2);
        b.finish();
        assert(b.finishedBytes() == cast(const(ubyte)[]) [2, 4, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startTypedVector();
        v.push(1); v.push(2); v.push(3);
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [3, 1, 2, 3, 3, 44, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        v.push(1); v.push(2); v.push(3);
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [3, 1, 2, 3, 4, 4, 4, 6, 40, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startFixedTypedVector(3);
        v.push(1); v.push(2); v.push(3);
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [1, 2, 3, 3, 76, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startTypedVector();
        v.push(true); v.push(false); v.push(true); v.push(false);
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [4, 1, 0, 1, 0, 4, 144, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        v.end(); b.finish();
        expectBytes(b.finishedBytes(), cast(const(ubyte)[]) [0, 0, 40, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startTypedVector();
        v.push(1);
        v.pushString("x");
        assertThrown!FlexBufferException(v.end());
    }
    {
        auto b = Builder();
        assertThrown!FlexBufferException(b.startFixedTypedVector(5));
    }

    {
        auto b = Builder();
        auto v = b.startVector();
        v.pushIndirectFloat(4.0);
        auto indirect = v.lastValue();
        v.pushIndirectFloat(4.0);
        v.reuseValue(indirect);
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [0, 0, 128, 64, 0, 0, 128, 64, 3, 9, 6, 11,
                34, 34, 34, 6, 40, 1]);
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        v.push(1); v.push(2); v.undo();
        v.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [1, 1, 4, 2, 40, 1]);
    }

    {
        auto b = Builder();
        auto m = b.startMap();
        m.put("foo", 100);
        m.end(); b.finish();
        expectBytes(b.finishedBytes(),
            cast(const(ubyte)[]) [102, 111, 111, 0, 1, 5, 1, 1, 1, 100, 4,
                2, 36, 1]);
    }
    {
        auto b = Builder();
        auto m = b.startMap();
        m.put("a", 1);
        m.put("a", 2);
        m.end();
        assert(b.hasDuplicateKeys);
    }
    {
        auto opts = BuilderOptions();
        opts.shareStrings = true;
        auto b = Builder(256, opts);
        auto m = b.startMap();
        m.putString("a", "same");
        m.putString("b", "same");
        m.end(); b.finish();
        import std.algorithm.searching : count;
        assert(b.finishedBytes().count(cast(ubyte) 's') == 1);

        auto unshared = Builder();
        auto m2 = unshared.startMap();
        m2.putString("a", "same");
        m2.putString("b", "same");
        m2.end(); unshared.finish();
        assert(unshared.finishedBytes().count(cast(ubyte) 's') == 2);
    }
    {
        auto golden = cast(const(ubyte)[]) read(goldenPath());
        assert(buildGolden() == golden);
    }

    {
        auto b = Builder();
        b.intValue(13);
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isValid);
        assert(r.isInt);
        assert(!r.getInt64.isNull);
        assert(r.getInt64.get == 13);
        assert(r.asInt64 == 13);
    }
    {
        auto b = Builder();
        b.uintValue(250);
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isUInt);
        assert(!r.getUInt64.isNull);
        assert(r.getUInt64.get == 250);
    }
    {
        auto b = Builder();
        b.floatValue(4.0f);
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isFloat);
        assert(!r.getDouble.isNull);
        assert(r.getDouble.get == 4.0);
        assert(r.asDouble == 4.0);
    }
    {
        auto b = Builder();
        b.boolValue(true);
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isBool);
        assert(r.asBool);
    }
    {
        auto b = Builder();
        b.stringValue("Fred");
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isString);
        assert(!r.getString.isNull);
        assert(r.getString.get == "Fred");
        assert(r.asString == "Fred");
    }
    {
        auto b = Builder();
        b.blobValue(cast(const(ubyte)[]) [77]);
        b.finish();
        auto r = getRoot(b.finishedBytes());
        assert(r.isBlob);
        assert(!r.getBlob.isNull);
        assert(r.getBlob.get.data == cast(const(ubyte)[]) [77]);
    }
    {
        assert(getRoot(null).isValid == false);
        assert(getRoot(cast(const(ubyte)[]) [1, 2]).isValid == false);
        assert(getRoot(cast(const(ubyte)[]) [0, 0, 3]).isValid == false);
        assert(getRoot(cast(const(ubyte)[]) [0, 0xfc, 1]).isValid == false);
    }
    {
        static void checkGcFree() @nogc nothrow
        {
            auto r = getRoot(null);
            assert(!r.isValid);
            assert(r.asInt64 == 0);
            assert(r.asString is null);
        }
        checkGcFree();
    }

    {
        auto b = Builder();
        auto m = b.startMap();
        m.put("foo", 100);
        m.end(); b.finish();

        auto root = getRoot(b.finishedBytes());
        assert(root.isMap);
        auto map = root.asMap();
        assert(map.isValid);
        assert(map.length == 1);
        assert(map.contains("foo"));
        assert(map["foo"].asInt64 == 100);
        assert(!map.contains("missing"));
        assert(!map["missing"].isValid);
    }
    {
        auto b = Builder();
        auto v = b.startTypedVector();
        v.push(1); v.push(2); v.push(3);
        v.end(); b.finish();

        auto root = getRoot(b.finishedBytes());
        auto vec = root.asVector();
        assert(vec.isValid);
        assert(vec.length == 3);
        assert(vec.isTyped);
        assert(vec.elementType == FlexBufferType.intValue);
        assert(vec[0].asInt64 == 1);
        assert(vec[2].asInt64 == 3);
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        v.end(); b.finish();
        auto vec = getRoot(b.finishedBytes()).asVector();
        assert(vec.isValid);
        assert(vec.length == 0);
        assert(!vec[0].isValid);
    }
    {
        auto b = Builder();
        b.alignedBlobValue(
            cast(const(ubyte)[]) [88, 0, 0, 0, 99, 0, 0, 0],
            BitWidth.w32);
        b.finish();
        auto blob = getRoot(b.finishedBytes()).asBlob();
        assert(blob.data ==
            cast(const(ubyte)[]) [88, 0, 0, 0, 99, 0, 0, 0]);
        assert((cast(size_t) blob.data.ptr & 3) == 0);
    }
    {
        auto golden = cast(const(ubyte)[]) read(goldenPath());
        auto root = getRoot(golden);
        assert(root.isMap);
        auto map = root.asMap();
        auto vec = map["vec"].asVector();
        assert(vec[0].asInt64 == -100);
        assert(vec[1].asString == "Fred");
        assert(vec[2].asDouble == 4.0);
        assert(vec[3].asBlob.data == cast(const(ubyte)[]) [77]);
        assert(vec[4].asBool == false);
        assert(vec[5].asDouble == 4.0);
        assert(map["bar"].asVector().length == 3);
        assert(map["bar3"].asVector().isFixed);
        assert(map["bools"].asVector().length == 4);
        assert(map["bool"].asBool == true);
        assert(map["foo"].asDouble == 100.0);
        assert(map["mymap"].asMap()["foo"].asString == "Fred");
        auto bar = map["bar"].asVector();
        assert(bar.elementType == FlexBufferType.intValue);
        assert(bar[2].asInt64 == 3);
        auto bar3 = map["bar3"].asVector();
        assert(bar3.elementType == FlexBufferType.intValue);
        assert(bar3[2].asInt64 == 3);
        auto keys = map.keys();
        assert(keys.length == map.length);
        assert(keys[0].asKey == "bar");
        auto values = map.values();
        assert(values.length == map.length);
        assert(values[0].asVector().length == 3);
    }

    {
        auto b = Builder();
        auto v = b.startVector();
        foreach (_; 0 .. 130)
            v.pushUInt8(255);
        v.end(); b.finish();
        auto vec = getRoot(b.finishedBytes()).asVector();
        assert(vec.length == 130);
        assert(vec[0].asUInt64 == 255);
        assert(vec[129].asUInt64 == 255);
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        v.pushIndirectFloat(4.0);
        auto indirect = v.lastValue();
        v.pushIndirectFloat(4.0);
        v.reuseValue(indirect);
        v.end(); b.finish();
        auto vec = getRoot(b.finishedBytes()).asVector();
        assert(vec.length == 3);
        assert(vec[0].asDouble == 4.0);
        assert(vec[1].asDouble == 4.0);
        assert(vec[2].asDouble == 4.0);
    }

    {
        auto golden = cast(const(ubyte)[]) read(goldenPath());
        assert(verifyBuffer(golden));
        assert(verifyBuffer(buildGolden()));
        assert(!verifyBuffer(null));
        assert(!verifyBuffer(cast(const(ubyte)[]) [1, 2]));
        assert(!verifyBuffer(cast(const(ubyte)[]) [0, 0, 0]));
        assert(!verifyBuffer(cast(const(ubyte)[]) [0, 0xfc, 1]));
    }
    {
        auto b = Builder();
        b.stringValue("Fred");
        b.finish();
        auto bad = b.finishedBytes().dup;
        bad[0] = 255;
        assert(!verifyBuffer(bad));

        auto missingNul = b.finishedBytes().dup;
        missingNul[5] = cast(ubyte) 'X';
        assert(!verifyBuffer(missingNul));
    }
    {
        auto simpleMap = cast(const(ubyte)[])
            [102, 111, 111, 0, 1, 5, 1, 1, 1, 100, 4, 2, 36, 1];
        auto badKeyWidth = simpleMap.dup;
        badKeyWidth[7] = 3;
        assert(!verifyBuffer(badKeyWidth));

        auto hetero = cast(const(ubyte)[]) [3, 1, 2, 3, 4, 4, 4, 6, 40, 1];
        auto badType = hetero.dup;
        badType[4] = 0xff;
        assert(!verifyBuffer(badType));
    }
    {
        auto nested = buildNested(65);
        assert(!verifyBuffer(nested, VerifierOptions(64)));
        assert(verifyBuffer(nested, VerifierOptions(128)));
    }
    {
        auto golden = cast(const(ubyte)[]) read(goldenPath());
        auto tracker = new ubyte[golden.length];
        assert(verifyBuffer(golden, VerifierOptions.init, tracker));
        assert(verifyBuffer(buildGolden(), VerifierOptions.init, tracker));
        assert(!verifyBuffer(golden, VerifierOptions.init,
            new ubyte[golden.length - 1]));
    }

    assertThrown!FlexBufferException(MapBuilder.init.end());
    assertThrown!FlexBufferException(VectorBuilder.init.end());
    assertThrown!FlexBufferException(MapBuilder.init.put("x", 1));
    assertThrown!FlexBufferException(VectorBuilder.init.push(1));
    static assert(!__traits(compiles, { MapBuilder a; MapBuilder b = a; }));
    static assert(!__traits(compiles, { VectorBuilder a; VectorBuilder b = a; }));

    {
        auto malformed = cast(const(ubyte)[]) [0, 0, 2, 20, 1];
        auto r = getRoot(malformed);
        assert(r.isString);
        assert(r.getString.isNull);
        assert(r.asString is null);
    }
    {
        auto b = Builder();
        b.stringValue("Fred");
        b.finish();
        auto badLength = b.finishedBytes().dup;
        badLength[0] = 255;
        assert(getRoot(badLength).getString.isNull);
        assert(!verifyBuffer(badLength));

        auto missingNul = b.finishedBytes().dup;
        missingNul[5] = cast(ubyte) 'X';
        assert(getRoot(missingNul).getString.isNull);
        assert(!verifyBuffer(missingNul));
    }
    {
        auto b = Builder();
        b.blobValue(cast(const(ubyte)[]) [77]);
        b.finish();
        auto badLength = b.finishedBytes().dup;
        badLength[0] = 255;
        assert(getRoot(badLength).getBlob.isNull);
        assert(!verifyBuffer(badLength));
        assert(!verifyBuffer(b.finishedBytes()[0 .. $ - 1]));
    }
    {
        auto simpleMap = cast(const(ubyte)[])
            [102, 111, 111, 0, 1, 5, 1, 1, 1, 100, 4, 2, 36, 1];
        auto badKeyOffset = simpleMap.dup;
        badKeyOffset[6] = 255;
        assert(!verifyBuffer(badKeyOffset));
        assert(!getRoot(badKeyOffset).asMap().isValid);

        auto badKeyWidth = simpleMap.dup;
        badKeyWidth[7] = 3;
        assert(!verifyBuffer(badKeyWidth));
        assert(!getRoot(badKeyWidth).asMap().isValid);

        auto badKeyNul = simpleMap.dup;
        badKeyNul[3] = cast(ubyte) 'X';
        assert(!verifyBuffer(badKeyNul));
        assert(!getRoot(badKeyNul).asMap().contains("foo"));
    }
    {
        assert(!verifyBuffer(cast(const(ubyte)[]) [0, 2, 40, 1]));
    }
    {
        auto deprecatedBytes = cast(const(ubyte)[])
            [1, 97, 0, 1, 98, 0, 2, 6, 4, 2, 60, 1];
        assert(verifyBuffer(deprecatedBytes));
        auto vec = getRoot(deprecatedBytes).asVector();
        assert(vec.isValid);
        assert(vec.isTyped);
        assert(vec.elementType == FlexBufferType.key);
        assert(vec[0].asKey == "a");
        assert(vec[1].asKey == "b");
    }
    {
        auto b = Builder();
        b.stringValue("héllo");
        b.finish();
        assert(verifyBuffer(b.finishedBytes()));
        assert(getRoot(b.finishedBytes()).asString == "héllo");
    }
    {
        auto b = Builder();
        auto m = b.startMap();
        auto empty = m.startVector("vec");
        empty.end();
        m.put("bool", true);
        m.end(); b.finish();
        assert(verifyBuffer(b.finishedBytes()));
        auto map = getRoot(b.finishedBytes()).asMap();
        assert(map["vec"].asVector().length == 0);
        assert(map["bool"].asBool);
    }

    {
        auto b = Builder();
        auto m = b.startMap();
        m.putNull("null");
        m.putBlob("blob", cast(const(ubyte)[]) [1, 2]);
        m.putAlignedBlob("aligned", cast(const(ubyte)[]) [1, 0, 0, 0],
            BitWidth.w32);
        m.putIndirectInt("ii", -100);
        m.putIndirectUInt("iu", 250);
        m.putIndirectFloat("if", 4.0);
        m.putKey("key", "value");
        m.end(); b.finish();
        assert(verifyBuffer(b.finishedBytes()));
        auto map = getRoot(b.finishedBytes()).asMap();
        assert(map["null"].isNull);
        assert(map["blob"].asBlob.data == cast(const(ubyte)[]) [1, 2]);
        assert(map["aligned"].asBlob.data == cast(const(ubyte)[]) [1, 0, 0, 0]);
        assert(map["ii"].asInt64 == -100);
        assert(map["iu"].asUInt64 == 250);
        assert(map["if"].asDouble == 4.0);
        assert(map["key"].asKey == "value");
    }
    {
        foreach (value; [-129L, -128L, 127L, 128L])
        {
            auto b = Builder();
            b.intValue(value);
            b.finish();
            assert(verifyBuffer(b.finishedBytes()));
            assert(getRoot(b.finishedBytes()).asInt64 == value);
        }
        foreach (value; [255UL, 256UL])
        {
            auto b = Builder();
            b.uintValue(value);
            b.finish();
            assert(verifyBuffer(b.finishedBytes()));
            assert(getRoot(b.finishedBytes()).asUInt64 == value);
        }
    }
    {
        auto b = Builder();
        auto v = b.startVector();
        foreach (_; 0 .. 65536)
            v.pushUInt8(1);
        v.end(); b.finish();
        assert(verifyBuffer(b.finishedBytes()));
        auto vec = getRoot(b.finishedBytes()).asVector();
        assert(vec.length == 65536);
        assert(vec[0].asUInt64 == 1);
        assert(vec[65535].asUInt64 == 1);
    }

    {
        static void checkContainerAccess() @nogc nothrow
        {
            auto root = getRoot(null);
            auto map = root.asMap();
            auto vec = root.asVector();
            assert(map.length == 0);
            assert(vec.length == 0);
            assert(root.getMap.isNull);
            assert(root.getVector.isNull);
            assert(!verifyBuffer(null));
        }
        checkContainerAccess();
    }

    {
        auto misaligned = cast(const(ubyte)[]) [0, 1, 0, 42, 0, 2, 49, 1];
        assert(!verifyBuffer(misaligned));
        assert(verifyBuffer(misaligned, VerifierOptions(64, false)));
    }

}
