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

module codegen_matrix;

import asdf : Asdf, serializeToJson;
import asdf.jsonparser : parseJson;

import flatbuffers;
import CodegenMatrix.Aligned;
import CodegenMatrix.Alias;
import CodegenMatrix.AliasHolder;
import CodegenMatrix.Child;
import CodegenMatrix.Fields;
import CodegenMatrix.Flags;
import CodegenMatrix.Kind;
import CodegenMatrix.Optional;
import CodegenMatrix.Only;
import CodegenMatrix.Shadow;
import CodegenMatrix.ShadowTable;
import CodegenMatrix.UnionOnly;

private UOffsetT makeChild(ref FlatBufferBuilder fbb, string value)
{
    const name = fbb.createString(value);
    Child.startChild(fbb);
    Child.addName(fbb, name);
    return Child.endChild(fbb);
}

void main()
{
    auto fbb = FlatBufferBuilder(256);
    const child = makeChild(fbb, "child");
    UnionOnly.startUnionOnly(fbb);
    UnionOnly.addItemType(fbb, Only.Child);
    UnionOnly.addItem(fbb, child);
    auto root = UnionOnly.endUnionOnly(fbb);
    UnionOnly.finishUnionOnlyBuffer(fbb, root);

    auto unionOnly = UnionOnly.getRootAsUnionOnly(fbb.finishedBytes());
    assert(unionOnly.itemType == Only.Child);
    assert(unionOnly.itemAs!Child.get.name == "child");
    auto unionJson = parseJson(serializeToJson(unionOnly));
    assert(unionJson["item", "name"] == "child");

    auto aliasFbb = FlatBufferBuilder(256);
    const aliasChild = makeChild(aliasFbb, "alias");
    AliasHolder.startAliasHolder(aliasFbb);
    AliasHolder.addAType(aliasFbb, Alias.M2);
    AliasHolder.addA(aliasFbb, aliasChild);
    auto aliasRoot = AliasHolder.endAliasHolder(aliasFbb);
    aliasFbb.finish(aliasRoot);

    auto aliasHolder = AliasHolder.getRootAsAliasHolder(
        aliasFbb.finishedBytes());
    assert(aliasHolder.aType == Alias.M2);
    assert(aliasHolder.aAs!Child.get.name == "alias");
    auto aliasJson = parseJson(serializeToJson(aliasHolder));
    assert(aliasJson["a_type"] == "M2");
    assert(aliasJson["a", "name"] == "alias");

    auto fieldsFbb = FlatBufferBuilder(256);
    Fields.startFields(fieldsFbb);
    Fields.addState(fieldsFbb, 42);
    Fields.addSerializer(fieldsFbb, 7);
    Fields.addI(fieldsFbb, 3);
    Fields.addFbb(fieldsFbb, 5);
    Fields.addFlags(fieldsFbb, cast(Flags) 3);
    auto fieldsRoot = Fields.endFields(fieldsFbb);
    fieldsFbb.finish(fieldsRoot);

    auto fields = Fields.getRootAsFields(fieldsFbb.finishedBytes());
    assert(fields.state == 42);
    assert(fields.serializer == 7);
    assert(fields.i == 3);
    assert(fields.fbb == 5);
    auto fieldsJson = parseJson(serializeToJson(fields));
    assert(fieldsJson["state"] == parseJson("42"));
    assert(fieldsJson["serializer"] == parseJson("7"));
    assert(fieldsJson["i"] == parseJson("3"));
    assert(fieldsJson["fbb"] == parseJson("5"));
    assert(fieldsJson["flags"] == parseJson("3"));

    auto optionalFbb = FlatBufferBuilder(128);
    Optional.startOptional(optionalFbb);
    Optional.addX(optionalFbb, 0);
    Optional.addE(optionalFbb, Kind.High);
    auto optionalRoot = Optional.endOptional(optionalFbb);
    optionalFbb.finish(optionalRoot);

    auto optional = Optional.getRootAsOptional(optionalFbb.finishedBytes());
    assert(!optional.x.isNull);
    assert(optional.x.get == 0);
    assert(!optional.e.isNull);
    assert(optional.e.get == Kind.High);
    auto optionalJson = parseJson(serializeToJson(optional));
    assert(optionalJson["x"] == parseJson("0"));
    assert(optionalJson["e"] == "High");

    auto unsetFbb = FlatBufferBuilder(128);
    Optional.startOptional(unsetFbb);
    auto unsetRoot = Optional.endOptional(unsetFbb);
    unsetFbb.finish(unsetRoot);
    auto unsetJson = parseJson(serializeToJson(
        Optional.getRootAsOptional(unsetFbb.finishedBytes())));
    assert(unsetJson["x"] == Asdf.init);
    assert(unsetJson["e"] == Asdf.init);

    auto shadowFbb = FlatBufferBuilder(128);
    ShadowTable.startShadowTable(shadowFbb);
    ShadowTable.addS(shadowFbb, Shadow.createShadow(shadowFbb, 11, 22));
    auto shadowRoot = ShadowTable.endShadowTable(shadowFbb);
    shadowFbb.finish(shadowRoot);
    auto shadowTable = ShadowTable.getRootAsShadowTable(
        shadowFbb.finishedBytes());
    assert(!shadowTable.s.isNull);
    assert(shadowTable.s.get.fbb == 11);
    assert(shadowTable.s.get.state == 22);

    auto alignedFbb = FlatBufferBuilder(128);
    const alignedData = Aligned.createDataVector(alignedFbb,
        cast(const(ubyte)[]) [1, 2, 3, 4, 5]);
    Aligned.startAligned(alignedFbb);
    Aligned.addData(alignedFbb, alignedData);
    auto alignedRoot = Aligned.endAligned(alignedFbb);
    alignedFbb.finish(alignedRoot);
    auto aligned = Aligned.getRootAsAligned(alignedFbb.finishedBytes());
    assert(aligned.dataBytes == cast(const(ubyte)[]) [1, 2, 3, 4, 5]);
    assert((cast(size_t) aligned.dataBytes.ptr & 15) == 0);
}
