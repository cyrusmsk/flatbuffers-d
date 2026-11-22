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

module conformance;

import std.exception : assertThrown;

import flatbuffers;
import flatbuffers.exception : FlatBufferException;
import optional_scalars.OptionalByte;
import optional_scalars.ScalarStuff;
import order.Food;
import required_strings.Foo;
import Pizza;

private ubyte[] copyBytes(const(ubyte)[] source)
{
    auto result = new ubyte[source.length];
    result[] = source[];
    return result;
}

void main()
{
    auto optionalFbb = FlatBufferBuilder(256);
    ScalarStuff.startScalarStuff(optionalFbb);
    ScalarStuff.addMaybeI32(optionalFbb, 0);
    ScalarStuff.addDefaultI32(optionalFbb, 7);
    ScalarStuff.addMaybeEnum(optionalFbb, OptionalByte.One);
    auto optionalRoot = ScalarStuff.endScalarStuff(optionalFbb);
    ScalarStuff.finishScalarStuffBuffer(optionalFbb, optionalRoot);

    auto optionalBytes = copyBytes(optionalFbb.finishedBytes());
    assert(ScalarStuff.ScalarStuffBufferHasIdentifier(optionalBytes));
    assert(ScalarStuff.verifyScalarStuffBuffer(optionalBytes));

    auto optional = ScalarStuff.getRootAsScalarStuff(optionalBytes);
    assert(!optional.maybeI32.isNull);
    assert(optional.maybeI32.get == 0);
    assert(optional.defaultI32 == 7);
    assert(!optional.maybeEnum.isNull);
    assert(optional.maybeEnum.get == OptionalByte.One);

    auto foodFbb = FlatBufferBuilder(256);
    Pizza.Pizza.startPizza(foodFbb);
    Pizza.Pizza.addSize(foodFbb, 12);
    auto pizza = Pizza.Pizza.endPizza(foodFbb);
    Food.startFood(foodFbb);
    Food.addPizza(foodFbb, pizza);
    auto foodRoot = Food.endFood(foodFbb);
    foodFbb.finish(foodRoot);

    auto foodBytes = copyBytes(foodFbb.finishedBytes());
    assert(Food.verifyFoodBuffer(foodBytes));
    auto food = Food.getRootAsFood(foodBytes);
    assert(!food.pizza.isNull);
    assert(food.pizza.get.size == 12);

    auto requiredFbb = FlatBufferBuilder(128);
    const strA = requiredFbb.createString("a");
    const strB = requiredFbb.createString("b");
    Foo.startFoo(requiredFbb);
    Foo.addStrA(requiredFbb, strA);
    Foo.addStrB(requiredFbb, strB);
    auto requiredRoot = Foo.endFoo(requiredFbb);
    requiredFbb.finish(requiredRoot);

    auto requiredBytes = copyBytes(requiredFbb.finishedBytes());
    assert(Foo.verifyFooBuffer(requiredBytes));
    auto required = Foo.getRootAsFoo(requiredBytes);
    assert(required.strA == "a");
    assert(required.strB == "b");

    auto missingFbb = FlatBufferBuilder(128);
    const onlyA = missingFbb.createString("a");
    Foo.startFoo(missingFbb);
    Foo.addStrA(missingFbb, onlyA);
    assertThrown!FlatBufferException(Foo.endFoo(missingFbb));
}
