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

module flatbuffers.builder;

import core.stdc.string : memcpy, memset;
import std.algorithm.sorting : sort;
import std.exception : assertThrown;

import flatbuffers.base;
import flatbuffers.exception : FlatBufferException;
import flatbuffers.table : Table;

alias KeyCompare = bool delegate(UOffsetT a, UOffsetT b,
    const(ubyte)[] buf);

struct FlatBufferBuilder
{
    private ubyte[] _buf;
    private size_t _head;
    private size_t _minalign = 1;
    private UOffsetT[] _vtable;
    private UOffsetT[] _vtables;
    private UOffsetT _objectEnd;
    private size_t _vectorNumElems;
    private bool _nested;
    private bool _finished;
    private bool _forceDefaults;
    private UOffsetT[string] _sharedStrings;

    @disable this(this);

    this(size_t initialSize)
    {
        _buf = new ubyte[initialSize];
        _head = initialSize;
    }

    void reset()
    {
        _head = _buf.length;
        _minalign = 1;
        _vtable.length = 0;
        _vtables.length = 0;
        _objectEnd = 0;
        _vectorNumElems = 0;
        _nested = false;
        _finished = false;
        _sharedStrings = null;
    }

    UOffsetT offset() const @nogc nothrow
    {
        return cast(UOffsetT) (_buf.length - _head);
    }

    const(ubyte)[] finishedBytes() const
    {
        if (!_finished)
            throw new FlatBufferException(
                "FlatBuffers: FinishedBytes() requires Finish() first");
        return _buf[_head .. $];
    }

    @property bool forceDefaults() const @nogc nothrow
    {
        return _forceDefaults;
    }

    @property void forceDefaults(bool value) @nogc nothrow
    {
        _forceDefaults = value;
    }

    void pad(size_t size)
    {
        if (size > _head)
            throw new FlatBufferException(
                "FlatBuffers: cannot pad beyond the start of the buffer");
        _head -= size;
        memset(_buf.ptr + _head, 0, size);
    }

    void prep(size_t size, size_t additionalBytes)
    {
        if (size == 0 || (size & (size - 1)) != 0)
            throw new FlatBufferException(
                "FlatBuffers: alignment must be a power of two");

        if (size > _minalign)
            _minalign = size;

        const size_t used = _buf.length - _head;
        if (additionalBytes > size_t.max - used)
            throw new FlatBufferException(
                "FlatBuffers: buffer size overflow");

        const size_t alignSize = (-(used + additionalBytes)) & (size - 1);
        if (additionalBytes > size_t.max - size ||
            alignSize > size_t.max - size - additionalBytes)
            throw new FlatBufferException(
                "FlatBuffers: buffer size overflow");

        const size_t total = alignSize + size + additionalBytes;
        while (_head < total)
        {
            const size_t oldLen = _buf.length;
            growBuffer();
            _head += _buf.length - oldLen;
        }

        pad(alignSize);
    }

    void put(T)(T value) @trusted
    {
        static if (is(T == bool))
        {
            if (_head < 1)
                throw new FlatBufferException(
                    "FlatBuffers: no space left in the builder buffer");
            _head -= 1;
            _buf[_head] = value ? 1 : 0;
        }
        else
        {
            if (_head < T.sizeof)
                throw new FlatBufferException(
                    "FlatBuffers: no space left in the builder buffer");
            _head -= T.sizeof;
            flatbuffers.base.put!T(_buf, _head, value);
        }
    }

    void add(T)(T value)
    {
        prep(T.sizeof, 0);
        put!T(value);
    }

    void add(T)(size_t voffset, T value, T defaultValue)
    {
        if (_forceDefaults || value != defaultValue)
        {
            add!T(value);
            slot(voffset);
        }
    }

    void addOffset(UOffsetT off)
    {
        prep(sizeUOffsetT, 0);
        if (off > offset())
            throw new FlatBufferException(
                "FlatBuffers: offset must be less than current offset");

        const auto relative = offset() - off + sizeUOffsetT;
        put!UOffsetT(relative);
    }

    void addOffset(size_t voffset, UOffsetT value, UOffsetT defaultValue)
    {
        if (value != defaultValue)
        {
            addOffset(value);
            slot(voffset);
        }
    }

    void addStruct(size_t voffset, UOffsetT value, UOffsetT defaultValue)
    {
        if (value != defaultValue)
        {
            if (!_nested)
                throw new FlatBufferException(
                    "FlatBuffers: inline data written outside of an object");
            if (value != offset())
                throw new FlatBufferException(
                    "FlatBuffers: struct must be serialized inline");
            slot(voffset);
        }
    }

    void startObject(size_t numfields)
    {
        notNested();
        _nested = true;
        _vtable.length = numfields;
        _vtable[] = 0;
        _objectEnd = offset();
    }

    UOffsetT endObject()
    {
        if (!_nested)
            throw new FlatBufferException(
                "FlatBuffers: EndObject() called without StartObject()");

        const auto result = writeVtable();
        _nested = false;
        return result;
    }

    void slot(size_t voffset)
    {
        if (voffset >= _vtable.length)
            throw new FlatBufferException(
                "FlatBuffers: slot is outside the current object");
        _vtable[voffset] = offset();
    }

    void required(UOffsetT tableOffset, VOffsetT field) const
    {
        if (tableOffset > _buf.length)
            throw new FlatBufferException(
                "FlatBuffers: required field table is out of range");

        const auto table = Table(_buf, cast(uint) (_buf.length - tableOffset));
        if (table.offset(field) == 0)
            throw new FlatBufferException(
                "FlatBuffers: required field is missing");
    }

    UOffsetT startVector(size_t elemSize, size_t numElems, size_t alignment)
    {
        notNested();
        _nested = true;
        _vectorNumElems = numElems;

        if (numElems != 0 && elemSize > size_t.max / numElems)
            throw new FlatBufferException("FlatBuffers: vector is too large");

        prep(sizeUOffsetT, elemSize * numElems);
        prep(alignment, elemSize * numElems);
        return offset();
    }

    void forceVectorAlignment(size_t len, size_t elemSize, size_t alignment)
    {
        if (len == 0)
            return;
        if (elemSize != 0 && len > size_t.max / elemSize)
            throw new FlatBufferException(
                "FlatBuffers: vector size overflow");
        prep(alignment, len * elemSize);
    }

    UOffsetT endVector(size_t numElems)
    {
        if (!_nested)
            throw new FlatBufferException(
                "FlatBuffers: EndVector() called without StartVector()");

        if (numElems > UOffsetT.max)
            throw new FlatBufferException(
                "FlatBuffers: vector is too large");

        put!UOffsetT(cast(UOffsetT) numElems);
        _nested = false;
        return offset();
    }

    UOffsetT endVector()
    {
        return endVector(_vectorNumElems);
    }

    void finish(UOffsetT rootTable)
    {
        finishInternal(rootTable, false, null);
    }

    void finish(UOffsetT rootTable, string fileIdentifier)
    {
        finishInternal(rootTable, false, fileIdentifier);
    }

    void finishSizePrefixed(UOffsetT rootTable)
    {
        finishInternal(rootTable, true, null);
    }

    void finishSizePrefixed(UOffsetT rootTable, string fileIdentifier)
    {
        finishInternal(rootTable, true, fileIdentifier);
    }

    UOffsetT createString(string value)
    {
        return createByteString(cast(const(ubyte)[]) value);
    }

    UOffsetT createByteString(const(ubyte)[] value)
    {
        notNested();
        _nested = true;

        prep(sizeUOffsetT, value.length + 1);
        put!ubyte(0);

        _head -= value.length;
        if (value.length)
            memcpy(_buf.ptr + _head, value.ptr, value.length);

        return endVector(value.length);
    }

    UOffsetT createByteVector(const(ubyte)[] value)
    {
        notNested();
        _nested = true;

        prep(sizeUOffsetT, value.length);
        _head -= value.length;
        if (value.length)
            memcpy(_buf.ptr + _head, value.ptr, value.length);

        return endVector(value.length);
    }

    UOffsetT createSharedString(string value)
    {
        auto found = value in _sharedStrings;
        if (found !is null)
            return *found;

        const off = createString(value);
        _sharedStrings[value] = off;
        return off;
    }

    UOffsetT createVectorOfTables(const UOffsetT[] offsets)
    {
        startVector(sizeUOffsetT, offsets.length, sizeUOffsetT);
        foreach_reverse (off; offsets)
            addOffset(off);
        return endVector(offsets.length);
    }

    UOffsetT createVectorOfSortedTables(UOffsetT[] offsets,
        KeyCompare keyCompare)
    {
        if (offsets.length > 1)
            sort!((a, b) => keyCompare(a, b, _buf))(offsets);
        return createVectorOfTables(offsets);
    }

    private void notNested()
    {
        if (_nested)
            throw new FlatBufferException(
                "FlatBuffers: object serialization must not be nested");
    }

    private void growBuffer()
    {
        const size_t oldLen = _buf.length;
        if ((oldLen & 0xC0000000) != 0)
            throw new FlatBufferException(
                "FlatBuffers: cannot grow buffer beyond 2 gigabytes");

        size_t newLen = oldLen == 0 ? 1024 : oldLen * 2;
        if (newLen <= oldLen)
            throw new FlatBufferException(
                "FlatBuffers: cannot grow buffer beyond 2 gigabytes");

        auto newBuf = new ubyte[newLen];
        if (oldLen)
            newBuf[newLen - oldLen .. $] = _buf[];
        _buf = newBuf;
    }

    private UOffsetT writeVtable()
    {
        prep(sizeSOffsetT, 0);
        put!SOffsetT(0);
        const UOffsetT objectOffset = offset();

        UOffsetT existingVtable = 0;

        size_t usedSlots = _vtable.length;
        while (usedSlots > 0 && _vtable[usedSlots - 1] == 0)
            --usedSlots;
        _vtable.length = usedSlots;

        foreach_reverse (vt2Offset; _vtables)
        {
            if (vt2Offset > _buf.length)
                continue;

            const size_t vt2Start = _buf.length - vt2Offset;
            if (sizeVOffsetT > _buf.length - vt2Start)
                continue;

            const auto vt2Len = get!VOffsetT(_buf, vt2Start);
            if (vt2Len < 2 * sizeVOffsetT)
                continue;

            const size_t vt2End = vt2Start + vt2Len;
            if (vt2End > _buf.length)
                continue;

            const auto entries = _buf[vt2Start + 2 * sizeVOffsetT .. vt2End];
            if (vtableEqual(_vtable, objectOffset, entries))
            {
                existingVtable = vt2Offset;
                break;
            }
        }

        if (existingVtable == 0)
        {
            foreach_reverse (i; 0 .. _vtable.length)
            {
                UOffsetT fieldOffset = 0;
                if (_vtable[i] != 0)
                    fieldOffset = objectOffset - _vtable[i];
                if (fieldOffset > ushort.max)
                    throw new FlatBufferException(
                        "FlatBuffers: field offset does not fit in 16 bits");
                prependVOffsetT(cast(VOffsetT) fieldOffset);
            }

            const auto objectSize = objectOffset - _objectEnd;
            if (objectSize > ushort.max)
                throw new FlatBufferException(
                    "FlatBuffers: object does not fit in a vtable");

            const auto vtableSize =
                (_vtable.length + 2) * sizeVOffsetT;
            if (vtableSize > ushort.max)
                throw new FlatBufferException(
                    "FlatBuffers: vtable is too large");

            prependVOffsetT(cast(VOffsetT) objectSize);
            prependVOffsetT(cast(VOffsetT) vtableSize);

            const size_t objectStart = _buf.length - objectOffset;
            flatbuffers.base.put!SOffsetT(_buf, objectStart,
                cast(SOffsetT) (offset() - objectOffset));
            _vtables ~= offset();
        }
        else
        {
            const size_t objectStart = _buf.length - objectOffset;
            _head = objectStart;
            flatbuffers.base.put!SOffsetT(_buf, objectStart,
                cast(SOffsetT) (existingVtable - objectOffset));
        }

        _vtable.length = 0;
        return objectOffset;
    }

    private void prependVOffsetT(VOffsetT value)
    {
        prep(sizeVOffsetT, 0);
        put!VOffsetT(value);
    }

    private static bool vtableEqual(const UOffsetT[] fields,
        UOffsetT objectStart, const(ubyte)[] written) @nogc nothrow
    {
        if (fields.length * sizeVOffsetT != written.length)
            return false;

        foreach (i, value; fields)
        {
            const auto other =
                flatbuffers.base.get!VOffsetT(written, i * sizeVOffsetT);
            if (other == 0 && value == 0)
                continue;

            const auto expected =
                cast(SOffsetT) objectStart - cast(SOffsetT) value;
            if (cast(SOffsetT) other != expected)
                return false;
        }
        return true;
    }

    private void finishInternal(UOffsetT rootTable, bool sizePrefixed,
        string fileIdentifier)
    {
        notNested();

        const size_t identifierLength =
            fileIdentifier is null ? 0 : fileIdentifier.length;
        if (identifierLength != 0 && identifierLength != fileIdentifierLength)
            throw new FlatBufferException(
                "FlatBuffers: file identifier must be four bytes long");

        if (identifierLength != 0)
        {
            const size_t extra = sizeUOffsetT + identifierLength +
                (sizePrefixed ? sizePrefixLength : 0);
            prep(_minalign, extra);
            foreach_reverse (i; 0 .. identifierLength)
                put!ubyte(cast(ubyte) fileIdentifier[i]);
        }

        if (sizePrefixed)
            prep(_minalign, sizeUOffsetT + sizePrefixLength);
        else
            prep(_minalign, sizeUOffsetT);

        if (rootTable > offset())
            throw new FlatBufferException(
                "FlatBuffers: root table offset is out of range");

        const auto relativeRoot = offset() - rootTable + sizeUOffsetT;
        put!UOffsetT(relativeRoot);

        if (sizePrefixed)
            put!UOffsetT(offset());

        _finished = true;
    }
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.startObject(2);
    fbb.add!int(0, 42, 0);
    fbb.add!short(1, 7, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto bytes = fbb.finishedBytes();
    auto table = Table(bytes, getRoot(bytes));

    assert(table.getSlot!int(4, 0) == 42);
    assert(table.getSlot!short(6, 0) == 7);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.startObject(1);
    fbb.add!int(0, 0, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes(), 0));
    assert(!table.hasSlot(4));
    assert(table.getSlot!int(4, -1) == -1);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.forceDefaults = true;
    fbb.startObject(1);
    fbb.add!int(0, 0, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes(), 0));
    assert(table.hasSlot(4));
    assert(table.getSlot!int(4, -1) == 0);
}

unittest
{
    auto fbb = FlatBufferBuilder(16);
    fbb.startObject(1);
    fbb.add!int(0, 1, 0);
    fbb.endObject();
    fbb.startObject(1);
    fbb.add!int(0, 2, 0);
    fbb.endObject();

    assert(fbb._vtables.length == 1);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.startObject(1);
    assertThrown!FlatBufferException(fbb.startObject(1));

    auto other = FlatBufferBuilder(1);
    assertThrown!FlatBufferException(other.finishedBytes());

    auto third = FlatBufferBuilder(1);
    third.startObject(1);
    auto root = third.endObject();
    assertThrown!FlatBufferException(third.finish(root, "BAD"));
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.startObject(1);
    fbb.add!int(0, 42, 0);
    auto root = fbb.endObject();
    fbb.finishSizePrefixed(root);

    auto bytes = fbb.finishedBytes();
    assert(get!UOffsetT(bytes, 0) == bytes.length - sizePrefixLength);

    auto table = Table(bytes, getSizePrefixedRoot(bytes, 0));
    assert(table.getSlot!int(4, 0) == 42);
}

unittest
{
    auto fbb = FlatBufferBuilder(16);
    fbb.forceDefaults = true;
    fbb.startObject(1);
    fbb.addOffset(0, 0, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    assert(!table.hasSlot(4));

    auto structBuilder = FlatBufferBuilder(16);
    structBuilder.forceDefaults = true;
    structBuilder.startObject(1);
    structBuilder.addStruct(0, 0, 0);
    root = structBuilder.endObject();
    structBuilder.finish(root);
}

unittest
{
    auto fbb = FlatBufferBuilder(16);
    fbb.startObject(1);
    fbb.add!int(0, 42, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    assertThrown!FlatBufferException(fbb.required(root, 6));

    auto withField = FlatBufferBuilder(16);
    withField.startObject(1);
    withField.add!int(0, 42, 0);
    root = withField.endObject();
    withField.finish(root);
    withField.required(root, 4);
}

unittest
{
    auto fbb = FlatBufferBuilder(0);
    assertThrown!FlatBufferException(fbb.pad(1));
    assertThrown!FlatBufferException(fbb.put!int(1));

    auto other = FlatBufferBuilder(16);
    other.startObject(1);
    other.add!int(0, 42, 0);
    auto root = other.endObject();
    other.finish(root);

    other.reset();
    other.startObject(1);
    other.add!int(0, 7, 0);
    root = other.endObject();
    other.finish(root);

    auto table = Table(other.finishedBytes(), getRoot(other.finishedBytes()));
    assert(table.getSlot!int(4, 0) == 7);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    const name = fbb.createString("hello");

    fbb.startObject(1);
    fbb.addOffset(0, name, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto bytes = fbb.finishedBytes();
    auto table = Table(bytes, getRoot(bytes));
    auto field = table.offset(4) + table.pos;

    assert(table.byteVector(field) == cast(const(ubyte)[]) "hello");

    const size_t stringPos = field + get!UOffsetT(bytes, field);
    assert(bytes[stringPos + sizeUOffsetT + 5] == 0);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    const vec = fbb.createByteVector(cast(const(ubyte)[]) [0, 1, 2, 3, 4]);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    auto field = table.offset(4) + table.pos;
    assert(table.byteVector(field) == cast(const(ubyte)[]) [0, 1, 2, 3, 4]);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
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
    const field = table.offset(4);
    const data = table.vector(field);

    assert(table.vectorLen(field) == 2);
    assert(table.stringAt(data) == "one");
    assert(table.stringAt(data + sizeUOffsetT) == "two");
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    const first = fbb.createSharedString("same");
    const second = fbb.createSharedString("same");
    const other = fbb.createSharedString("other");

    assert(first == second);
    assert(first != other);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);
    fbb.startObject(1);
    fbb.add!double(0, 1.5, 0.0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    const field = table.offset(4) + table.pos;
    assert((field & 7) == 0);
    assert(table.get!double(field) == 1.5);
}

unittest
{
    auto fbb = FlatBufferBuilder(1);

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
    const field = table.offset(4);
    const data = table.vector(field);

    assert(table.vectorLen(field) == 2);
    auto firstTable = Table(table.bytes,
        table.indirect(data));
    auto secondTable = Table(table.bytes,
        table.indirect(data + sizeUOffsetT));
    assert(firstTable.getSlot!int(4, 0) == 10);
    assert(secondTable.getSlot!int(4, 0) == 20);
}

unittest
{
    auto fbb = FlatBufferBuilder(64);

    fbb.startObject(1);
    fbb.add!int(0, 30, 0);
    const third = fbb.endObject();

    fbb.startObject(1);
    fbb.add!int(0, 10, 0);
    const first = fbb.endObject();

    fbb.startObject(1);
    fbb.add!int(0, 20, 0);
    const second = fbb.endObject();

    bool compare(UOffsetT a, UOffsetT b, const(ubyte)[] buf)
    {
        auto left = Table(buf, cast(uint) (buf.length - a));
        auto right = Table(buf, cast(uint) (buf.length - b));
        return left.getSlot!int(4, 0) < right.getSlot!int(4, 0);
    }

    UOffsetT[] offsets = [third, first, second];
    const vec = fbb.createVectorOfSortedTables(offsets, &compare);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    auto table = Table(fbb.finishedBytes(), getRoot(fbb.finishedBytes()));
    const field = table.offset(4);
    const data = table.vector(field);

    assert(table.vectorLen(field) == 3);
    foreach (i, expected; [10, 20, 30])
    {
        auto element = Table(table.bytes,
            table.indirect(cast(UOffsetT) (data + i * sizeUOffsetT)));
        assert(element.getSlot!int(4, 0) == expected);
    }
}
