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

module serialize;

import std.file : exists, read;
import std.path : buildPath, dirName;
import std.stdio : writeln;

import asdf : Asdf, deserialize, serializeToJson;
import asdf.jsonparser : parseJson;

import MyGame.Example.Any;
import MyGame.Example.AnyAmbiguousAliases;
import MyGame.Example.Monster;

private struct NestedShape
{
    string name;
}

private struct Shape
{
    string test_type;
    NestedShape test;
    string[] testarrayofstring;
    string color;
    long mana;
    double testf;
    ulong testhashu32_fnv1;
    long testhashs64_fnv1;
    ulong long_enum_non_enum_default;
}

private string findGolden()
{
    const local = buildPath(dirName(__FILE_FULL_PATH__), "data",
        "monsterdata_test.mon");
    foreach (candidate; [local, "../tests/monsterdata_test.mon",
        "tests/monsterdata_test.mon"])
    {
        if (exists(candidate))
            return candidate;
    }
    throw new Exception("cannot find monsterdata_test.mon in tests/data");
}

void main()
{
    const buff = cast(const(ubyte)[]) read(findGolden());
    auto monster = Monster.getRootAsMonster(buff);

    const json = serializeToJson(monster);
    auto parsed = deserialize!Shape(json);
    assert(parsed.test_type == "Monster");
    assert(parsed.test.name == "Fred");
    assert(parsed.testarrayofstring == ["test1", "test2"]);
    assert(parsed.color == "Blue");
    assert(parsed.mana == 150);
    assert(parsed.testf == 3.14159);
    assert(parsed.testhashu32_fnv1 == 3_715_746_113);
    assert(parsed.testhashs64_fnv1 == 7_930_699_090_847_568_257);
    assert(parsed.long_enum_non_enum_default == 0);

    auto raw = parseJson(json);
    assert(raw["testarrayofstring2"] == Asdf.init);

    auto ambiguous = deserialize!AnyAmbiguousAliases(`"M1"`);
    assert(ambiguous == AnyAmbiguousAliases.M1);

    writeln("D FlatBuffers serialization tests passed");
}
