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

module flatbuffers.flexbuffers.verifier;

import flatbuffers.flexbuffers.types;

struct VerifierOptions
{
    uint maxDepth = 64;
    bool alignmentCheck = true;
}

private enum MarkResult
{
    firstVisit,
    alreadyVerified,
    conflict
}

private bool readUIntAt(const(ubyte)[] buffer, size_t position,
    BitWidth width, out ulong value) @nogc nothrow
{
    const bytes = bitWidthBytes(width);
    if (position > buffer.length || bytes > buffer.length - position)
        return false;

    value = 0;
    foreach (i; 0 .. bytes)
        value |= cast(ulong) buffer[position + i] << (8 * i);
    return true;
}

struct Verifier
{
    private const(ubyte)[] _buffer;
    private VerifierOptions _options;
    private ubyte[] _tracker;
    private uint _depth;
    private size_t _numVectors;

    static Verifier opCall(const(ubyte)[] buffer,
        VerifierOptions options = VerifierOptions.init,
        ubyte[] reuseTracker = null) @nogc nothrow
    {
        Verifier result;
        result._buffer = buffer;
        result._options = options;
        result._tracker = reuseTracker;
        return result;
    }

    bool verifyBuffer() @nogc nothrow
    {
        if (_buffer.length < 3)
            return false;
        if (_tracker !is null)
        {
            if (_tracker.length < _buffer.length)
                return false;
            _tracker[0 .. _buffer.length] = 0;
        }

        BitWidth rootWidth;
        if (!bitWidthFromBytes(_buffer[$ - 1], rootWidth))
            return false;

        FlexBufferType type;
        BitWidth width;
        if (!unpackType(_buffer[$ - 2], type, width))
            return false;

        const payloadEnd = _buffer.length - 2;
        if (payloadEnd < bitWidthBytes(rootWidth))
            return false;

        const data = payloadEnd - bitWidthBytes(rootWidth);
        return verifyRef(data, rootWidth, width, type);
    }

    private bool verifyRef(size_t data, BitWidth parentWidth,
        BitWidth width, FlexBufferType type) @nogc nothrow
    {
        if (type >= FlexBufferType.maxType)
            return false;

        const bytes = bitWidthBytes(width);
        if (isInline(type))
            return true;

        ulong offset;
        if (!readUIntAt(_buffer, data, parentWidth, offset))
            return false;
        if (offset > data)
            return false;
        const target = data - cast(size_t) offset;
        if (target >= _buffer.length)
            return false;
        if (_options.alignmentCheck && (target & (bytes - 1)) != 0)
            return false;

        switch (type)
        {
            case FlexBufferType.indirectInt:
            case FlexBufferType.indirectUInt:
            case FlexBufferType.indirectFloat:
                return verifyFrom(target, bytes);
            case FlexBufferType.key:
                return verifyKey(target);
            case FlexBufferType.map:
                return verifyMap(target, width);
            case FlexBufferType.vector:
            {
                size_t length;
                return verifyUntypedVector(target, width,
                    FlexBufferType.vector, length);
            }
            case FlexBufferType.vectorInt:
                return verifyTypedVector(target, width, FlexBufferType.intValue,
                    size_t.max, FlexBufferType.vectorInt);
            case FlexBufferType.vectorUInt:
                return verifyTypedVector(target, width, FlexBufferType.uintValue,
                    size_t.max, FlexBufferType.vectorUInt);
            case FlexBufferType.vectorFloat:
                return verifyTypedVector(target, width,
                    FlexBufferType.floatValue, size_t.max,
                    FlexBufferType.vectorFloat);
            case FlexBufferType.vectorKey:
                return verifyTypedVector(target, width, FlexBufferType.key,
                    size_t.max, FlexBufferType.vectorKey);
            case FlexBufferType.vectorStringDeprecated:
                return verifyTypedVector(target, width, FlexBufferType.key,
                    size_t.max, FlexBufferType.vectorStringDeprecated);
            case FlexBufferType.vectorBool:
                return verifyTypedVector(target, width,
                    FlexBufferType.boolValue, size_t.max,
                    FlexBufferType.vectorBool);
            case FlexBufferType.blob:
                return verifySized(target, width, FlexBufferType.blob, 1,
                    false);
            case FlexBufferType.string:
                return verifySized(target, width, FlexBufferType.string, 1,
                    true);
            case FlexBufferType.vectorInt2:
            case FlexBufferType.vectorUInt2:
            case FlexBufferType.vectorFloat2:
            case FlexBufferType.vectorInt3:
            case FlexBufferType.vectorUInt3:
            case FlexBufferType.vectorFloat3:
            case FlexBufferType.vectorInt4:
            case FlexBufferType.vectorUInt4:
            case FlexBufferType.vectorFloat4:
            {
                const length = fixedVectorLength(type);
                if (length > (size_t.max / bytes))
                    return false;
                return verifyFrom(target, bytes * length);
            }
            default:
                return false;
        }
    }

    private bool verifyUntypedVector(size_t target, BitWidth width,
        FlexBufferType trackType, out size_t length) @nogc nothrow
    {
        length = 0;
        if (!enterVector())
            return false;
        scope(exit) --_depth;

        const bytes = bitWidthBytes(width);
        if (target < bytes)
            return false;
        const mark = markVerified(target - bytes,
            packedType(trackType, width));
        if (mark == MarkResult.conflict)
            return false;
        if (mark == MarkResult.alreadyVerified)
            return true;

        ulong lengthValue;
        if (!readUIntAt(_buffer, target - bytes, width, lengthValue))
            return false;
        if (lengthValue > _buffer.length)
            return false;
        length = cast(size_t) lengthValue;

        if (length > (_buffer.length - target) / bytes)
            return false;
        const valueBytes = length * bytes;
        if (length > _buffer.length - target - valueBytes)
            return false;

        foreach (i; 0 .. length)
        {
            FlexBufferType elementType;
            BitWidth elementWidth;
            if (!unpackType(_buffer[target + valueBytes + i],
                elementType, elementWidth))
                return false;
            if (!verifyRef(target + i * bytes, width, elementWidth,
                elementType))
                return false;
        }
        return true;
    }

    private bool verifyTypedVector(size_t target, BitWidth width,
        FlexBufferType elementType, size_t expectedLength,
        FlexBufferType trackType) @nogc nothrow
    {
        if (!enterVector())
            return false;
        scope(exit) --_depth;

        const bytes = bitWidthBytes(width);
        if (target < bytes)
            return false;
        const mark = markVerified(target - bytes,
            packedType(trackType, width));
        if (mark == MarkResult.conflict)
            return false;
        if (mark == MarkResult.alreadyVerified)
            return true;

        ulong lengthValue;
        if (!readUIntAt(_buffer, target - bytes, width, lengthValue))
            return false;
        if (expectedLength != size_t.max && lengthValue != expectedLength)
            return false;
        if (lengthValue > _buffer.length)
            return false;
        const length = cast(size_t) lengthValue;

        if (length > (_buffer.length - target) / bytes)
            return false;

        if (elementType == FlexBufferType.key)
        {
            foreach (i; 0 .. length)
            {
                const elementAddress = target + i * bytes;
                ulong offset;
                if (!readUIntAt(_buffer, elementAddress, width, offset))
                    return false;
                if (offset > elementAddress)
                    return false;
                const keyAddress = elementAddress - cast(size_t) offset;
                if (!verifyKey(keyAddress))
                    return false;
            }
        }
        else if (!isInline(elementType))
            return false;

        return true;
    }

    private bool verifySized(size_t target, BitWidth width,
        FlexBufferType trackType, size_t elementSize, bool requireTerminator)
        @nogc nothrow
    {
        if (!enterVector())
            return false;
        scope(exit) --_depth;

        const bytes = bitWidthBytes(width);
        if (target < bytes)
            return false;
        const mark = markVerified(target - bytes,
            packedType(trackType, width));
        if (mark == MarkResult.conflict)
            return false;
        if (mark == MarkResult.alreadyVerified)
            return true;

        ulong lengthValue;
        if (!readUIntAt(_buffer, target - bytes, width, lengthValue))
            return false;
        if (lengthValue > _buffer.length)
            return false;
        const length = cast(size_t) lengthValue;

        if (elementSize != 0 && length > size_t.max / elementSize)
            return false;
        const byteLength = length * elementSize;
        if (!verifyFrom(target, byteLength))
            return false;

        if (requireTerminator)
        {
            if (target + byteLength >= _buffer.length)
                return false;
            if (_buffer[target + byteLength] != 0)
                return false;
        }
        return true;
    }

    private bool verifyMap(size_t target, BitWidth width) @nogc nothrow
    {
        size_t length;
        if (!verifyUntypedVector(target, width, FlexBufferType.map, length))
            return false;
        return verifyKeys(target, width, length);
    }

    private bool verifyKeys(size_t target, BitWidth width, size_t length)
        @nogc nothrow
    {
        const bytes = bitWidthBytes(width);
        if (target < 3 * bytes)
            return false;

        const keysOffsetPosition = target - 3 * bytes;
        ulong keysOffset;
        if (!readUIntAt(_buffer, keysOffsetPosition, width, keysOffset))
            return false;
        if (keysOffset > keysOffsetPosition)
            return false;
        const keysTarget = keysOffsetPosition - cast(size_t) keysOffset;
        if (keysTarget >= _buffer.length)
            return false;

        ulong keyWidthValue;
        if (!readUIntAt(_buffer, target - 2 * bytes, width, keyWidthValue))
            return false;
        BitWidth keysWidth;
        if (!bitWidthFromBytes(cast(size_t) keyWidthValue, keysWidth))
            return false;

        return verifyTypedVector(keysTarget, keysWidth, FlexBufferType.key,
            length, FlexBufferType.vectorKey);
    }

    private bool verifyKey(size_t address) @nogc nothrow
    {
        const mark = markVerified(address,
            packedType(FlexBufferType.key, BitWidth.w8));
        if (mark == MarkResult.conflict)
            return false;
        if (mark == MarkResult.alreadyVerified)
            return true;

        size_t end = address;
        while (end < _buffer.length && _buffer[end] != 0)
            ++end;
        return end < _buffer.length;
    }

    private bool verifyFrom(size_t address, size_t length) const @nogc nothrow
    {
        if (address > _buffer.length)
            return false;
        return length <= _buffer.length - address;
    }

    private bool enterVector() @nogc nothrow
    {
        ++_depth;
        ++_numVectors;
        return _depth <= _options.maxDepth &&
            _numVectors <= _buffer.length;
    }

    private MarkResult markVerified(size_t address, ubyte packed)
        @nogc nothrow
    {
        if (_tracker is null)
            return MarkResult.firstVisit;
        if (address >= _tracker.length)
            return MarkResult.conflict;
        if (_tracker[address] == packed)
            return MarkResult.alreadyVerified;
        if (_tracker[address] != 0)
            return MarkResult.conflict;
        _tracker[address] = packed;
        return MarkResult.firstVisit;
    }
}

bool verifyBuffer(const(ubyte)[] buffer,
    VerifierOptions options = VerifierOptions.init,
    ubyte[] reuseTracker = null) @nogc nothrow
{
    return Verifier(buffer, options, reuseTracker).verifyBuffer();
}
