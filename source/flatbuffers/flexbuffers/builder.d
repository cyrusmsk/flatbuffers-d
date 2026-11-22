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

module flatbuffers.flexbuffers.builder;

import std.algorithm.comparison : cmp;
import std.algorithm.sorting : sort;
import std.traits : isFloatingPoint, isIntegral, isUnsigned;

import flatbuffers.flexbuffers.types;

private union FloatBits
{
    float value;
    uint bits;
}

private union DoubleBits
{
    double value;
    ulong bits;
}

struct BuilderOptions
{
    bool shareKeys = true;
    bool shareStrings = false;
}

struct Builder
{
    private ubyte[] _buffer;
    private Value[] _values;
    private BuilderOptions _options;
    private bool _finished;
    private bool _hasDuplicateKeys;
    private uint _openContainers;
    private size_t[string] _keyPool;
    private size_t[string] _stringPool;

    @disable this(this);

    static Builder opCall()
    {
        return opCall(256, BuilderOptions.init);
    }

    static Builder opCall(size_t initialSize)
    {
        return opCall(initialSize, BuilderOptions.init);
    }

    static Builder opCall(size_t initialSize, BuilderOptions options)
    {
        Builder result;
        result._buffer = new ubyte[initialSize];
        result._buffer.length = 0;
        result._options = options;
        return result;
    }

    void reset()
    {
        _buffer.length = 0;
        _values.length = 0;
        _finished = false;
        _hasDuplicateKeys = false;
        _openContainers = 0;
        _keyPool = null;
        _stringPool = null;
    }

    @property size_t size() const @nogc nothrow
    {
        return _buffer.length;
    }

    const(ubyte)[] finishedBytes() const
    {
        if (!_finished)
            throw new FlexBufferException(
                "FlexBuffers: Finish() must be called before FinishedBytes()");
        return _buffer;
    }

    @property bool hasDuplicateKeys() const @nogc nothrow
    {
        return _hasDuplicateKeys;
    }

    void finish()
    {
        if (_finished)
            throw new FlexBufferException("FlexBuffers: already finished");
        if (_openContainers != 0)
            throw new FlexBufferException(
                "FlexBuffers: cannot finish with open containers");
        if (_values.length != 1)
            throw new FlexBufferException(
                "FlexBuffers: exactly one root value is required");

        const root = _values[0];
        const rootWidth = root.elemWidth(_buffer.length, 0);
        alignBuffer(rootWidth);
        writeAny(root, rootWidth);
        _buffer ~= storedPackedType(root, BitWidth.w8);
        _buffer ~= cast(ubyte) bitWidthBytes(rootWidth);
        _finished = true;
    }

    void nullValue()
    {
        checkNoContainers();
        pushNull();
    }

    void intValue(long value)
    {
        checkNoContainers();
        pushInt(value);
    }

    void uintValue(ulong value)
    {
        checkNoContainers();
        pushUInt(value);
    }

    void floatValue(float value)
    {
        checkNoContainers();
        pushFloat(value);
    }

    void doubleValue(double value)
    {
        checkNoContainers();
        pushDouble(value);
    }

    void boolValue(bool value)
    {
        checkNoContainers();
        pushBool(value);
    }

    size_t stringValue(string value)
    {
        checkNoContainers();
        return pushString(value);
    }

    size_t blobValue(const(ubyte)[] value)
    {
        checkNoContainers();
        return pushBlob(value, widthOfUInt(value.length));
    }

    size_t alignedBlobValue(const(ubyte)[] value, BitWidth alignment)
    {
        checkNoContainers();
        return pushBlob(value, alignment);
    }

    void indirectInt(long value)
    {
        checkNoContainers();
        pushIndirectInt(value);
    }

    void indirectUInt(ulong value)
    {
        checkNoContainers();
        pushIndirectUInt(value);
    }

    void indirectFloat(double value)
    {
        checkNoContainers();
        pushIndirectFloat(value);
    }

    size_t key(string value)
    {
        checkNoContainers();
        return pushKey(value);
    }

    void add(T)(T value)
        if (is(T == bool) || isIntegral!T || isFloatingPoint!T)
    {
        checkNoContainers();
        pushValue(value);
    }

    size_t addString(string value)
    {
        checkNoContainers();
        return pushString(value);
    }

    size_t addBlob(const(ubyte)[] value)
    {
        checkNoContainers();
        return pushBlob(value, widthOfUInt(value.length));
    }

    MapBuilder startMap()
    {
        checkRootStart();
        return beginMap();
    }

    VectorBuilder startVector()
    {
        checkRootStart();
        return beginVector(false, false, 0);
    }

    VectorBuilder startTypedVector()
    {
        checkRootStart();
        return beginVector(true, false, 0);
    }

    VectorBuilder startFixedTypedVector(size_t fixedLength)
    {
        checkRootStart();
        if (fixedLength < 2 || fixedLength > 4)
            throw new FlexBufferException(
                "FlexBuffers: fixed typed vectors must have 2, 3, or 4 elements");
        return beginVector(true, true, fixedLength);
    }

    Value lastValue() const
    {
        checkNoContainers();
        return lastValueInternal();
    }

    void reuseValue(Value value)
    {
        checkNoContainers();
        pushReuse(value);
    }

    void reuseValue(string key, Value value)
    {
        checkNoContainers();
        pushKey(key);
        pushReuse(value);
    }

    void undo()
    {
        checkNoContainers();
        undoInternal();
    }

    struct Value
    {
        private long _int;
        private ulong _uint;
        private double _float;
        private size_t _address;
        private FlexBufferType _type;
        private BitWidth _width;

        private static Value fromNull() @nogc nothrow
        {
            Value result;
            result._type = FlexBufferType.nullValue;
            result._width = BitWidth.w8;
            return result;
        }

        private static Value fromInt(long value) @nogc nothrow
        {
            Value result;
            result._int = value;
            result._type = FlexBufferType.intValue;
            result._width = widthOfInt(value);
            return result;
        }

        private static Value fromUInt(ulong value) @nogc nothrow
        {
            Value result;
            result._uint = value;
            result._type = FlexBufferType.uintValue;
            result._width = widthOfUInt(value);
            return result;
        }

        private static Value fromFloat(float value) @nogc nothrow
        {
            Value result;
            result._float = value;
            result._type = FlexBufferType.floatValue;
            result._width = BitWidth.w32;
            return result;
        }

        private static Value fromDouble(double value) @nogc nothrow
        {
            Value result;
            result._float = value;
            result._type = FlexBufferType.floatValue;
            result._width = widthOfDouble(value);
            return result;
        }

        private static Value fromBool(bool value) @nogc nothrow
        {
            Value result;
            result._uint = value ? 1 : 0;
            result._type = FlexBufferType.boolValue;
            result._width = BitWidth.w8;
            return result;
        }

        private static Value fromReference(size_t address, FlexBufferType type,
            BitWidth width) @nogc nothrow
        {
            Value result;
            result._address = address;
            result._type = type;
            result._width = width;
            return result;
        }

        BitWidth elemWidth(size_t bufferLength, size_t index) const
        {
            if (isInline(_type))
                return _width;

            foreach (bits; 0 .. 4)
            {
                const size_t byteWidth = size_t(1) << bits;
                const size_t padding =
                    (byteWidth - bufferLength % byteWidth) % byteWidth;
                const size_t offsetLocation =
                    bufferLength + padding + index * byteWidth;
                if (offsetLocation < _address)
                    continue;
                const ulong offset = offsetLocation - _address;
                if (widthOfUInt(offset) == cast(BitWidth) bits)
                    return cast(BitWidth) bits;
            }

            throw new FlexBufferException(
                "FlexBuffers: reference offset does not fit any width");
        }
    }

    private MapBuilder beginMap()
    {
        ++_openContainers;
        return MapBuilder(&this, _values.length);
    }

    private VectorBuilder beginVector(bool typed, bool fixed,
        size_t fixedLength)
    {
        ++_openContainers;
        return VectorBuilder(&this, _values.length, typed, fixed, fixedLength);
    }

    private void endMap(size_t start)
    {
        if (_openContainers == 0)
            throw new FlexBufferException(
                "FlexBuffers: EndMap() called without StartMap()");
        --_openContainers;

        if (start > _values.length ||
            ((_values.length - start) & 1) != 0)
            throw new FlexBufferException(
                "FlexBuffers: map keys and values must be paired");

        const map = encodeMap(_values[start .. $]);
        _values.length = start;
        _values ~= map;
    }

    private void endVector(size_t start, bool typed, bool fixed,
        size_t fixedLength)
    {
        if (_openContainers == 0)
            throw new FlexBufferException(
                "FlexBuffers: EndVector() called without StartVector()");
        --_openContainers;

        if (start > _values.length)
            throw new FlexBufferException("FlexBuffers: invalid vector start");

        const length = _values.length - start;
        if (fixed && length != fixedLength)
            throw new FlexBufferException(
                "FlexBuffers: fixed typed vector length mismatch");

        const vector = encodeVector(_values[start .. $], typed, fixed, null,
            fixed ? 0 : 1);
        _values.length = start;
        _values ~= vector;
    }

    private void checkNoContainers() const
    {
        if (_openContainers != 0)
            throw new FlexBufferException(
                "FlexBuffers: use the active map/vector builder");
    }

    private void checkRootStart() const
    {
        if (_openContainers != 0)
            throw new FlexBufferException(
                "FlexBuffers: use the active map/vector builder");
        if (_finished || _values.length != 0)
            throw new FlexBufferException(
                "FlexBuffers: reset the builder before starting a new root");
    }

    private void pushNull()
    {
        _values ~= Value.fromNull();
    }

    private void pushInt(long value)
    {
        _values ~= Value.fromInt(value);
    }

    private void pushUInt(ulong value)
    {
        _values ~= Value.fromUInt(value);
    }

    private void pushIntWithWidth(long value, BitWidth width)
    {
        if (cast(uint) widthOfInt(value) > cast(uint) width)
            throw new FlexBufferException(
                "FlexBuffers: value does not fit the requested width");
        auto stored = Value.fromInt(value);
        stored._width = width;
        _values ~= stored;
    }

    private void pushUIntWithWidth(ulong value, BitWidth width)
    {
        if (cast(uint) widthOfUInt(value) > cast(uint) width)
            throw new FlexBufferException(
                "FlexBuffers: value does not fit the requested width");
        auto stored = Value.fromUInt(value);
        stored._width = width;
        _values ~= stored;
    }

    private void pushFloat64(double value)
    {
        auto stored = Value.fromDouble(value);
        stored._width = BitWidth.w64;
        _values ~= stored;
    }

    private void pushFloat(float value)
    {
        _values ~= Value.fromFloat(value);
    }

    private void pushDouble(double value)
    {
        _values ~= Value.fromDouble(value);
    }

    private void pushBool(bool value)
    {
        _values ~= Value.fromBool(value);
    }

    private void pushValue(T)(T value)
    {
        static if (is(T == bool))
            pushBool(value);
        else static if (isFloatingPoint!T)
        {
            static if (is(T == float))
                pushFloat(value);
            else
                pushDouble(value);
        }
        else static if (isUnsigned!T)
            pushUInt(cast(ulong) value);
        else
            pushInt(cast(long) value);
    }

    private void pushReuse(Value value)
    {
        _values ~= value;
    }

    private Value lastValueInternal() const
    {
        if (_values.length == 0)
            throw new FlexBufferException(
                "FlexBuffers: no value has been pushed");
        return _values[$ - 1];
    }

    private void undoInternal()
    {
        if (_values.length == 0)
            throw new FlexBufferException(
                "FlexBuffers: no value has been pushed");
        _values.length -= 1;
    }

    private size_t pushKey(string value)
    {
        foreach (c; value)
            if (c == '\0')
                throw new FlexBufferException(
                    "FlexBuffers: keys must not contain NUL bytes");

        if (_options.shareKeys)
        {
            if (auto found = value in _keyPool)
            {
                _values ~= Value.fromReference(*found, FlexBufferType.key,
                    BitWidth.w8);
                return *found;
            }
        }

        const address = _buffer.length;
        _buffer ~= cast(const(ubyte)[]) value;
        _buffer ~= cast(ubyte) 0;
        if (_options.shareKeys)
            _keyPool[value] = address;

        _values ~= Value.fromReference(address, FlexBufferType.key,
            BitWidth.w8);
        return address;
    }

    private size_t pushString(string value)
    {
        const width = widthOfUInt(value.length);
        const startPosition = _buffer.length;
        alignBuffer(width);
        const lengthPosition = _buffer.length;
        writeUInt(value.length, bitWidthBytes(width));

        const address = _buffer.length;
        _buffer ~= cast(const(ubyte)[]) value;
        _buffer ~= cast(ubyte) 0;

        if (_options.shareStrings)
        {
            if (auto found = value in _stringPool)
            {
                _buffer.length = startPosition;
                _values ~= Value.fromReference(*found, FlexBufferType.string,
                    width);
                return *found;
            }
            _stringPool[value] = address;
        }

        _values ~= Value.fromReference(address, FlexBufferType.string, width);
        return address;
    }

    private size_t pushBlob(const(ubyte)[] value, BitWidth alignment)
    {
        const width = maxWidth(alignment, widthOfUInt(value.length));
        alignBuffer(width);
        writeUInt(value.length, bitWidthBytes(width));

        const address = _buffer.length;
        _buffer ~= value;
        _values ~= Value.fromReference(address, FlexBufferType.blob, width);
        return address;
    }

    private void pushIndirectInt(long value)
    {
        const width = widthOfInt(value);
        alignBuffer(width);
        const address = _buffer.length;
        writeInt(value, bitWidthBytes(width));
        _values ~= Value.fromReference(address, FlexBufferType.indirectInt,
            width);
    }

    private void pushIndirectUInt(ulong value)
    {
        const width = widthOfUInt(value);
        alignBuffer(width);
        const address = _buffer.length;
        writeUInt(value, bitWidthBytes(width));
        _values ~= Value.fromReference(address, FlexBufferType.indirectUInt,
            width);
    }

    private void pushIndirectFloat(double value)
    {
        const width = widthOfDouble(value);
        alignBuffer(width);
        const address = _buffer.length;
        writeFloat(value, bitWidthBytes(width));
        _values ~= Value.fromReference(address, FlexBufferType.indirectFloat,
            width);
    }

    private Value encodeMap(const(Value)[] interleaved)
    {
        struct Entry
        {
            Value key;
            Value value;
        }

        Entry[] entries;
        entries.length = interleaved.length / 2;
        foreach (i; 0 .. entries.length)
            entries[i] = Entry(interleaved[2 * i], interleaved[2 * i + 1]);

        sort!((a, b) => cmp(keyBytes(a.key), keyBytes(b.key)) < 0)(entries);
        foreach (i; 1 .. entries.length)
            if (cmp(keyBytes(entries[i - 1].key),
                keyBytes(entries[i].key)) == 0)
                _hasDuplicateKeys = true;

        Value[] keys;
        Value[] values;
        keys.length = entries.length;
        values.length = entries.length;
        foreach (i, ref entry; entries)
        {
            keys[i] = entry.key;
            values[i] = entry.value;
        }

        const keyVector = encodeVector(keys, true, false, null, 1);
        return encodeVector(values, false, false, &keyVector, 3);
    }

    private Value encodeVector(const(Value)[] elements, bool typed,
        bool fixed, const(Value)* keys, size_t prefixElements)
    {
        if (fixed && !typed)
            throw new FlexBufferException(
                "FlexBuffers: fixed vectors must be typed");

        BitWidth width = widthOfUInt(elements.length);
        if (elements.length == 0 && fixed)
            throw new FlexBufferException(
                "FlexBuffers: fixed typed vectors cannot be empty");

        if (keys !is null)
            width = maxWidth(width, keys.elemWidth(_buffer.length, 0));
        foreach (i, element; elements)
            width = maxWidth(width,
                element.elemWidth(_buffer.length, i + prefixElements));

        FlexBufferType elementType = FlexBufferType.key;
        if (elements.length != 0)
            elementType = elements[0]._type;

        FlexBufferType vectorType;
        if (keys !is null)
            vectorType = FlexBufferType.map;
        else if (typed)
        {
            if (elementType == FlexBufferType.string)
                throw new FlexBufferException(
                    "FlexBuffers: deprecated string vectors are not writable");
            if (!toTypedVectorType(elementType,
                fixed ? elements.length : 0, vectorType))
                throw new FlexBufferException(
                    "FlexBuffers: invalid typed vector element type");
            foreach (element; elements)
                if (element._type != elementType)
                    throw new FlexBufferException(
                        "FlexBuffers: typed vector elements must share a type");
        }
        else
            vectorType = FlexBufferType.vector;

        alignBuffer(width);
        const widthBytes = bitWidthBytes(width);
        if (keys !is null)
        {
            writeAny(*keys, width);
            writeUInt(bitWidthBytes(keys._width), widthBytes);
        }
        if (!fixed)
            writeUInt(elements.length, widthBytes);

        const address = _buffer.length;
        foreach (element; elements)
            writeAny(element, width);
        if (!typed)
            foreach (element; elements)
                _buffer ~= storedPackedType(element, width);

        return Value.fromReference(address, vectorType, width);
    }

    private void writeAny(const Value value, BitWidth width)
    {
        const bytes = bitWidthBytes(width);
        if (!isInline(value._type))
        {
            if (value._address > _buffer.length)
                throw new FlexBufferException(
                    "FlexBuffers: reference points past the buffer");
            writeUInt(_buffer.length - value._address, bytes);
            return;
        }

        switch (value._type)
        {
            case FlexBufferType.nullValue:
                writeUInt(0, bytes);
                break;
            case FlexBufferType.intValue:
                writeInt(value._int, bytes);
                break;
            case FlexBufferType.uintValue:
            case FlexBufferType.boolValue:
                writeUInt(value._uint, bytes);
                break;
            case FlexBufferType.floatValue:
                writeFloat(value._float, bytes);
                break;
            default:
                throw new FlexBufferException(
                    "FlexBuffers: invalid inline value type");
        }
    }

    private void alignBuffer(BitWidth width)
    {
        const byteWidth = bitWidthBytes(width);
        while (_buffer.length % byteWidth != 0)
            _buffer ~= cast(ubyte) 0;
    }

    private void writeUInt(ulong value, size_t bytes)
    {
        foreach (i; 0 .. bytes)
            _buffer ~= cast(ubyte) (value >> (8 * i));
    }

    private void writeInt(long value, size_t bytes)
    {
        writeUInt(cast(ulong) value, bytes);
    }

    private void writeFloat(double value, size_t bytes)
    {
        if (bytes == 4)
        {
            FloatBits bits;
            bits.value = cast(float) value;
            writeUInt(bits.bits, 4);
        }
        else if (bytes == 8)
        {
            DoubleBits bits;
            bits.value = value;
            writeUInt(bits.bits, 8);
        }
        else
            throw new FlexBufferException(
                "FlexBuffers: floats must use 4 or 8 bytes");
    }

    private const(ubyte)[] keyBytes(const Value value) const
    {
        if (value._address >= _buffer.length)
            return null;
        size_t end = value._address;
        while (end < _buffer.length && _buffer[end] != 0)
            ++end;
        return _buffer[value._address .. end];
    }

    private static BitWidth widthOfInt(long value) @nogc nothrow
    {
        if (value >= byte.min && value <= byte.max)
            return BitWidth.w8;
        if (value >= short.min && value <= short.max)
            return BitWidth.w16;
        if (value >= int.min && value <= int.max)
            return BitWidth.w32;
        return BitWidth.w64;
    }

    private static BitWidth widthOfUInt(ulong value) @nogc nothrow
    {
        if (value <= ubyte.max)
            return BitWidth.w8;
        if (value <= ushort.max)
            return BitWidth.w16;
        if (value <= uint.max)
            return BitWidth.w32;
        return BitWidth.w64;
    }

    private static BitWidth widthOfDouble(double value) @nogc nothrow
    {
        if (cast(double) cast(float) value == value)
            return BitWidth.w32;
        return BitWidth.w64;
    }

    private static BitWidth maxWidth(BitWidth a, BitWidth b) @nogc nothrow
    {
        return cast(uint) a >= cast(uint) b ? a : b;
    }

    private static BitWidth storedWidth(const Value value,
        BitWidth parentWidth) @nogc nothrow
    {
        if (isInline(value._type))
            return maxWidth(value._width, parentWidth);
        return value._width;
    }

    private static ubyte storedPackedType(const Value value,
        BitWidth parentWidth) @nogc nothrow
    {
        return packedType(value._type, storedWidth(value, parentWidth));
    }
}

struct MapBuilder
{
    private Builder* _builder;
    private size_t _start;
    private bool _active;

    @disable this(this);

    private this(Builder* builder, size_t start) @nogc nothrow
    {
        _builder = builder;
        _start = start;
        _active = true;
    }

    void put(T)(string key, T value)
        if (is(T == bool) || isIntegral!T || isFloatingPoint!T)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushValue(value);
    }

    void putNull(string key)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushNull();
    }

    void putString(string key, string value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushString(value);
    }

    void putBlob(string key, const(ubyte)[] value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushBlob(value, _builder.widthOfUInt(value.length));
    }

    void putAlignedBlob(string key, const(ubyte)[] value, BitWidth alignment)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushBlob(value, alignment);
    }

    void putIndirectInt(string key, long value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushIndirectInt(value);
    }

    void putIndirectUInt(string key, ulong value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushIndirectUInt(value);
    }

    void putIndirectFloat(string key, double value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushIndirectFloat(value);
    }

    void putKey(string key, string value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushKey(value);
    }

    Builder.Value lastValue() const
    {
        checkActive();
        return _builder.lastValueInternal();
    }

    void reuseValue(Builder.Value value)
    {
        checkActive();
        _builder.pushReuse(value);
    }

    void reuseValue(string key, Builder.Value value)
    {
        checkActive();
        _builder.pushKey(key);
        _builder.pushReuse(value);
    }

    void undo()
    {
        checkActive();
        _builder.undoInternal();
    }

    MapBuilder startMap(string key)
    {
        checkActive();
        _builder.pushKey(key);
        return _builder.beginMap();
    }

    VectorBuilder startVector(string key)
    {
        checkActive();
        _builder.pushKey(key);
        return _builder.beginVector(false, false, 0);
    }

    VectorBuilder startTypedVector(string key)
    {
        checkActive();
        _builder.pushKey(key);
        return _builder.beginVector(true, false, 0);
    }

    VectorBuilder startFixedTypedVector(string key, size_t fixedLength)
    {
        checkActive();
        if (fixedLength < 2 || fixedLength > 4)
            throw new FlexBufferException(
                "FlexBuffers: fixed typed vectors must have 2, 3, or 4 elements");
        _builder.pushKey(key);
        return _builder.beginVector(true, true, fixedLength);
    }

    void end()
    {
        checkActive();
        _active = false;
        _builder.endMap(_start);
    }

    private void checkActive() const
    {
        if (!_active)
            throw new FlexBufferException(
                "FlexBuffers: map builder is already finished");
    }
}

struct VectorBuilder
{
    private Builder* _builder;
    private size_t _start;
    private bool _typed;
    private bool _fixed;
    private size_t _fixedLength;
    private bool _active;

    @disable this(this);

    private this(Builder* builder, size_t start, bool typed, bool fixed,
        size_t fixedLength) @nogc nothrow
    {
        _builder = builder;
        _start = start;
        _typed = typed;
        _fixed = fixed;
        _fixedLength = fixedLength;
        _active = true;
    }

    void push(T)(T value)
        if (is(T == bool) || isIntegral!T || isFloatingPoint!T)
    {
        checkActive();
        _builder.pushValue(value);
    }

    void pushInt8(long value)
    {
        checkActive();
        _builder.pushIntWithWidth(value, BitWidth.w8);
    }

    void pushInt16(long value)
    {
        checkActive();
        _builder.pushIntWithWidth(value, BitWidth.w16);
    }

    void pushInt32(long value)
    {
        checkActive();
        _builder.pushIntWithWidth(value, BitWidth.w32);
    }

    void pushInt64(long value)
    {
        checkActive();
        _builder.pushIntWithWidth(value, BitWidth.w64);
    }

    void pushUInt8(ulong value)
    {
        checkActive();
        _builder.pushUIntWithWidth(value, BitWidth.w8);
    }

    void pushUInt16(ulong value)
    {
        checkActive();
        _builder.pushUIntWithWidth(value, BitWidth.w16);
    }

    void pushUInt32(ulong value)
    {
        checkActive();
        _builder.pushUIntWithWidth(value, BitWidth.w32);
    }

    void pushUInt64(ulong value)
    {
        checkActive();
        _builder.pushUIntWithWidth(value, BitWidth.w64);
    }

    void pushFloat32(float value)
    {
        checkActive();
        _builder.pushFloat(value);
    }

    void pushFloat64(double value)
    {
        checkActive();
        _builder.pushFloat64(value);
    }

    void pushNull()
    {
        checkActive();
        _builder.pushNull();
    }

    void pushString(string value)
    {
        checkActive();
        _builder.pushString(value);
    }

    void pushBlob(const(ubyte)[] value)
    {
        checkActive();
        _builder.pushBlob(value, _builder.widthOfUInt(value.length));
    }

    void pushAlignedBlob(const(ubyte)[] value, BitWidth alignment)
    {
        checkActive();
        _builder.pushBlob(value, alignment);
    }

    void pushIndirectInt(long value)
    {
        checkActive();
        _builder.pushIndirectInt(value);
    }

    void pushIndirectUInt(ulong value)
    {
        checkActive();
        _builder.pushIndirectUInt(value);
    }

    void pushIndirectFloat(double value)
    {
        checkActive();
        _builder.pushIndirectFloat(value);
    }

    void pushKey(string value)
    {
        checkActive();
        _builder.pushKey(value);
    }

    Builder.Value lastValue() const
    {
        checkActive();
        return _builder.lastValueInternal();
    }

    void reuseValue(Builder.Value value)
    {
        checkActive();
        _builder.pushReuse(value);
    }

    void undo()
    {
        checkActive();
        _builder.undoInternal();
    }

    MapBuilder startMap()
    {
        checkActive();
        return _builder.beginMap();
    }

    VectorBuilder startVector()
    {
        checkActive();
        return _builder.beginVector(false, false, 0);
    }

    VectorBuilder startTypedVector()
    {
        checkActive();
        return _builder.beginVector(true, false, 0);
    }

    VectorBuilder startFixedTypedVector(size_t fixedLength)
    {
        checkActive();
        if (fixedLength < 2 || fixedLength > 4)
            throw new FlexBufferException(
                "FlexBuffers: fixed typed vectors must have 2, 3, or 4 elements");
        return _builder.beginVector(true, true, fixedLength);
    }

    void end()
    {
        checkActive();
        _active = false;
        _builder.endVector(_start, _typed, _fixed, _fixedLength);
    }

    private void checkActive() const
    {
        if (!_active)
            throw new FlexBufferException(
                "FlexBuffers: vector builder is already finished");
    }
}
