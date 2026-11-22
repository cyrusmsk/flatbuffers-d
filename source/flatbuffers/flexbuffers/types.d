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

module flatbuffers.flexbuffers.types;

import flatbuffers.exception : FlatBufferException;

enum BitWidth : ubyte
{
    w8 = 0,
    w16 = 1,
    w32 = 2,
    w64 = 3
}

enum FlexBufferType : ubyte
{
    nullValue = 0,
    intValue = 1,
    uintValue = 2,
    floatValue = 3,
    key = 4,
    string = 5,
    indirectInt = 6,
    indirectUInt = 7,
    indirectFloat = 8,
    map = 9,
    vector = 10,
    vectorInt = 11,
    vectorUInt = 12,
    vectorFloat = 13,
    vectorKey = 14,
    vectorStringDeprecated = 15,
    vectorInt2 = 16,
    vectorUInt2 = 17,
    vectorFloat2 = 18,
    vectorInt3 = 19,
    vectorUInt3 = 20,
    vectorFloat3 = 21,
    vectorInt4 = 22,
    vectorUInt4 = 23,
    vectorFloat4 = 24,
    blob = 25,
    boolValue = 26,
    vectorBool = 36,
    maxType = 37
}

class FlexBufferException : FlatBufferException
{
    this(string message) @safe pure nothrow
    {
        super(message);
    }
}

size_t bitWidthBytes(BitWidth width) @nogc nothrow
{
    return size_t(1) << cast(uint) width;
}

bool bitWidthFromBytes(size_t bytes, out BitWidth width) @nogc nothrow
{
    switch (bytes)
    {
        case 1: width = BitWidth.w8; return true;
        case 2: width = BitWidth.w16; return true;
        case 4: width = BitWidth.w32; return true;
        case 8: width = BitWidth.w64; return true;
        default: return false;
    }
}

BitWidth bitWidthFromBits(ubyte bits) @nogc nothrow
{
    return cast(BitWidth) (bits & 3);
}

bool isInline(FlexBufferType type) @nogc nothrow
{
    return type <= FlexBufferType.floatValue || type == FlexBufferType.boolValue;
}

bool isTypedVectorElement(FlexBufferType type) @nogc nothrow
{
    return (type >= FlexBufferType.intValue && type <= FlexBufferType.string) ||
        type == FlexBufferType.boolValue;
}

bool isTypedVector(FlexBufferType type) @nogc nothrow
{
    return (type >= FlexBufferType.vectorInt &&
        type <= FlexBufferType.vectorStringDeprecated) ||
        type == FlexBufferType.vectorBool;
}

bool isFixedTypedVector(FlexBufferType type) @nogc nothrow
{
    return type >= FlexBufferType.vectorInt2 &&
        type <= FlexBufferType.vectorFloat4;
}

bool isVectorType(FlexBufferType type) @nogc nothrow
{
    return (type >= FlexBufferType.map && type <= FlexBufferType.blob) ||
        type == FlexBufferType.vectorBool;
}

bool hasLengthSlot(FlexBufferType type) @nogc nothrow
{
    if (isFixedTypedVector(type))
        return false;
    return isVectorType(type) || type == FlexBufferType.string;
}

size_t fixedVectorLength(FlexBufferType type) @nogc nothrow
{
    if (!isFixedTypedVector(type))
        return 0;
    return (cast(size_t) type - cast(size_t) FlexBufferType.vectorInt2) / 3 + 2;
}

bool typedVectorElementType(FlexBufferType type, out FlexBufferType element)
    @nogc nothrow
{
    if (type == FlexBufferType.vectorBool)
    {
        element = FlexBufferType.boolValue;
        return true;
    }
    if (!isTypedVector(type))
        return false;
    element = cast(FlexBufferType) (cast(uint) type -
        cast(uint) FlexBufferType.vectorInt + cast(uint) FlexBufferType.intValue);
    return true;
}

bool toTypedVectorType(FlexBufferType element, size_t fixedLength,
    out FlexBufferType type) @nogc nothrow
{
    if (!isTypedVectorElement(element))
        return false;
    if (fixedLength == 0)
    {
        type = cast(FlexBufferType) (cast(uint) element -
            cast(uint) FlexBufferType.intValue +
            cast(uint) FlexBufferType.vectorInt);
        return true;
    }
    if (fixedLength < 2 || fixedLength > 4)
        return false;
    if (element != FlexBufferType.intValue &&
        element != FlexBufferType.uintValue &&
        element != FlexBufferType.floatValue)
        return false;
    type = cast(FlexBufferType) (cast(uint) element -
        cast(uint) FlexBufferType.intValue +
        cast(uint) FlexBufferType.vectorInt2 +
        cast(uint) (fixedLength - 2) * 3);
    return true;
}

bool toFixedTypedVectorElementType(FlexBufferType type,
    out FlexBufferType element, out size_t length) @nogc nothrow
{
    if (!isFixedTypedVector(type))
        return false;
    const uint fixedType = cast(uint) type - cast(uint) FlexBufferType.vectorInt2;
    length = fixedType / 3 + 2;
    element = cast(FlexBufferType) (fixedType % 3 +
        cast(uint) FlexBufferType.intValue);
    return true;
}

ubyte packedType(FlexBufferType type, BitWidth width) @nogc nothrow
{
    return cast(ubyte) ((cast(uint) type << 2) | cast(uint) width);
}

bool unpackType(ubyte packed, out FlexBufferType type, out BitWidth width)
    @nogc nothrow
{
    const uint typeBits = packed >> 2;
    if (typeBits >= cast(uint) FlexBufferType.maxType)
        return false;
    type = cast(FlexBufferType) typeBits;
    width = bitWidthFromBits(packed);
    return true;
}

unittest
{
    FlexBufferType type;
    BitWidth width;
    assert(unpackType(packedType(FlexBufferType.intValue, BitWidth.w16),
        type, width));
    assert(type == FlexBufferType.intValue);
    assert(width == BitWidth.w16);
    assert(!unpackType(cast(ubyte) (FlexBufferType.maxType << 2), type, width));
}
