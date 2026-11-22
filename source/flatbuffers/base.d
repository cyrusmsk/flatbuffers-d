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

module flatbuffers.base;

static assert(FLATBUFFERS_25_12_19);

import core.stdc.string : memcpy;
import std.exception : assertThrown;
import std.traits : isFloatingPoint, isIntegral;

import flatbuffers.exception : FlatBufferException;

version (BigEndian)
{
    static assert(0, "FlatBuffers D runtime requires a little-endian target");
}

alias UOffsetT = uint;
alias SOffsetT = int;
alias VOffsetT = ushort;

enum sizeBool = 1;
enum sizeByte = 1;
enum sizeUint8 = 1;
enum sizeUint16 = 2;
enum sizeUint32 = 4;
enum sizeUint64 = 8;
enum sizeInt8 = 1;
enum sizeInt16 = 2;
enum sizeInt32 = 4;
enum sizeInt64 = 8;
enum sizeFloat32 = 4;
enum sizeFloat64 = 8;
enum sizeSOffsetT = 4;
enum sizeUOffsetT = 4;
enum sizeVOffsetT = 2;
enum sizePrefixLength = 4;
enum fileIdentifierLength = 4;

enum FLATBUFFERS_25_12_19 = true;

private enum isScalar(T) = is(T == bool) || is(T == enum) ||
    isIntegral!T || isFloatingPoint!T;

T get(T)(const(ubyte)[] buf, size_t off) @trusted @nogc nothrow
if (isScalar!T)
{
    assert(off <= buf.length && T.sizeof <= buf.length - off);
    static if (is(T == bool))
    {
        return buf[off] != 0;
    }
    else
    {
        T value;
        memcpy(&value, buf.ptr + off, T.sizeof);
        return value;
    }
}

bool tryGet(T)(const(ubyte)[] buf, size_t off, out T value)
    @trusted @nogc nothrow
if (isScalar!T)
{
    if (off > buf.length || T.sizeof > buf.length - off)
        return false;

    static if (is(T == bool))
    {
        value = buf[off] != 0;
    }
    else
    {
        memcpy(&value, buf.ptr + off, T.sizeof);
    }
    return true;
}

void put(T)(ubyte[] buf, size_t off, T value) @trusted @nogc nothrow
if (isScalar!T)
{
    assert(off <= buf.length && T.sizeof <= buf.length - off);
    static if (is(T == bool))
    {
        buf[off] = value ? 1 : 0;
    }
    else
    {
        T stored = value;
        memcpy(buf.ptr + off, &stored, T.sizeof);
    }
}

string bytesToString(const(ubyte)[] bytes) @trusted @nogc pure nothrow
{
    return cast(string) bytes;
}

UOffsetT getRoot(const(ubyte)[] buf, size_t offset = 0) @nogc nothrow
{
    UOffsetT relative;
    if (!tryGet!UOffsetT(buf, offset, relative) || relative == 0)
        return 0;

    const size_t target = offset + relative;
    if (target >= buf.length || target > UOffsetT.max)
        return 0;
    return cast(UOffsetT) target;
}

UOffsetT getSizePrefixedRoot(const(ubyte)[] buf, size_t offset = 0)
    @nogc nothrow
{
    const size_t rootOffset = offset + sizePrefixLength;
    UOffsetT relative;
    if (!tryGet!UOffsetT(buf, rootOffset, relative) || relative == 0)
        return 0;

    const size_t target = rootOffset + relative;
    if (target >= buf.length || target > UOffsetT.max)
        return 0;
    return cast(UOffsetT) target;
}

bool bufferHasIdentifier(const(ubyte)[] buf, string identifier,
    size_t offset = 0)
{
    if (identifier.length != fileIdentifierLength)
        throw new FlatBufferException(
            "FlatBuffers: file identifier must be four bytes long");

    const size_t start = offset + sizeUOffsetT;
    if (start > buf.length || fileIdentifierLength > buf.length - start)
        return false;

    foreach (i; 0 .. fileIdentifierLength)
    {
        if (buf[start + i] != cast(ubyte) identifier[i])
            return false;
    }
    return true;
}

bool sizePrefixedBufferHasIdentifier(const(ubyte)[] buf, string identifier,
    size_t offset = 0)
{
    if (identifier.length != fileIdentifierLength)
        throw new FlatBufferException(
            "FlatBuffers: file identifier must be four bytes long");

    const size_t start = offset + sizePrefixLength + sizeUOffsetT;
    if (start > buf.length || fileIdentifierLength > buf.length - start)
        return false;

    foreach (i; 0 .. fileIdentifierLength)
    {
        if (buf[start + i] != cast(ubyte) identifier[i])
            return false;
    }
    return true;
}

unittest
{
    auto buf = new ubyte[128];

    put!byte(buf, 0, -5);
    put!ubyte(buf, 1, 250);
    put!short(buf, 2, -1234);
    put!ushort(buf, 4, 54321);
    put!int(buf, 6, -123456789);
    put!uint(buf, 10, 3_456_789_012);
    put!long(buf, 14, -9_876_543_210_123_456L);
    put!ulong(buf, 22, 18_000_000_000_000_000_000UL);
    put!float(buf, 30, 3.5f);
    put!double(buf, 34, -1.25);
    put!bool(buf, 42, true);
    put!bool(buf, 43, false);

    assert(get!byte(buf, 0) == -5);
    assert(get!ubyte(buf, 1) == 250);
    assert(get!short(buf, 2) == -1234);
    assert(get!ushort(buf, 4) == 54321);
    assert(get!int(buf, 6) == -123456789);
    assert(get!uint(buf, 10) == 3_456_789_012);
    assert(get!long(buf, 14) == -9_876_543_210_123_456L);
    assert(get!ulong(buf, 22) == 18_000_000_000_000_000_000UL);
    assert(get!float(buf, 30) == 3.5f);
    assert(get!double(buf, 34) == -1.25);
    assert(get!bool(buf, 42));
    assert(!get!bool(buf, 43));

    put!int(buf, 47, 0x12345678);
    assert(get!int(buf, 47) == 0x12345678);
}

unittest
{
    auto buf = new ubyte[8];
    uint value;

    assert(tryGet!uint(buf, 0, value));
    assert(!tryGet!uint(buf, buf.length - 3, value));
    assert(!tryGet!uint(buf, size_t.max - 1, value));
}

unittest
{
    auto truncated = new ubyte[3];
    assert(getRoot(truncated) == 0);
    assert(getSizePrefixedRoot(truncated) == 0);
}

unittest
{
    auto buf = new ubyte[16];
    put!UOffsetT(buf, 0, 8);
    assert(getRoot(buf, 0) == 8);

    put!UOffsetT(buf, 0, 100);
    put!UOffsetT(buf, 4, 4);
    assert(getSizePrefixedRoot(buf, 0) == 8);
}

unittest
{
    auto buf = new ubyte[24];
    put!ubyte(buf, 4, 'M');
    put!ubyte(buf, 5, 'O');
    put!ubyte(buf, 6, 'N');
    put!ubyte(buf, 7, 'S');
    put!ubyte(buf, 8, 'M');
    put!ubyte(buf, 9, 'O');
    put!ubyte(buf, 10, 'N');
    put!ubyte(buf, 11, 'S');

    assert(bufferHasIdentifier(buf, "MONS", 0));
    assert(!bufferHasIdentifier(buf, "MONS", 1));
    assert(sizePrefixedBufferHasIdentifier(buf, "MONS", 0));
    assert(!sizePrefixedBufferHasIdentifier(buf, "MONS", 1));
    assertThrown!FlatBufferException(bufferHasIdentifier(buf, "BAD"));
}

unittest
{
    const(ubyte)[] bytes = cast(const(ubyte)[]) "abc";
    string text = bytesToString(bytes);
    assert(text == "abc");
    assert(text.ptr is cast(char*) bytes.ptr);
}
