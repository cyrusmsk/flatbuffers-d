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

module flatbuffers.flexbuffers.reader;

import std.typecons : Nullable;

import flatbuffers.base : bytesToString;
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

private long readIntAt(const(ubyte)[] buffer, size_t position,
    BitWidth width) @nogc nothrow
{
    ulong bits;
    if (!readUIntAt(buffer, position, width, bits))
        return 0;

    long value = cast(long) bits;
    const bytes = bitWidthBytes(width);
    if (bytes < 8)
    {
        const shift = cast(uint) (64 - bytes * 8);
        value = (value << shift) >> shift;
    }
    return value;
}

private double readFloatAt(const(ubyte)[] buffer, size_t position,
    BitWidth width) @nogc nothrow
{
    if (width == BitWidth.w32)
    {
        ulong bits;
        if (!readUIntAt(buffer, position, width, bits))
            return 0.0;
        FloatBits value;
        value.bits = cast(uint) bits;
        return value.value;
    }

    ulong bits;
    if (!readUIntAt(buffer, position, width, bits))
        return 0.0;
    DoubleBits value;
    value.bits = bits;
    return value.value;
}

struct Blob
{
    const(ubyte)[] data;

    @property size_t length() const @nogc nothrow
    {
        return data.length;
    }
}

struct Reference
{
    private const(ubyte)[] _buffer;
    private size_t _data;
    private BitWidth _parentWidth;
    private BitWidth _width;
    private FlexBufferType _type;
    private bool _valid;

    private this(const(ubyte)[] buffer, size_t data, BitWidth parentWidth,
        BitWidth width, FlexBufferType type) @nogc nothrow
    {
        _buffer = buffer;
        _data = data;
        _parentWidth = parentWidth;
        _width = width;
        _type = type;
        _valid = true;
    }

    @property bool isValid() const @nogc nothrow
    {
        return _valid;
    }

    @property FlexBufferType type() const @nogc nothrow
    {
        return _type;
    }

    @property BitWidth bitWidth() const @nogc nothrow
    {
        return _width;
    }

    bool isNull() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.nullValue;
    }

    bool isBool() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.boolValue;
    }

    bool isInt() const @nogc nothrow
    {
        return _valid && (_type == FlexBufferType.intValue ||
            _type == FlexBufferType.indirectInt);
    }

    bool isUInt() const @nogc nothrow
    {
        return _valid && (_type == FlexBufferType.uintValue ||
            _type == FlexBufferType.indirectUInt);
    }

    bool isIntOrUint() const @nogc nothrow
    {
        return isInt() || isUInt();
    }

    bool isFloat() const @nogc nothrow
    {
        return _valid && (_type == FlexBufferType.floatValue ||
            _type == FlexBufferType.indirectFloat);
    }

    bool isNumeric() const @nogc nothrow
    {
        return isIntOrUint() || isFloat();
    }

    bool isString() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.string;
    }

    bool isKey() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.key;
    }

    bool isBlob() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.blob;
    }

    bool isMap() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.map;
    }

    bool isVector() const @nogc nothrow
    {
        return _valid && (_type == FlexBufferType.vector || isMap());
    }

    bool isUntypedVector() const @nogc nothrow
    {
        return _valid && _type == FlexBufferType.vector;
    }

    bool isTypedVector() const @nogc nothrow
    {
        return _valid && flatbuffers.flexbuffers.types.isTypedVector(_type);
    }

    bool isFixedTypedVector() const @nogc nothrow
    {
        return _valid &&
            flatbuffers.flexbuffers.types.isFixedTypedVector(_type);
    }

    bool isAnyVector() const @nogc nothrow
    {
        return isVector() || isTypedVector() || isFixedTypedVector();
    }

    size_t length() const @nogc nothrow
    {
        size_t result;
        return lengthValue(result) ? result : 0;
    }

    private bool lengthValue(out size_t result) const @nogc nothrow
    {
        result = 0;
        if (!_valid)
            return false;
        if (isFixedTypedVector())
        {
            result = fixedVectorLength(_type);
            return true;
        }
        if (!hasLengthSlot(_type))
            return false;

        const address = indirect();
        if (address == size_t.max ||
            address < bitWidthBytes(_width))
            return false;

        ulong value;
        if (!readUIntAt(_buffer, address - bitWidthBytes(_width),
            _width, value))
            return false;
        if (value > _buffer.length)
            return false;
        result = cast(size_t) value;
        return true;
    }

    Nullable!long getInt64() const @nogc nothrow
    {
        if (!isInt())
            return Nullable!long.init;

        size_t address;
        BitWidth width;
        if (!numericAddress(address, width))
            return Nullable!long.init;
        return Nullable!long(readIntAt(_buffer, address, width));
    }

    Nullable!ulong getUInt64() const @nogc nothrow
    {
        if (!isUInt())
            return Nullable!ulong.init;

        size_t address;
        BitWidth width;
        if (!numericAddress(address, width))
            return Nullable!ulong.init;
        ulong result;
        if (!readUIntAt(_buffer, address, width, result))
            return Nullable!ulong.init;
        return Nullable!ulong(result);
    }

    Nullable!double getDouble() const @nogc nothrow
    {
        if (!isFloat())
            return Nullable!double.init;

        size_t address;
        BitWidth width;
        if (!numericAddress(address, width))
            return Nullable!double.init;
        return Nullable!double(readFloatAt(_buffer, address, width));
    }

    Nullable!bool getBool() const @nogc nothrow
    {
        if (!isBool())
            return Nullable!bool.init;

        ulong bits;
        if (!readUIntAt(_buffer, _data, _parentWidth, bits))
            return Nullable!bool.init;
        return Nullable!bool(bits != 0);
    }

    Nullable!string getString() const @nogc nothrow
    {
        if (!isString())
            return Nullable!string.init;
        const value = asString();
        if (value is null)
            return Nullable!string.init;
        return Nullable!string(value);
    }

    Nullable!string getKey() const @nogc nothrow
    {
        if (!isKey())
            return Nullable!string.init;
        const value = asKey();
        if (value is null)
            return Nullable!string.init;
        return Nullable!string(value);
    }

    Nullable!Blob getBlob() const @nogc nothrow
    {
        if (!isBlob())
            return Nullable!Blob.init;
        const value = asBlob();
        if (value.data is null)
            return Nullable!Blob.init;
        return Nullable!Blob(value);
    }

    long asInt64() const @nogc nothrow
    {
        if (!_valid)
            return 0;

        size_t address;
        BitWidth width;
        switch (_type)
        {
            case FlexBufferType.intValue:
            case FlexBufferType.indirectInt:
                if (!numericAddress(address, width))
                    return 0;
                return readIntAt(_buffer, address, width);
            case FlexBufferType.uintValue:
            case FlexBufferType.indirectUInt:
                if (!numericAddress(address, width))
                    return 0;
                ulong result;
                if (!readUIntAt(_buffer, address, width, result))
                    return 0;
                return cast(long) result;
            case FlexBufferType.floatValue:
            case FlexBufferType.indirectFloat:
                if (!numericAddress(address, width))
                    return 0;
                return cast(long) readFloatAt(_buffer, address, width);
            case FlexBufferType.boolValue:
                return getBool().get ? 1 : 0;
            case FlexBufferType.nullValue:
                return 0;
            default:
                if (isVector() || isTypedVector() || isFixedTypedVector())
                    return cast(long) length();
                return 0;
        }
    }

    ulong asUInt64() const @nogc nothrow
    {
        if (!_valid)
            return 0;

        size_t address;
        BitWidth width;
        switch (_type)
        {
            case FlexBufferType.intValue:
            case FlexBufferType.indirectInt:
                if (!numericAddress(address, width))
                    return 0;
                return cast(ulong) readIntAt(_buffer, address, width);
            case FlexBufferType.uintValue:
            case FlexBufferType.indirectUInt:
                if (!numericAddress(address, width))
                    return 0;
                ulong result;
                if (!readUIntAt(_buffer, address, width, result))
                    return 0;
                return result;
            case FlexBufferType.floatValue:
            case FlexBufferType.indirectFloat:
                if (!numericAddress(address, width))
                    return 0;
                return cast(ulong) readFloatAt(_buffer, address, width);
            case FlexBufferType.boolValue:
                return getBool().get ? 1 : 0;
            case FlexBufferType.nullValue:
                return 0;
            default:
                if (isVector() || isTypedVector() || isFixedTypedVector())
                    return length();
                return 0;
        }
    }

    double asDouble() const @nogc nothrow
    {
        if (!_valid)
            return 0.0;

        size_t address;
        BitWidth width;
        switch (_type)
        {
            case FlexBufferType.intValue:
            case FlexBufferType.indirectInt:
                if (!numericAddress(address, width))
                    return 0.0;
                return cast(double) readIntAt(_buffer, address, width);
            case FlexBufferType.uintValue:
            case FlexBufferType.indirectUInt:
                if (!numericAddress(address, width))
                    return 0.0;
                ulong result;
                if (!readUIntAt(_buffer, address, width, result))
                    return 0.0;
                return cast(double) result;
            case FlexBufferType.floatValue:
            case FlexBufferType.indirectFloat:
                if (!numericAddress(address, width))
                    return 0.0;
                return readFloatAt(_buffer, address, width);
            case FlexBufferType.boolValue:
                return getBool().get ? 1.0 : 0.0;
            case FlexBufferType.nullValue:
                return 0.0;
            default:
                if (isVector() || isTypedVector() || isFixedTypedVector())
                    return cast(double) length();
                return 0.0;
        }
    }

    float asFloat() const @nogc nothrow
    {
        return cast(float) asDouble();
    }

    bool asBool() const @nogc nothrow
    {
        if (!_valid)
            return false;

        switch (_type)
        {
            case FlexBufferType.boolValue:
                return getBool().get;
            case FlexBufferType.intValue:
            case FlexBufferType.indirectInt:
                return asInt64() != 0;
            case FlexBufferType.uintValue:
            case FlexBufferType.indirectUInt:
                return asUInt64() != 0;
            case FlexBufferType.floatValue:
            case FlexBufferType.indirectFloat:
                return asDouble() != 0.0;
            case FlexBufferType.string:
            case FlexBufferType.key:
                return asString().length != 0;
            case FlexBufferType.blob:
                return length() != 0;
            case FlexBufferType.nullValue:
                return false;
            default:
                return isVector() || isTypedVector() ||
                    isFixedTypedVector() ? length() != 0 : false;
        }
    }

    string asString() const @nogc nothrow
    {
        if (!_valid)
            return null;

        if (_type == FlexBufferType.string)
        {
            size_t size;
            if (!lengthValue(size))
                return null;
            const address = indirect();
            if (address == size_t.max ||
                address > _buffer.length ||
                size >= _buffer.length - address)
                return null;
            if (_buffer[address + size] != 0)
                return null;
            return bytesToString(_buffer[address .. address + size]);
        }

        if (_type == FlexBufferType.key)
        {
            size_t size;
            if (!keyLengthValue(size))
                return null;
            const address = indirect();
            if (address == size_t.max ||
                address > _buffer.length ||
                size > _buffer.length - address)
                return null;
            return bytesToString(_buffer[address .. address + size]);
        }

        return null;
    }

    string asKey() const @nogc nothrow
    {
        if (!_valid)
            return null;
        if (_type == FlexBufferType.key)
            return asString();
        if (_type == FlexBufferType.string)
            return asString();
        return null;
    }

    Blob asBlob() const @nogc nothrow
    {
        if (!_valid)
            return Blob(null);
        if (_type != FlexBufferType.blob &&
            _type != FlexBufferType.string)
            return Blob(null);

        size_t size;
        if (!lengthValue(size))
            return Blob(null);
        const address = indirect();
        if (address == size_t.max ||
            address > _buffer.length ||
            size > _buffer.length - address)
            return Blob(null);
        return Blob(_buffer[address .. address + size]);
    }

    private size_t keyLength() const @nogc nothrow
    {
        size_t result;
        return keyLengthValue(result) ? result : 0;
    }

    private bool keyLengthValue(out size_t result) const @nogc nothrow
    {
        result = 0;
        if (!_valid || _type != FlexBufferType.key)
            return false;

        const address = indirect();
        if (address == size_t.max || address >= _buffer.length)
            return false;

        size_t end = address;
        while (end < _buffer.length && _buffer[end] != 0)
            ++end;
        if (end == _buffer.length)
            return false;
        result = end - address;
        return true;
    }

    private bool numericAddress(out size_t address, out BitWidth width)
        const @nogc nothrow
    {
        if (_type == FlexBufferType.indirectInt ||
            _type == FlexBufferType.indirectUInt ||
            _type == FlexBufferType.indirectFloat)
        {
            address = indirect();
            width = _width;
            return address != size_t.max;
        }

        address = _data;
        width = _parentWidth;
        return address < _buffer.length;
    }

    private size_t indirect() const @nogc nothrow
    {
        if (!_valid || isInline(_type))
            return _data;

        ulong offset;
        if (!readUIntAt(_buffer, _data, _parentWidth, offset))
            return size_t.max;
        if (offset > _data)
            return size_t.max;

        const address = _data - cast(size_t) offset;
        if (address >= _buffer.length)
            return size_t.max;
        return address;
    }
    Map asMap() const @nogc nothrow
    {
        if (!isMap())
            return Map.init;

        const address = indirect();
        if (address == size_t.max)
            return Map.init;

        const widthBytes = bitWidthBytes(_width);
        if (address < 3 * widthBytes)
            return Map.init;

        const keysOffsetPosition = address - 3 * widthBytes;
        ulong keysOffset;
        if (!readUIntAt(_buffer, keysOffsetPosition, _width, keysOffset))
            return Map.init;
        if (keysOffset > keysOffsetPosition)
            return Map.init;

        const keysData = keysOffsetPosition - cast(size_t) keysOffset;
        if (keysData >= _buffer.length)
            return Map.init;

        ulong keyWidthValue;
        if (!readUIntAt(_buffer, address - 2 * widthBytes, _width,
            keyWidthValue))
            return Map.init;
        BitWidth keysWidth;
        if (!bitWidthFromBytes(cast(size_t) keyWidthValue, keysWidth))
            return Map.init;

        ulong lengthValue;
        if (!readUIntAt(_buffer, address - widthBytes, _width, lengthValue))
            return Map.init;
        if (lengthValue > _buffer.length)
            return Map.init;
        const length = cast(size_t) lengthValue;

        const keysWidthBytes = bitWidthBytes(keysWidth);
        if (keysData < keysWidthBytes)
            return Map.init;
        ulong keyLength;
        if (!readUIntAt(_buffer, keysData - keysWidthBytes, keysWidth,
            keyLength))
            return Map.init;
        if (keyLength != length)
            return Map.init;

        if (length != 0)
        {
            if (length > (_buffer.length - keysData) / keysWidthBytes)
                return Map.init;
            if (length > (_buffer.length - address) / widthBytes)
                return Map.init;
            const valueBytes = length * widthBytes;
            if (length > _buffer.length - address - valueBytes)
                return Map.init;
        }

        return Map(_buffer, address, _width, keysData, keysWidth, length);
    }

    Vector asVector() const @nogc nothrow
    {
        if (!_valid)
            return Vector.init;

        if (isMap())
            return asMap().values();

        if (!isVector() && !isTypedVector() && !isFixedTypedVector())
            return Vector.init;

        const address = indirect();
        if (address == size_t.max)
            return Vector.init;

        const widthBytes = bitWidthBytes(_width);
        if (isUntypedVector())
        {
            size_t length;
            if (!lengthValue(length))
                return Vector.init;
            if (length > (_buffer.length - address) / widthBytes)
                return Vector.init;
            const valueBytes = length * widthBytes;
            if (length > _buffer.length - address - valueBytes)
                return Vector.init;
            return Vector(_buffer, address, _width, length,
                FlexBufferType.vector, FlexBufferType.nullValue, false);
        }

        FlexBufferType elementType;
        const fixed = isFixedTypedVector();
        if (fixed)
        {
            size_t fixedLength;
            if (!toFixedTypedVectorElementType(_type, elementType,
                fixedLength))
                return Vector.init;
        }
        else
        {
            if (!typedVectorElementType(_type, elementType))
                return Vector.init;
            if (_type == FlexBufferType.vectorStringDeprecated)
                elementType = FlexBufferType.key;
        }

        size_t length;
        if (fixed)
            length = fixedVectorLength(_type);
        else if (!lengthValue(length))
            return Vector.init;
        if (length > (_buffer.length - address) / widthBytes)
            return Vector.init;

        return Vector(_buffer, address, _width, length, _type, elementType,
            fixed);
    }

    Nullable!Map getMap() const @nogc nothrow
    {
        if (!isMap())
            return Nullable!Map.init;
        const value = asMap();
        if (!value.isValid)
            return Nullable!Map.init;
        return Nullable!Map(value);
    }

    Nullable!Vector getVector() const @nogc nothrow
    {
        if (!isVector() && !isTypedVector() && !isFixedTypedVector())
            return Nullable!Vector.init;
        const value = asVector();
        if (!value.isValid)
            return Nullable!Vector.init;
        return Nullable!Vector(value);
    }

    Nullable!Vector getTypedVector() const @nogc nothrow
    {
        if (!isTypedVector())
            return Nullable!Vector.init;
        const value = asVector();
        if (!value.isValid)
            return Nullable!Vector.init;
        return Nullable!Vector(value);
    }

    Nullable!Vector getFixedTypedVector() const @nogc nothrow
    {
        if (!isFixedTypedVector())
            return Nullable!Vector.init;
        const value = asVector();
        if (!value.isValid)
            return Nullable!Vector.init;
        return Nullable!Vector(value);
    }
}

struct Map
{
    private const(ubyte)[] _buffer;
    private size_t _data;
    private BitWidth _width;
    private size_t _keysData;
    private BitWidth _keysWidth;
    private size_t _length;
    private bool _valid;

    private this(const(ubyte)[] buffer, size_t data, BitWidth width,
        size_t keysData, BitWidth keysWidth, size_t length) @nogc nothrow
    {
        _buffer = buffer;
        _data = data;
        _width = width;
        _keysData = keysData;
        _keysWidth = keysWidth;
        _length = length;
        _valid = true;
    }

    @property bool isValid() const @nogc nothrow
    {
        return _valid;
    }

    @property size_t length() const @nogc nothrow
    {
        return _valid ? _length : 0;
    }

    bool contains(string key) const @nogc nothrow
    {
        return indexOf(key) != size_t.max;
    }

    Reference opIndex(size_t index) const @nogc nothrow
    {
        return valueAt(index);
    }

    Reference opIndex(string key) const @nogc nothrow
    {
        const index = indexOf(key);
        return index == size_t.max ? Reference.init : valueAt(index);
    }

    Reference valueAt(size_t index) const @nogc nothrow
    {
        if (!_valid || index >= _length)
            return Reference.init;

        const widthBytes = bitWidthBytes(_width);
        const valueAddress = _data + index * widthBytes;
        const typeAddress = _data + _length * widthBytes + index;
        if (valueAddress > _buffer.length ||
            widthBytes > _buffer.length - valueAddress ||
            typeAddress >= _buffer.length)
            return Reference.init;

        FlexBufferType type;
        BitWidth width;
        if (!unpackType(_buffer[typeAddress], type, width))
            return Reference.init;
        return Reference(_buffer, valueAddress, _width, width, type);
    }

    string keyAt(size_t index) const @nogc nothrow
    {
        if (!_valid || index >= _length)
            return null;

        const keysWidthBytes = bitWidthBytes(_keysWidth);
        const offsetAddress = _keysData + index * keysWidthBytes;
        if (offsetAddress > _buffer.length ||
            keysWidthBytes > _buffer.length - offsetAddress)
            return null;

        ulong offset;
        if (!readUIntAt(_buffer, offsetAddress, _keysWidth, offset))
            return null;
        if (offset > offsetAddress)
            return null;

        const keyAddress = offsetAddress - cast(size_t) offset;
        if (keyAddress >= _buffer.length)
            return null;

        size_t end = keyAddress;
        while (end < _buffer.length && _buffer[end] != 0)
            ++end;
        if (end == _buffer.length)
            return null;
        return bytesToString(_buffer[keyAddress .. end]);
    }

    Vector keys() const @nogc nothrow
    {
        if (!_valid)
            return Vector.init;
        return Vector(_buffer, _keysData, _keysWidth, _length,
            FlexBufferType.vectorKey, FlexBufferType.key, false);
    }

    Vector values() const @nogc nothrow
    {
        if (!_valid)
            return Vector.init;
        return Vector(_buffer, _data, _width, _length,
            FlexBufferType.vector, FlexBufferType.nullValue, false);
    }

    private size_t indexOf(string key) const @nogc nothrow
    {
        if (!_valid)
            return size_t.max;

        const needle = cast(const(ubyte)[]) key;
        size_t low = 0;
        size_t high = _length;
        while (low < high)
        {
            const middle = (low + high) / 2;
            const candidate = keyAt(middle);
            if (candidate is null)
                return size_t.max;
            import std.algorithm.comparison : cmp;
            const order = cmp(cast(const(ubyte)[]) candidate, needle);
            if (order == 0)
                return middle;
            if (order < 0)
                low = middle + 1;
            else
                high = middle;
        }
        return size_t.max;
    }
}

struct Vector
{
    private const(ubyte)[] _buffer;
    private size_t _data;
    private BitWidth _width;
    private size_t _length;
    private FlexBufferType _type;
    private FlexBufferType _elementType;
    private bool _fixed;
    private bool _valid;

    private this(const(ubyte)[] buffer, size_t data, BitWidth width,
        size_t length, FlexBufferType type, FlexBufferType elementType,
        bool fixed) @nogc nothrow
    {
        _buffer = buffer;
        _data = data;
        _width = width;
        _length = length;
        _type = type;
        _elementType = elementType;
        _fixed = fixed;
        _valid = true;
    }

    @property bool isValid() const @nogc nothrow
    {
        return _valid;
    }

    @property size_t length() const @nogc nothrow
    {
        return _valid ? _length : 0;
    }

    @property FlexBufferType elementType() const @nogc nothrow
    {
        return _elementType;
    }

    @property bool isTyped() const @nogc nothrow
    {
        return _valid && _elementType != FlexBufferType.nullValue;
    }

    @property bool isFixed() const @nogc nothrow
    {
        return _valid && _fixed;
    }

    Reference opIndex(size_t index) const @nogc nothrow
    {
        if (!_valid || index >= _length)
            return Reference.init;

        const widthBytes = bitWidthBytes(_width);
        const valueAddress = _data + index * widthBytes;
        if (valueAddress > _buffer.length ||
            widthBytes > _buffer.length - valueAddress)
            return Reference.init;

        if (_elementType != FlexBufferType.nullValue)
            return Reference(_buffer, valueAddress, _width, _width,
                _elementType);

        const typeAddress = _data + _length * widthBytes + index;
        if (typeAddress >= _buffer.length)
            return Reference.init;

        FlexBufferType type;
        BitWidth width;
        if (!unpackType(_buffer[typeAddress], type, width))
            return Reference.init;
        return Reference(_buffer, valueAddress, _width, width, type);
    }

    int opApply(scope int delegate(Reference) dg) const
    {
        foreach (i; 0 .. _length)
        {
            const result = dg(opIndex(i));
            if (result)
                return result;
        }
        return 0;
    }
}

Reference getRoot(const(ubyte)[] buffer) @nogc nothrow
{
    if (buffer.length < 3)
        return Reference.init;

    BitWidth rootWidth;
    if (!bitWidthFromBytes(buffer[$ - 1], rootWidth))
        return Reference.init;

    FlexBufferType type;
    BitWidth width;
    if (!unpackType(buffer[$ - 2], type, width))
        return Reference.init;

    const payloadEnd = buffer.length - 2;
    if (payloadEnd < bitWidthBytes(rootWidth))
        return Reference.init;

    const data = payloadEnd - bitWidthBytes(rootWidth);
    return Reference(buffer, data, rootWidth, width, type);
}
