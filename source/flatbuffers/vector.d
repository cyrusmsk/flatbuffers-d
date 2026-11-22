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

module flatbuffers.vector;

import flatbuffers.base;
import flatbuffers.builder : FlatBufferBuilder;
import flatbuffers.table : Struct, Table;


struct ScalarVector(T)
{
    Table _tab;
    VOffsetT vtableOffset;

    private UOffsetT field() const @nogc nothrow
    {
        return _tab.offset(vtableOffset);
    }

    @property size_t length() const @nogc nothrow
    {
        const offset = field();
        return offset == 0 ? 0 : _tab.vectorLen(offset);
    }

    T opIndex(size_t index) const @nogc nothrow
    {
        if (index >= length)
            return T.init;

        const offset = field();
        if (offset == 0)
            return T.init;

        const data = _tab.vector(offset);
        if (data == 0)
            return T.init;

        return _tab.get!T(data + cast(UOffsetT) (index * T.sizeof));
    }

    int opApply(scope int delegate(T) dg) const
    {
        foreach (i; 0 .. length)
        {
            const result = dg(opIndex(i));
            if (result)
                return result;
        }
        return 0;
    }
}

struct StringVector
{
    Table _tab;
    VOffsetT vtableOffset;

    private UOffsetT field() const @nogc nothrow
    {
        return _tab.offset(vtableOffset);
    }

    @property size_t length() const @nogc nothrow
    {
        const offset = field();
        return offset == 0 ? 0 : _tab.vectorLen(offset);
    }

    string opIndex(size_t index) const @nogc nothrow
    {
        if (index >= length)
            return null;

        const offset = field();
        if (offset == 0)
            return null;

        const data = _tab.vector(offset);
        if (data == 0)
            return null;

        return _tab.stringAt(data +
            cast(UOffsetT) (index * sizeUOffsetT));
    }

    int opApply(scope int delegate(string) dg) const
    {
        foreach (i; 0 .. length)
        {
            const result = dg(opIndex(i));
            if (result)
                return result;
        }
        return 0;
    }
}

struct TableVector(T)
{
    Table _tab;
    VOffsetT vtableOffset;

    private UOffsetT field() const @nogc nothrow
    {
        return _tab.offset(vtableOffset);
    }

    @property size_t length() const @nogc nothrow
    {
        const offset = field();
        return offset == 0 ? 0 : _tab.vectorLen(offset);
    }

    T opIndex(size_t index) const @nogc nothrow
    {
        if (index >= length)
            return T.init;

        const offset = field();
        if (offset == 0)
            return T.init;

        const data = _tab.vector(offset);
        if (data == 0)
            return T.init;

        const target = _tab.indirect(data +
            cast(UOffsetT) (index * sizeUOffsetT));
        if (target == 0)
            return T.init;

        return T(_tab.bytes, target);
    }

    int opApply(scope int delegate(T) dg) const
    {
        foreach (i; 0 .. length)
        {
            const result = dg(opIndex(i));
            if (result)
                return result;
        }
        return 0;
    }
}

struct StructVector(T, size_t elementSize)
{
    Table _tab;
    VOffsetT vtableOffset;

    private UOffsetT field() const @nogc nothrow
    {
        return _tab.offset(vtableOffset);
    }

    @property size_t length() const @nogc nothrow
    {
        const offset = field();
        return offset == 0 ? 0 : _tab.vectorLen(offset);
    }

    T opIndex(size_t index) const @nogc nothrow
    {
        if (index >= length)
            return T.init;

        const offset = field();
        if (offset == 0)
            return T.init;

        const data = _tab.vector(offset);
        if (data == 0)
            return T.init;

        const target = data + cast(UOffsetT) (index * elementSize);
        if (target > _tab.bytes.length ||
            elementSize > _tab.bytes.length - target)
            return T.init;

        return T(_tab.bytes, target);
    }

    int opApply(scope int delegate(T) dg) const
    {
        foreach (i; 0 .. length)
        {
            const result = dg(opIndex(i));
            if (result)
                return result;
        }
        return 0;
    }
}

private struct LocalItem
{
    Table _tab;

    this(const(ubyte)[] bytes, uint pos) @nogc nothrow
    {
        _tab = Table(bytes, pos);
    }

    int value() const @nogc nothrow
    {
        return _tab.getSlot!int(4, 0);
    }
}

private struct LocalStruct
{
    Struct _tab;

    this(const(ubyte)[] bytes, uint pos) @nogc nothrow
    {
        _tab = Struct(bytes, pos);
    }

    short a() const @nogc nothrow
    {
        return _tab.get!short(_tab.pos + 0);
    }

    byte b() const @nogc nothrow
    {
        return _tab.get!byte(_tab.pos + 2);
    }
}

unittest
{
    auto fbb = FlatBufferBuilder(64);
    const vec = fbb.createByteVector(cast(const(ubyte)[]) [9, 8, 7]);
    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    auto values = ScalarVector!ubyte(table, 4);

    assert(values.length == 3);
    assert(values[0] == 9);
    assert(values[1] == 8);
    assert(values[2] == 7);
    assert(values[3] == 0);
}

unittest
{
    auto fbb = FlatBufferBuilder(64);
    const first = fbb.createString("one");
    const second = fbb.createString("two");
    fbb.startVector(sizeUOffsetT, 2, sizeUOffsetT);
    fbb.addOffset(second);
    fbb.addOffset(first);
    const vec = fbb.endVector(2);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    auto values = StringVector(table, 4);

    assert(values.length == 2);
    assert(values[0] == "one");
    assert(values[1] == "two");
    assert(values[2] is null);
}

unittest
{
    auto fbb = FlatBufferBuilder(64);

    fbb.startObject(1);
    fbb.add!int(0, 10, 0);
    const first = fbb.endObject();

    fbb.startObject(1);
    fbb.add!int(0, 20, 0);
    const second = fbb.endObject();

    fbb.startVector(sizeUOffsetT, 2, sizeUOffsetT);
    fbb.addOffset(second);
    fbb.addOffset(first);
    const vec = fbb.endVector(2);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    auto values = TableVector!LocalItem(table, 4);

    assert(values.length == 2);
    assert(values[0].value == 10);
    assert(values[1].value == 20);
    assert(values[2]._tab.bytes is null);
}

unittest
{
    auto fbb = FlatBufferBuilder(64);
    fbb.startVector(4, 2, 2);
    fbb.put!int(0x0028_001E);
    fbb.put!int(0x0014_000A);
    const vec = fbb.endVector(2);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    auto values = StructVector!(LocalStruct, 4)(table, 4);

    assert(values.length == 2);
    assert(values[0].a == 10);
    assert(values[0].b == 20);
    assert(values[1].a == 30);
    assert(values[1].b == 40);
    assert(values[2]._tab.bytes is null);
}
