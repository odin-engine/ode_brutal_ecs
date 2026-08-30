/*
    2026 (c) Zaya https://github.com/zm69

    Tests for binary snapshot serialization (serialization.odin).
*/

package ode_ecs__tests

import "core:testing"
import "core:log"
import "core:mem"

import ecs "../src"

@(test)
table__slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    at: ecs.Table
    defer ecs.table__terminate(&at)
    testing.expect(t, ecs.table__init(&at, &db, 5, {Position, AI}) == nil)

    testing.expect(t, len(ecs.slice(&at)) == 0)
    testing.expect(t, len(ecs.slice(&at, Position)) == 0)

    e0, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e0, Position).x = 11
    ecs.get_component(&at, e0, AI).neurons_count = 111

    e1, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e1, Position).x = 22
    ecs.get_component(&at, e1, AI).neurons_count = 222

    eids := ecs.slice(&at)
    pos_col := ecs.slice(&at, Position)
    ai_col := ecs.slice(&at, AI)

    testing.expect(t, len(eids) == 2)
    testing.expect(t, len(pos_col) == 2)
    testing.expect(t, len(ai_col) == 2)

    testing.expect(t, eids[0] == e0)
    testing.expect(t, eids[1] == e1)
    testing.expect(t, pos_col[0].x == 11)
    testing.expect(t, pos_col[1].x == 22)
    testing.expect(t, ai_col[0].neurons_count == 111)
    testing.expect(t, ai_col[1].neurons_count == 222)
}

@(test)
table__slice_after_remove__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    at: ecs.Table
    defer ecs.table__terminate(&at)
    testing.expect(t, ecs.table__init(&at, &db, 5, {Position}) == nil)

    testing.expect(t, len(ecs.slice(&at, Position)) == 0)

    e0, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e0, Position).x = 10
    e1, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e1, Position).x = 20
    e2, _ := ecs.create_entity(&at)
    ecs.get_component(&at, e2, Position).x = 30

    s := ecs.slice(&at, Position)
    testing.expect(t, len(s) == 3)
    testing.expect(t, s[0].x == 10)
    testing.expect(t, s[1].x == 20)
    testing.expect(t, s[2].x == 30)

    testing.expect(t, ecs.table__remove_entity(&at, e1) == nil)
    s = ecs.slice(&at, Position)
    testing.expect(t, len(s) == 2)
    found_10, found_30 := false, false
    for row in s {
        if row.x == 10 do found_10 = true
        if row.x == 30 do found_30 = true
    }
    testing.expect(t, found_10 && found_30)
}

@(test)
table__entities_slice__test :: proc(t: ^testing.T) {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    allocator := context.allocator
    context.allocator = mem.panic_allocator()

    db: ecs.Database
    defer ecs.terminate(&db)
    testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

    at: ecs.Table
    defer ecs.table__terminate(&at)
    testing.expect(t, ecs.table__init(&at, &db, 5, {Position}) == nil)

    testing.expect(t, len(ecs.entities_slice(&at)) == 0)

    e0, _ := ecs.create_entity(&at)
    e1, _ := ecs.create_entity(&at)
    e2, _ := ecs.create_entity(&at)

    dense := ecs.slice(&at, Position)
    entities := ecs.entities_slice(&at)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, entities[0] == e0)
    testing.expect(t, entities[1] == e1)
    testing.expect(t, entities[2] == e2)

    testing.expect(t, ecs.table__remove_entity(&at, e0) == nil)
    dense = ecs.slice(&at, Position)
    entities = ecs.entities_slice(&at)
    testing.expect(t, len(entities) == len(dense))
    testing.expect(t, len(entities) == 2)
    for i in 0..<len(entities) {
        testing.expect(t, ecs.get_component(&at, entities[i], Position) == &dense[i])
    }
}
