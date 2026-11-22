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

module integration;

import std.file : exists, read;
import std.path : buildPath, dirName;
import std.stdio : writeln;

import flatbuffers;
import MyGame.Example.Any;
import MyGame.Example.Color;
import MyGame.Example.Monster;
import MyGame.Example.Test;
import MyGame.Example.Vec3;

static assert(__traits(compiles, Monster.init.inventoryLength));
static assert(__traits(compiles, Monster.init.inventory()));
static assert(__traits(compiles, Monster.init.inventory(0)));
static assert(__traits(compiles, Monster.init.hasEnemy));
static assert(__traits(compiles, Monster.init.test4(0)));
static assert(__traits(compiles, Monster.init.testAs!Monster));

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

private void checkMonster(const(ubyte)[] buf)
{
    assert(Monster.MonsterBufferHasIdentifier(buf));

    auto monster = Monster.getRootAsMonster(buf);
    assert(monster.hp == 80);
    assert(monster.mana == 150);
    assert(monster.name == "MyMonster");
    assert(monster.color == Color.Blue);
    assert(monster.testbool);

    auto pos = monster.pos;
    assert(!pos.isNull);
    auto vec = pos.get;
    assert(vec.x == 1.0f);
    assert(vec.y == 2.0f);
    assert(vec.z == 3.0f);
    assert(vec.test1 == 3.0);
    assert(vec.test2 == Color.Green);
    assert(vec.test3.a == 5);
    assert(vec.test3.b == 6);

    assert(monster.inventory().length == 5);
    foreach (i; 0 .. 5)
        assert(monster.inventory()[i] == i);

    assert(monster.testType == Any.Monster);
    auto testMonster = monster.testAs!Monster;
    assert(!testMonster.isNull);
    assert(testMonster.get.name == "Fred");

    assert(monster.test4().length == 2);
    assert(monster.test4(0).a == 10);
    assert(monster.test4(0).b == 20);
    assert(monster.test4(1).a == 30);
    assert(monster.test4(1).b == 40);

    assert(monster.test5().length == 2);
    assert(monster.test5(1).a == 30);
    assert(monster.test5(1).b == 40);

    assert(monster.testarrayofstring().length == 2);
    assert(monster.testarrayofstring(0) == "test1");
    assert(monster.testarrayofstring(1) == "test2");

    auto enemy = monster.enemy;
    assert(!enemy.isNull);
    assert(enemy.get.name == "Fred");

    assert(monster.testarrayofbools().length == 3);
    assert(monster.testarrayofbools(0));
    assert(!monster.testarrayofbools(1));
    assert(monster.testarrayofbools(2));

    assert(monster.testhashs32Fnv1 == cast(int) 3_715_746_113u);
    assert(monster.testhashu32Fnv1 == 3_715_746_113u);
    assert(monster.testhashs64Fnv1 ==
        cast(long) 7_930_699_090_847_568_257UL);
    assert(monster.testhashu64Fnv1 == 7_930_699_090_847_568_257UL);
    assert(monster.testhashs32Fnv1a == cast(int) 2_390_860_913u);
    assert(monster.testhashu32Fnv1a == 2_390_860_913u);
    assert(monster.testhashs64Fnv1a ==
        cast(long) 4_898_026_182_817_603_057UL);
    assert(monster.testhashu64Fnv1a == 4_898_026_182_817_603_057UL);

    assert(monster.testf == 3.14159f);
    assert(monster.testf2 == 3.0f);
    assert(monster.testf3 == 0.0f);

    assert(monster.vectorOfLongs().length == 5);
    assert(monster.vectorOfLongs(0) == 1L);
    assert(monster.vectorOfLongs(4) == 100_000_000L);

    assert(monster.vectorOfDoubles().length == 3);
    assert(monster.vectorOfDoubles(0) == -double.max);
    assert(monster.vectorOfDoubles(1) == 0.0);
    assert(monster.vectorOfDoubles(2) == double.max);
}

private void checkNoGc(const(ubyte)[] buf) @nogc
{
    auto monster = Monster.getRootAsMonster(buf);
    assert(monster.hp == 80);
    assert(monster.name == "MyMonster");

    auto pos = monster.pos;
    assert(!pos.isNull);
    assert(pos.get.x == 1.0f);

    auto inventory = monster.inventory();
    assert(inventory.length == 5);
    assert(inventory[2] == 2);
}

private UOffsetT buildTestVector(ref FlatBufferBuilder fbb)
{
    Monster.startTest4Vector(fbb, 2);
    Test.createTest(fbb, 30, 40);
    Test.createTest(fbb, 10, 20);
    return fbb.endVector(2);
}

private ubyte[] buildMonster(bool sizePrefixed = false)
{
    auto fbb = FlatBufferBuilder(1024);

    const name = fbb.createString("MyMonster");
    const fred = fbb.createString("Fred");
    const firstString = fbb.createString("test1");
    const secondString = fbb.createString("test2");
    const inventory = Monster.createInventoryVector(fbb,
        cast(const(ubyte)[]) [0, 1, 2, 3, 4]);
    const stringVector = Monster.createTestarrayofstringVector(fbb,
        [firstString, secondString]);
    const test4 = buildTestVector(fbb);
    const test5 = buildTestVector(fbb);
    const boolVector = Monster.createTestarrayofboolsVector(fbb,
        [true, false, true]);
    const longVector = Monster.createVectorOfLongsVector(fbb,
        [1L, 100L, 10_000L, 1_000_000L, 100_000_000L]);
    const doubleVector = Monster.createVectorOfDoublesVector(fbb,
        [-double.max, 0.0, double.max]);

    Monster.startMonster(fbb);
    Monster.addName(fbb, fred);
    const testMonster = Monster.endMonster(fbb);

    Monster.startMonster(fbb);
    Monster.addName(fbb, fred);
    const enemy = Monster.endMonster(fbb);

    Monster.startMonster(fbb);
    Monster.addPos(fbb,
        Vec3.createVec3(fbb, 1.0f, 2.0f, 3.0f, 3.0, Color.Green, 5, 6));
    Monster.addHp(fbb, 80);
    Monster.addName(fbb, name);
    Monster.addInventory(fbb, inventory);
    Monster.addTestType(fbb, Any.Monster);
    Monster.addTest(fbb, testMonster);
    Monster.addTest4(fbb, test4);
    Monster.addTest5(fbb, test5);
    Monster.addTestarrayofstring(fbb, stringVector);
    Monster.addEnemy(fbb, enemy);
    Monster.addTestbool(fbb, true);
    Monster.addTesthashs32Fnv1(fbb, cast(int) 3_715_746_113u);
    Monster.addTesthashu32Fnv1(fbb, 3_715_746_113u);
    Monster.addTesthashs64Fnv1(fbb,
        cast(long) 7_930_699_090_847_568_257UL);
    Monster.addTesthashu64Fnv1(fbb, 7_930_699_090_847_568_257UL);
    Monster.addTesthashs32Fnv1a(fbb, cast(int) 2_390_860_913u);
    Monster.addTesthashu32Fnv1a(fbb, 2_390_860_913u);
    Monster.addTesthashs64Fnv1a(fbb,
        cast(long) 4_898_026_182_817_603_057UL);
    Monster.addTesthashu64Fnv1a(fbb, 4_898_026_182_817_603_057UL);
    Monster.addTestarrayofbools(fbb, boolVector);
    Monster.addVectorOfLongs(fbb, longVector);
    Monster.addVectorOfDoubles(fbb, doubleVector);

    const root = Monster.endMonster(fbb);
    if (sizePrefixed)
        Monster.finishSizePrefixedMonsterBuffer(fbb, root);
    else
        Monster.finishMonsterBuffer(fbb, root);

    const source = fbb.finishedBytes();
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

void main()
{
    const path = findGolden();
    const golden = cast(const(ubyte)[]) read(path);

    assert(Monster.verifyMonsterBuffer(golden));
    auto broken = new ubyte[golden.length];
    broken[] = golden[];
    broken[0] = 0;
    assert(!Monster.verifyMonsterBuffer(broken));
    checkMonster(golden);
    checkNoGc(golden);

    auto built = buildMonster();
    assert(Monster.verifyMonsterBuffer(built));
    checkMonster(built);

    auto prefixed = buildMonster(true);
    assert(Monster.SizePrefixedMonsterBufferHasIdentifier(prefixed));
    assert(Monster.verifyMonsterBuffer(prefixed, true));
    auto prefixedMonster = Monster.getSizePrefixedRootAsMonster(prefixed);
    assert(prefixedMonster.hp == 80);
    assert(prefixedMonster.name == "MyMonster");

    writeln("D FlatBuffers integration tests passed");
}
