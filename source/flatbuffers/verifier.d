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

module flatbuffers.verifier;

import flatbuffers.base;
import flatbuffers.builder : FlatBufferBuilder;
import flatbuffers.table : Table;


struct VerifierOptions
{
    uint maxDepth = 64;
    uint maxTables = 1_000_000;
    bool alignmentCheck = true;
    bool stringEndCheck = true;
}

alias VerifyTable = bool function(ref Verifier, uint) @nogc nothrow;
alias VerifyUnion = bool function(ref Verifier, ubyte, uint) @nogc nothrow;

struct Verifier
{
    const(ubyte)[] bytes;
    VerifierOptions options;
    uint depth;
    uint numTables;

    this(const(ubyte)[] bytes,
        VerifierOptions options = VerifierOptions.init) @nogc nothrow
    {
        this.bytes = bytes;
        this.options = options;
    }

    bool verifyBuffer(string identifier, bool sizePrefixed,
        VerifyTable verifyTable) @nogc nothrow
    {
        return verifyBufferInternal(identifier, sizePrefixed, verifyTable,
            true);
    }

    private bool verifyBufferInternal(string identifier, bool sizePrefixed,
        VerifyTable verifyTable, bool resetCounters) @nogc nothrow
    {
        if (resetCounters)
        {
            depth = 0;
            numTables = 0;
        }

        const uint initialDepth = depth;
        const uint initialTables = numTables;

        if (verifyTable is null)
            return false;

        size_t start = 0;
        if (sizePrefixed)
        {
            UOffsetT prefix;
            if (!tryGet!UOffsetT(bytes, 0, prefix))
                return false;
            if (prefix != bytes.length - sizePrefixLength)
                return false;
            start = sizePrefixLength;
        }

        if (identifier.length != 0)
        {
            if (identifier.length != fileIdentifierLength)
                return false;
            if (start > bytes.length || sizeUOffsetT > bytes.length - start)
                return false;

            const size_t identifierPos = start + sizeUOffsetT;
            if (fileIdentifierLength > bytes.length - identifierPos)
                return false;

            foreach (i; 0 .. fileIdentifierLength)
            {
                if (bytes[identifierPos + i] != cast(ubyte) identifier[i])
                    return false;
            }
        }

        UOffsetT root;
        if (!tryGet!UOffsetT(bytes, start, root) || root == 0)
            return false;

        const size_t tablePos = start + root;
        if (tablePos >= bytes.length)
            return false;

        if (!verifyTable(this, cast(uint) tablePos))
            return false;

        return depth == initialDepth && numTables > initialTables;
    }

    bool verifyTableStart(uint tablePos) @nogc nothrow
    {
        if (depth >= options.maxDepth || numTables >= options.maxTables)
            return false;

        size_t vtablePos;
        VOffsetT vtableSize;
        VOffsetT objectSize;
        if (!tableInfo(tablePos, vtablePos, vtableSize, objectSize))
            return false;

        ++depth;
        ++numTables;
        return true;
    }

    bool verifyTableEnd(uint tablePos) @nogc nothrow
    {
        if (depth == 0)
            return false;
        --depth;
        return true;
    }

    bool verifyField(uint tablePos, VOffsetT vtableOffset,
        size_t elementSize, size_t alignment, bool required)
        @nogc nothrow
    {
        bool valid;
        const fieldOff = fieldOffset(tablePos, vtableOffset, valid);
        if (!valid)
            return false;
        if (fieldOff == 0)
            return !required;

        size_t vtablePos;
        VOffsetT vtableSize;
        VOffsetT objectSize;
        if (!tableInfo(tablePos, vtablePos, vtableSize, objectSize))
            return false;

        const size_t objectEnd = tablePos + objectSize;
        const size_t fieldPos = tablePos + fieldOff;
        if (fieldPos > objectEnd || elementSize > objectEnd - fieldPos)
            return false;
        if (fieldPos > bytes.length || elementSize > bytes.length - fieldPos)
            return false;
        if (options.alignmentCheck && alignment > 1 &&
            (fieldPos & (alignment - 1)) != 0)
            return false;
        return true;
    }

    bool verifyString(uint tablePos, VOffsetT vtableOffset, bool required)
        @nogc nothrow
    {
        bool valid;
        const fieldOff = fieldOffset(tablePos, vtableOffset, valid);
        if (!valid)
            return false;
        if (fieldOff == 0)
            return !required;

        const size_t fieldPos = tablePos + fieldOff;
        if (options.alignmentCheck && (fieldPos & (sizeUOffsetT - 1)) != 0)
            return false;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, fieldPos, relative))
            return false;
        if (relative == 0 || relative > bytes.length - fieldPos)
            return false;

        return verifyStringAt(fieldPos + relative);
    }

    bool verifyVectorOfData(uint tablePos, VOffsetT vtableOffset,
        size_t elementSize, bool required) @nogc nothrow
    {
        size_t dataPos;
        size_t length;
        const result = vectorData(tablePos, vtableOffset, required,
            dataPos, length);
        if (result != VectorResult.valid)
            return result == VectorResult.absent;

        if (length != 0 && elementSize > (bytes.length - dataPos) / length)
            return false;
        return true;
    }

    bool verifyVectorOfStrings(uint tablePos, VOffsetT vtableOffset,
        bool required) @nogc nothrow
    {
        size_t dataPos;
        size_t length;
        const result = vectorData(tablePos, vtableOffset, required,
            dataPos, length);
        if (result != VectorResult.valid)
            return result == VectorResult.absent;

        if (length > (bytes.length - dataPos) / sizeUOffsetT)
            return false;

        foreach (i; 0 .. length)
        {
            const size_t elementPos = dataPos + i * sizeUOffsetT;
            if (options.alignmentCheck &&
                (elementPos & (sizeUOffsetT - 1)) != 0)
                return false;

            UOffsetT relative;
            if (!tryGet!UOffsetT(bytes, elementPos, relative))
                return false;
            if (relative == 0 || relative > bytes.length - elementPos)
                return false;
            if (!verifyStringAt(elementPos + relative))
                return false;
        }
        return true;
    }

    bool verifyVectorOfTables(uint tablePos, VOffsetT vtableOffset,
        VerifyTable verifyTable, bool required) @nogc nothrow
    {
        if (verifyTable is null)
            return false;

        size_t dataPos;
        size_t length;
        const result = vectorData(tablePos, vtableOffset, required,
            dataPos, length);
        if (result != VectorResult.valid)
            return result == VectorResult.absent;

        if (length > (bytes.length - dataPos) / sizeUOffsetT)
            return false;

        foreach (i; 0 .. length)
        {
            const size_t elementPos = dataPos + i * sizeUOffsetT;
            if (options.alignmentCheck &&
                (elementPos & (sizeUOffsetT - 1)) != 0)
                return false;

            UOffsetT relative;
            if (!tryGet!UOffsetT(bytes, elementPos, relative))
                return false;
            if (relative == 0 || relative > bytes.length - elementPos)
                return false;

            const size_t childPos = elementPos + relative;
            if (childPos >= bytes.length)
                return false;
            if (!verifyTable(this, cast(uint) childPos))
                return false;
        }
        return true;
    }

    bool verifyTable(uint tablePos, VOffsetT vtableOffset,
        VerifyTable verifyTable, bool required) @nogc nothrow
    {
        if (verifyTable is null)
            return false;

        bool valid;
        const fieldOff = fieldOffset(tablePos, vtableOffset, valid);
        if (!valid)
            return false;
        if (fieldOff == 0)
            return !required;

        const size_t fieldPos = tablePos + fieldOff;
        if (options.alignmentCheck && (fieldPos & (sizeUOffsetT - 1)) != 0)
            return false;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, fieldPos, relative))
            return false;
        if (relative == 0 || relative > bytes.length - fieldPos)
            return false;

        const size_t target = fieldPos + relative;
        if (target >= bytes.length)
            return false;
        return verifyTable(this, cast(uint) target);
    }

    bool verifyUnion(uint tablePos, VOffsetT typeVOffset,
        VOffsetT valueVOffset, VerifyUnion verifyUnion, bool required)
        @nogc nothrow
    {
        if (verifyUnion is null)
            return false;

        bool valid;
        const typeOff = fieldOffset(tablePos, typeVOffset, valid);
        if (!valid)
            return false;
        if (typeOff == 0)
            return !required;

        const size_t typePos = tablePos + typeOff;
        if (typePos >= bytes.length)
            return false;
        const ubyte type = bytes[typePos];
        if (type == 0)
            return true;

        const valueOff = fieldOffset(tablePos, valueVOffset, valid);
        if (!valid || valueOff == 0)
            return false;

        const size_t fieldPos = tablePos + valueOff;
        if (options.alignmentCheck && (fieldPos & (sizeUOffsetT - 1)) != 0)
            return false;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, fieldPos, relative))
            return false;
        if (relative == 0 || relative > bytes.length - fieldPos)
            return false;

        const size_t target = fieldPos + relative;
        if (target >= bytes.length)
            return false;
        return verifyUnion(this, type, cast(uint) target);
    }

    bool verifyNestedBuffer(uint tablePos, VOffsetT vtableOffset,
        string identifier, VerifyTable verifyTable, bool required)
        @nogc nothrow
    {
        if (verifyTable is null)
            return false;

        size_t dataPos;
        size_t length;
        const result = vectorData(tablePos, vtableOffset, required,
            dataPos, length);
        if (result != VectorResult.valid)
            return result == VectorResult.absent;
        if (length > bytes.length - dataPos)
            return false;

        auto nested = Verifier(bytes[dataPos .. dataPos + length], options);
        nested.depth = depth;
        nested.numTables = numTables;
        const nestedResult = nested.verifyBufferInternal(identifier, false,
            verifyTable, false);
        depth = nested.depth;
        numTables = nested.numTables;
        return nestedResult;
    }

    bool verifyUnionData(uint pos, size_t elementSize, size_t alignment)
        @nogc nothrow
    {
        if (pos > bytes.length || elementSize > bytes.length - pos)
            return false;
        if (options.alignmentCheck && alignment > 1 &&
            (pos & (alignment - 1)) != 0)
            return false;
        return true;
    }

    private enum VectorResult
    {
        valid,
        absent,
        invalid
    }

    private VectorResult vectorData(uint tablePos, VOffsetT vtableOffset,
        bool required, out size_t dataPos, out size_t length)
        @nogc nothrow
    {
        bool valid;
        const fieldOff = fieldOffset(tablePos, vtableOffset, valid);
        if (!valid)
            return VectorResult.invalid;
        if (fieldOff == 0)
            return required ? VectorResult.invalid : VectorResult.absent;

        const size_t fieldPos = tablePos + fieldOff;
        if (options.alignmentCheck && (fieldPos & (sizeUOffsetT - 1)) != 0)
            return VectorResult.invalid;

        UOffsetT relative;
        if (!tryGet!UOffsetT(bytes, fieldPos, relative))
            return VectorResult.invalid;
        if (relative == 0 || relative > bytes.length - fieldPos)
            return VectorResult.invalid;

        const size_t vectorPos = fieldPos + relative;
        if (options.alignmentCheck && (vectorPos & (sizeUOffsetT - 1)) != 0)
            return VectorResult.invalid;

        UOffsetT vectorLength;
        if (!tryGet!UOffsetT(bytes, vectorPos, vectorLength))
            return VectorResult.invalid;

        dataPos = vectorPos + sizeUOffsetT;
        if (dataPos > bytes.length)
            return VectorResult.invalid;
        length = vectorLength;
        return VectorResult.valid;
    }

    private bool verifyStringAt(size_t stringPos) @nogc nothrow
    {
        if (options.alignmentCheck && (stringPos & (sizeUOffsetT - 1)) != 0)
            return false;

        UOffsetT length;
        if (!tryGet!UOffsetT(bytes, stringPos, length))
            return false;

        const size_t dataPos = stringPos + sizeUOffsetT;
        if (dataPos > bytes.length || length > bytes.length - dataPos)
            return false;
        if (!options.stringEndCheck)
            return true;

        if (length >= bytes.length - dataPos)
            return false;
        return bytes[dataPos + length] == 0;
    }

    private VOffsetT fieldOffset(uint tablePos, VOffsetT vtableOffset,
        out bool valid) const @nogc nothrow
    {
        valid = false;

        size_t vtablePos;
        VOffsetT vtableSize;
        VOffsetT objectSize;
        if (!tableInfo(tablePos, vtablePos, vtableSize, objectSize))
            return 0;

        if (vtableOffset < 2 * sizeVOffsetT ||
            cast(size_t) vtableOffset + sizeVOffsetT > vtableSize)
        {
            valid = true;
            return 0;
        }

        VOffsetT fieldOff;
        if (!tryGet!VOffsetT(bytes, vtablePos + vtableOffset, fieldOff))
            return 0;

        if (fieldOff != 0 &&
            (fieldOff < sizeSOffsetT || fieldOff >= objectSize))
            return 0;

        valid = true;
        return fieldOff;
    }

    private bool tableInfo(uint tablePos, out size_t vtablePos,
        out VOffsetT vtableSize, out VOffsetT objectSize)
        const @nogc nothrow
    {
        SOffsetT tableOffset;
        if (!tryGet!SOffsetT(bytes, tablePos, tableOffset))
            return false;

        const long vtable = cast(long) tablePos - tableOffset;
        if (vtable < 0)
            return false;

        vtablePos = cast(size_t) vtable;
        if (options.alignmentCheck && (vtablePos & (sizeVOffsetT - 1)) != 0)
            return false;
        if (options.alignmentCheck && (tablePos & (sizeUOffsetT - 1)) != 0)
            return false;
        if (vtablePos > bytes.length ||
            sizeVOffsetT > bytes.length - vtablePos)
            return false;

        if (!tryGet!VOffsetT(bytes, vtablePos, vtableSize))
            return false;
        if (vtableSize < 2 * sizeVOffsetT ||
            vtableSize > bytes.length - vtablePos)
            return false;

        if (!tryGet!VOffsetT(bytes, vtablePos + sizeVOffsetT, objectSize))
            return false;
        if (objectSize < sizeSOffsetT)
            return false;
        if (tablePos > bytes.length ||
            objectSize > bytes.length - tablePos)
            return false;

        return true;
    }
};

private bool verifyValid(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyString(pos, 4, true))
        return false;
    if (!v.verifyField(pos, 6, sizeInt32, 4, false))
        return false;
    if (!v.verifyVectorOfData(pos, 8, sizeByte, false))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildValidBuffer()
{
    auto fbb = FlatBufferBuilder(64);
    const name = fbb.createString("hello");
    const data = fbb.createByteVector(cast(const(ubyte)[]) [1, 2, 3]);

    fbb.startObject(3);
    fbb.addOffset(0, name, 0);
    fbb.add!int(1, 42, 0);
    fbb.addOffset(2, data, 0);
    auto root = fbb.endObject();
    fbb.finish(root, "MONS");

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

private uint rootTablePosition(const(ubyte)[] buf)
{
    return getRoot(buf);
}

private Table rootTable(const(ubyte)[] buf)
{
    return Table(buf, getRoot(buf));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto verifier = Verifier(bytes);

    assert(verifier.verifyBuffer("MONS", false, &verifyValid));
    assert(verifier.depth == 0);
}

unittest
{
    auto valid = buildValidBuffer();
    auto truncated = valid[0 .. valid.length / 2];
    auto verifier = Verifier(truncated);

    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    put!UOffsetT(bytes, 0, 0xFFFF_FF00);
    auto verifier = Verifier(bytes);

    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    put!UOffsetT(bytes, 0, 0);
    auto verifier = Verifier(bytes);

    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto table = rootTable(bytes);
    const field = rootTablePosition(bytes) + table.offset(4);
    const stringPos = field + get!UOffsetT(bytes, field);
    const length = get!UOffsetT(bytes, stringPos);

    bytes[stringPos + sizeUOffsetT + length] = 'X';

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto table = rootTable(bytes);
    const field = rootTablePosition(bytes) + table.offset(8);
    const vectorPos = field + get!UOffsetT(bytes, field);

    put!UOffsetT(bytes, vectorPos, 1000);

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto table = rootTable(bytes);
    const tablePos = rootTablePosition(bytes);
    const vtablePos = tablePos - get!SOffsetT(bytes, tablePos);

    put!VOffsetT(bytes, vtablePos + 4, 0);

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    const tablePos = rootTablePosition(bytes);
    put!SOffsetT(bytes, tablePos, 0x7FFF_FFFF);

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

private bool verifyChild(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyField(pos, 4, sizeInt32, 4, false))
        return false;
    return v.verifyTableEnd(pos);
}

private bool verifyParent(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyTable(pos, 4, &verifyChild, true))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildNestedBuffer()
{
    auto fbb = FlatBufferBuilder(64);

    fbb.startObject(1);
    fbb.add!int(0, 7, 0);
    const child = fbb.endObject();

    fbb.startObject(1);
    fbb.addOffset(0, child, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

unittest
{
    auto bytes = buildNestedBuffer();

    auto shallow = Verifier(bytes, VerifierOptions(1));
    assert(!shallow.verifyBuffer(null, false, &verifyParent));

    auto deep = Verifier(bytes, VerifierOptions(2));
    assert(deep.verifyBuffer(null, false, &verifyParent));
}

private bool verifyStringVector(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyVectorOfStrings(pos, 4, true))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildStringVector()
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

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

unittest
{
    auto valid = buildStringVector();
    auto verifier = Verifier(valid);
    assert(verifier.verifyBuffer(null, false, &verifyStringVector));

    auto bytes = valid.dup;
    auto table = rootTable(bytes);
    const field = rootTablePosition(bytes) + table.offset(4);
    const data = table.vector(table.offset(4));

    put!UOffsetT(bytes, data, 0xFFFF_FF00);

    auto bad = Verifier(bytes);
    assert(!bad.verifyBuffer(null, false, &verifyStringVector));
}

private bool verifyTableVector(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyVectorOfTables(pos, 4, &verifyChild, true))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildTableVector()
{
    auto fbb = FlatBufferBuilder(64);

    fbb.startObject(1);
    fbb.add!int(0, 1, 0);
    const first = fbb.endObject();

    fbb.startObject(1);
    fbb.add!int(0, 2, 0);
    const second = fbb.endObject();

    fbb.startVector(sizeUOffsetT, 2, sizeUOffsetT);
    fbb.addOffset(second);
    fbb.addOffset(first);
    const vec = fbb.endVector(2);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

unittest
{
    auto valid = buildTableVector();
    auto verifier = Verifier(valid);
    assert(verifier.verifyBuffer(null, false, &verifyTableVector));

    auto bytes = valid.dup;
    auto table = rootTable(bytes);
    const data = table.vector(table.offset(4));

    put!UOffsetT(bytes, data, 0xFFFF_FF00);

    auto bad = Verifier(bytes);
    assert(!bad.verifyBuffer(null, false, &verifyTableVector));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto table = rootTable(bytes);
    const nameField = rootTablePosition(bytes) + table.offset(4);
    put!UOffsetT(bytes, nameField, 0);

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto table = rootTable(bytes);
    const vectorField = rootTablePosition(bytes) + table.offset(8);
    put!UOffsetT(bytes, vectorField, 0);

    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("MONS", false, &verifyValid));
}

unittest
{
    auto bytes = buildValidBuffer();
    auto verifier = Verifier(bytes);
    assert(!verifier.verifyBuffer("BAD!", false, &verifyValid));
}

private bool verifyEmpty(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    return v.verifyTableEnd(pos);
}

unittest
{
    auto aligned = new ubyte[16];
    put!VOffsetT(aligned, 4, 4);
    put!VOffsetT(aligned, 6, 4);
    put!SOffsetT(aligned, 8, 4);

    auto v = Verifier(aligned);
    assert(v.verifyTableStart(8));

    auto misalignedTable = new ubyte[16];
    put!VOffsetT(misalignedTable, 2, 4);
    put!VOffsetT(misalignedTable, 4, 4);
    put!SOffsetT(misalignedTable, 10, 8);

    auto badTable = Verifier(misalignedTable);
    assert(!badTable.verifyTableStart(10));

    auto misalignedVtable = new ubyte[16];
    put!VOffsetT(misalignedVtable, 3, 4);
    put!VOffsetT(misalignedVtable, 5, 4);
    put!SOffsetT(misalignedVtable, 8, 5);

    auto badVtable = Verifier(misalignedVtable);
    assert(!badVtable.verifyTableStart(8));
}

private bool verifyStructVector(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyVectorOfData(pos, 4, 2 * sizeUint32, false))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildStructVector()
{
    auto fbb = FlatBufferBuilder(64);
    fbb.startVector(8, 2, 4);
    fbb.add!uint(21);
    fbb.add!uint(20);
    fbb.add!uint(11);
    fbb.add!uint(10);
    const vec = fbb.endVector(2);

    fbb.startObject(1);
    fbb.addOffset(0, vec, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

unittest
{
    auto bytes = buildStructVector();
    auto verifier = Verifier(bytes);
    assert(verifier.verifyBuffer(null, false, &verifyStructVector));
}

private bool verifyNested(ref Verifier v, uint pos) @nogc nothrow
{
    if (!v.verifyTableStart(pos))
        return false;
    if (!v.verifyNestedBuffer(pos, 4, null, &verifyEmpty, true))
        return false;
    return v.verifyTableEnd(pos);
}

private ubyte[] buildNestedBufferField()
{
    auto inner = FlatBufferBuilder(32);
    inner.startObject(1);
    inner.add!int(0, 7, 0);
    auto innerRoot = inner.endObject();
    inner.finish(innerRoot);

    auto fbb = FlatBufferBuilder(64);
    const nested = fbb.createByteVector(inner.finishedBytes());
    fbb.startObject(1);
    fbb.addOffset(0, nested, 0);
    auto root = fbb.endObject();
    fbb.finish(root);

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

unittest
{
    auto bytes = buildNestedBufferField();

    auto shallow = Verifier(bytes, VerifierOptions(1));
    assert(!shallow.verifyBuffer(null, false, &verifyNested));

    auto deeper = Verifier(bytes, VerifierOptions(4));
    assert(deeper.verifyBuffer(null, false, &verifyNested));
}
