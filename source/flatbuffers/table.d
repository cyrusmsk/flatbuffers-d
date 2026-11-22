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

module flatbuffers.table;

import std.typecons : Nullable;

import flatbuffers.base;
import flatbuffers.base : baseGet = get;

struct Table
{
    const(ubyte)[] bytes;
    uint pos;

    this(const(ubyte)[] bytes, uint pos) @nogc nothrow
    {
        this.bytes = bytes;
        this.pos = pos;
    }

    UOffsetT offset(VOffsetT vtableOffset) const @nogc nothrow
    {
        if (vtableOffset < 2 * sizeVOffsetT)
            return 0;

        if (pos > bytes.length || sizeSOffsetT > bytes.length - pos)
            return 0;

        const long vtable = cast(long) pos - baseGet!SOffsetT(bytes, pos);
        if (vtable < 0)
            return 0;

        const size_t vtablePos = cast(size_t) vtable;
        if (vtablePos > bytes.length ||
            2 * sizeVOffsetT > bytes.length - vtablePos)
            return 0;

        const auto vtableSize = baseGet!VOffsetT(bytes, vtablePos);
        if (vtableSize < 2 * sizeVOffsetT ||
            vtableSize > bytes.length - vtablePos)
            return 0;

        const auto objectSize =
            baseGet!VOffsetT(bytes, vtablePos + sizeVOffsetT);
        if (objectSize < sizeSOffsetT ||
            objectSize > bytes.length - pos)
            return 0;

        if (cast(size_t) vtableOffset + sizeVOffsetT > vtableSize)
            return 0;

        const auto fieldOff =
            baseGet!VOffsetT(bytes, vtablePos + vtableOffset);
        if (fieldOff == 0)
            return 0;
        if (fieldOff < sizeSOffsetT || fieldOff >= objectSize)
            return 0;

        return fieldOff;
    }

    UOffsetT indirect(UOffsetT off) const @nogc nothrow
    {
        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, off, relative) || relative == 0)
            return 0;

        const size_t target = cast(size_t) off + relative;
        if (target >= bytes.length)
            return 0;
        return cast(UOffsetT) target;
    }

    string stringAt(UOffsetT absoluteOff) const @trusted @nogc nothrow
    {
        const auto data = byteVector(absoluteOff);
        return data is null ? null : bytesToString(data);
    }

    const(ubyte)[] byteVector(UOffsetT absoluteOff) const
        @trusted @nogc nothrow
    {
        size_t off = absoluteOff;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return null;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, off, relative) || relative == 0)
            return null;

        off = off + relative;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return null;

        const auto length = baseGet!UOffsetT(bytes, off);
        const size_t start = off + sizeUOffsetT;
        if (start > bytes.length || length > bytes.length - start)
            return null;

        return bytes[start .. start + length];
    }

    size_t vectorLen(UOffsetT fieldOff) const @nogc nothrow
    {
        size_t off = cast(size_t) pos + fieldOff;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return 0;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, off, relative) || relative == 0)
            return 0;

        off = off + relative;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return 0;

        const auto length = baseGet!UOffsetT(bytes, off);
        const size_t dataPos = off + sizeUOffsetT;
        if (dataPos > bytes.length)
            return 0;

        const size_t remaining = bytes.length - dataPos;
        return length > remaining ? remaining : length;
    }

    UOffsetT vector(UOffsetT fieldOff) const @nogc nothrow
    {
        size_t off = cast(size_t) pos + fieldOff;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return 0;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, off, relative) || relative == 0)
            return 0;

        off = off + relative;
        if (off > bytes.length || sizeUOffsetT > bytes.length - off)
            return 0;

        return cast(UOffsetT) (off + sizeUOffsetT);
    }

    Table unionAt(UOffsetT fieldOff) const @nogc nothrow
    {
        const size_t off = cast(size_t) pos + fieldOff;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, off, relative) || relative == 0)
            return Table(null, 0);

        const size_t tablePos = off + relative;
        if (tablePos >= bytes.length)
            return Table(null, 0);

        return Table(bytes, cast(uint) tablePos);
    }

    T get(T)(UOffsetT absoluteOff) const @trusted @nogc nothrow
    {
        T value;
        if (!tryGet!T(bytes, absoluteOff, value))
            return T.init;
        return value;
    }

    T getSlot(T)(VOffsetT vtableOffset, T defaultValue) const
        @trusted @nogc nothrow
    {
        const o = offset(vtableOffset);
        if (o == 0)
            return defaultValue;

        return baseGet!T(bytes, pos + o);
    }

    bool hasSlot(VOffsetT vtableOffset) const @nogc nothrow
    {
        return offset(vtableOffset) != 0;
    }

    Nullable!T getSlotNullable(T)(VOffsetT vtableOffset) const
        @nogc nothrow
    {
        const o = offset(vtableOffset);
        if (o == 0)
            return Nullable!T.init;
        return Nullable!T(get!T(pos + o));
    }
}

struct Struct
{
    Table table;
    alias table this;

    this(const(ubyte)[] bytes, uint pos) @nogc nothrow
    {
        this.table = Table(bytes, pos);
    }
}

unittest
{
    auto buf = new ubyte[64];

    // vtable at 0: size 12, object size 20, four field slots.
    put!VOffsetT(buf, 0, 12);
    put!VOffsetT(buf, 2, 20);
    put!VOffsetT(buf, 4, 4);
    put!VOffsetT(buf, 6, 8);
    put!VOffsetT(buf, 8, 12);
    put!VOffsetT(buf, 10, 16);

    // table at 16, pointing back to the vtable at 0.
    put!SOffsetT(buf, 16, 16);
    put!int(buf, 20, 42);
    put!short(buf, 24, 7);
    put!UOffsetT(buf, 28, 12); // string at 40
    put!UOffsetT(buf, 32, 16); // vector at 48

    // string at 40
    put!UOffsetT(buf, 40, 3);
    put!ubyte(buf, 44, 'a');
    put!ubyte(buf, 45, 'b');
    put!ubyte(buf, 46, 'c');
    put!ubyte(buf, 47, 0);

    // vector at 48
    put!UOffsetT(buf, 48, 3);
    put!ubyte(buf, 52, 9);
    put!ubyte(buf, 53, 8);
    put!ubyte(buf, 54, 7);

    auto table = Table(buf, 16);

    assert(table.offset(4) == 4);
    assert(table.offset(6) == 8);
    assert(table.getSlot!int(4, 0) == 42);
    assert(table.getSlot!short(6, 0) == 7);
    assert(table.getSlot!int(14, -1) == -1);
    assert(table.hasSlot(4));
    assert(!table.hasSlot(14));
    assert(table.stringAt(28) == "abc");
    assert(table.byteVector(32) == cast(const(ubyte)[]) [9, 8, 7]);
    assert(table.vectorLen(16) == 3);
    assert(table.vector(16) == 52);
    assert(table.vectorLen(6) == 0);

    auto fixedStruct = Struct(buf, 20);
    assert(fixedStruct.get!int(fixedStruct.pos + 0) == 42);
    assert(fixedStruct.get!short(fixedStruct.pos + 4) == 7);

    auto present = table.getSlotNullable!int(4);
    assert(!present.isNull);
    assert(present.get == 42);
    assert(table.getSlotNullable!int(14).isNull);
}

unittest
{
    auto buf = new ubyte[3];
    auto table = Table(buf, 0);

    assert(table.get!int(0) == 0);
    assert(table.get!long(0) == 0);
    assert(table.get!bool(0) == false);
    assert(table.offset(4) == 0);
    assert(table.indirect(0) == 0);
    assert(table.unionAt(0).bytes is null);
    assert(table.getSlot!int(4, 7) == 7);
    assert(table.getSlotNullable!int(4).isNull);
    assert(table.vectorLen(0) == 0);
    assert(table.vector(0) == 0);
    assert(table.byteVector(0) is null);
}

unittest
{
    auto buf = new ubyte[16];
    auto table = Table(buf, 0);

    assert(table.byteVector(13) is null);
    assert(table.stringAt(13) is null);
}
