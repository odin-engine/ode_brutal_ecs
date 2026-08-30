/*
    2026 (c) Zaya, https://github.com/zm69

    ODE_BRUTAL_ECS micro-benchmarks. The referee for performance work: run before and
    after a change and compare ns/op. Uses a fixed seed and reports the best of
    REPS repetitions (min is the most stable statistic for micro-benchmarks).

    Run:
        odin run . -o:speed -out:out/bench.exe

    For release-like numbers also try:
        odin run . -o:speed -disable-assert -no-bounds-check -define:ECS_VALIDATIONS=false -out:out/bench.exe

    Scenarios:
        iter_arch_slice     both columns of a Table (Position+Velocity) via
                            table__column_slice — always aligned, no group needed
        iter_arch_slice_eids  same Table, but via slice(&arch) + slice(&arch, T) —
                            the entities_slice + column_slice idiom, read as entity_id + both columns
        get_random          shuffled random get_component by entity (Table)
        churn_arch          add+remove a 2-component row as a single Table entity
                            (one add_entity/remove_entity call moves both columns
                            in one swap)
        churn_table_1col    add+remove churn against a single-column Table (the
                            minimal-payload structural-churn path)
        create_entity       raw entity id allocation + destruction, no components
        create_entity (untyped+set x4)  create_entity()+set_component×4 into a
                            4-column table — zeroes all 4 columns then overwrites
                            all 4; same total work as create_entity (typed x4)
        create_entity (typed x4)  create_entity(&t, A{},B{},C{},D{}) into the
                            same 4-column table — only zeroes columns NOT among
                            the ones just written (zero of them here); the gap
                            vs. the untyped+set number above is the zero-skip
                            optimization's payoff
        destroy             create+destroy entities in a 1-column Table, with
                            8 / 32 / 128 OTHER tables also attached to the same
                            database — destroy_entity is a direct eid_to_table
                            lookup, so this should stay flat regardless of how
                            many other tables exist
        walk_hierarchy      whole-forest breadth-first Relations_Table walk (100
                            root chains) — reports ns per entity visited
        roots               O(entities_cap) root scan over the same forest —
                            reports ns per live entity (cost is independent of
                            forest shape, only of how many entities exist)
        pair_first_target   O(1) point lookup, most-recently-added target of a
                            holder (PAIR_FANOUT=16 targets/holder)
        pair_targets_of     O(#pairs for that holder) full-list walk, reported
                            per holder (not per pair) for a direct, honest
                            contrast against pair_first_target's O(1) number
        churn_pair          steady-state pair_add (fan-out 16) + pair_remove_all
                            per holder — Pair_Table's structural churn cost
*/
package ode_ecs_benchmarks

// Core
    import "core:fmt"
    import "core:time"
    import "core:math/rand"

// ODE_BRUTAL_ECS
    import ecs "../src"

//
// Components
//
    Position :: struct { x, y: f32 }
    Velocity :: struct { dx, dy: f32 }
    Health :: struct { hp: f32 }
    Inventory :: struct { gold: int }
    Pair_Data :: struct { weight: f32 }

//
// Config
//
    N :: #config(BENCH_N, 100_000)
    CHURN_N :: #config(BENCH_CHURN_N, 10_000)
    REPS :: 9
    SEED :: 881982019898081

    g_sink: f64

//
// Helpers
//
    report :: proc(name: string, best_ns: i64, ops: int) {
        fmt.printf("%-24s %10.2f ns/op    (best of %v, %v ops)\n", name, f64(best_ns) / f64(ops), REPS, ops)
    }

    elapsed_ns :: proc(sw: ^time.Stopwatch) -> i64 {
        return time.duration_nanoseconds(time.stopwatch_duration(sw^))
    }

//
// Globals
//
    arch_db: ecs.Database
    arch_pv: ecs.Table
    eids: []ecs.entity_id
    shuffled: []ecs.entity_id

main :: proc() {
    rand.reset(SEED)

    fmt.printfln("ODE_BRUTAL_ECS benchmarks: N=%v, CHURN_N=%v, REPS=%v, ECS_VALIDATIONS=%v", N, CHURN_N, REPS, ecs.VALIDATIONS)
    fmt.println()

    setup_arch_db()
    bench_iter_arch_slice()
    bench_iter_arch_slice_eids()
    bench_get_random()

    bench_churn_arch()
    bench_churn_table_1col()

    bench_create_entity()
    bench_create_entity_untyped_set()
    bench_create_entity_typed()

    bench_destroy(8)
    bench_destroy(32)
    bench_destroy(128)

    bench_walk_hierarchy()
    bench_roots()

    bench_pair_first_target()
    bench_pair_targets_of()
    bench_pair_churn()

    fmt.println()
    fmt.println("checksum:", g_sink)
}

//
// Setup
//

setup_arch_db :: proc() {
    if ecs.init(&arch_db, N, context.allocator) != nil do panic("arch db init failed")
    if ecs.table__init(&arch_pv, &arch_db, N, {Position, Velocity}) != nil do panic("arch_pv init failed")

    eids = make([]ecs.entity_id, N)
    shuffled = make([]ecs.entity_id, N)

    for i in 0..<N {
        eid, err := ecs.table__create_entity(&arch_pv)
        if err != nil do panic("arch create_entity failed")

        p := ecs.table__get_component(&arch_pv, eid, Position)
        p.x = f32(i)
        p.y = 1

        v := ecs.table__get_component(&arch_pv, eid, Velocity)
        v.dx = 1
        v.dy = f32(i % 7)

        eids[i] = eid
    }

    copy(shuffled, eids)
    rand.shuffle(shuffled)
}

//
// Iteration
//

bench_iter_arch_slice :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        ps := ecs.table__column_slice(&arch_pv, Position)
        vs := ecs.table__column_slice(&arch_pv, Velocity)
        if ps == nil || vs == nil do panic("expected arch dense slices")
        for i in 0..<len(ps) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_arch_slice", best, N)
}

bench_iter_arch_slice_eids :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        row_eids := ecs.slice(&arch_pv)
        ps := ecs.slice(&arch_pv, Position)
        vs := ecs.slice(&arch_pv, Velocity)
        if ps == nil || vs == nil do panic("expected arch slices")
        for i in 0..<len(row_eids) {
            s += ps[i].x + vs[i].dx
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("iter_arch_slice_eids", best, N)
}

//
// Random access
//

bench_get_random :: proc() {
    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        s: f32 = 0
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in shuffled {
            s += ecs.table__get_component(&arch_pv, eid, Position).x
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
        g_sink += f64(s)
    }

    report("get_random", best, N)
}

//
// Structural churn
//

bench_churn_arch :: proc() {
    churn_db: ecs.Database
    churn_pv: ecs.Table

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.table__init(&churn_pv, &churn_db, CHURN_N, {Position, Velocity}) != nil do panic("churn arch init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            if ecs.table__add_entity(&churn_pv, eid) != nil do panic("arch add failed")
        }
        for eid in churn_eids {
            if ecs.table__remove_entity(&churn_pv, eid) != nil do panic("arch remove failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_pv))

    report("churn_arch (2 cols)", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

bench_churn_table_1col :: proc() {
    churn_db: ecs.Database
    churn_t: ecs.Table

    if ecs.init(&churn_db, CHURN_N, context.allocator) != nil do panic("churn db init failed")
    if ecs.table__init(&churn_t, &churn_db, CHURN_N, {Position}) != nil do panic("churn table init failed")

    churn_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(churn_eids)

    for i in 0..<CHURN_N {
        eid, err := ecs.create_entity(&churn_db)
        if err != nil do panic("create_entity failed")
        churn_eids[i] = eid
    }
    rand.shuffle(churn_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for eid in churn_eids {
            if ecs.table__add_entity(&churn_t, eid) != nil do panic("add_entity failed")
        }
        for eid in churn_eids {
            if ecs.table__remove_entity(&churn_t, eid) != nil do panic("remove_entity failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&churn_t))

    report("churn_table (1 col)", best, CHURN_N * 2)

    if ecs.terminate(&churn_db) != nil do panic("churn db terminate failed")
}

//
// Entity creation
//

bench_create_entity :: proc() {
    ce_db: ecs.Database
    if ecs.init(&ce_db, CHURN_N, context.allocator) != nil do panic("create_entity db init failed")

    ce_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(ce_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&ce_db)
            if err != nil do panic("create_entity failed")
            ce_eids[i] = eid
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))

        for eid in ce_eids {
            if ecs.destroy_entity(&ce_db, eid) != nil do panic("destroy failed")
        }
    }
    g_sink += f64(ecs.entities_len(&ce_db))

    report("create_entity", best, CHURN_N)

    if ecs.terminate(&ce_db) != nil do panic("create_entity db terminate failed")
}

// create_entity_untyped_set / create_entity_typed do IDENTICAL total work —
// allocate a row in a 4-column table and populate all 4 columns — but via the
// two different APIs: the old create_entity()+set_component×4 idiom (which
// zeroes all 4 columns in add_entity, then overwrites all 4) vs. the typed
// create_entity(&t, A{}, B{}, C{}, D{}) idiom (which only zeroes columns NOT
// among the ones it's about to write — zero of them here, since N equals the
// table's full column count). Same row count, same table shape, same 9 reps —
// the gap between these two numbers IS the zero-skip optimization's payoff.

bench_create_entity_untyped_set :: proc() {
    ce_db: ecs.Database
    ce_t: ecs.Table

    if ecs.init(&ce_db, CHURN_N, context.allocator) != nil do panic("untyped create_entity db init failed")
    if ecs.table__init(&ce_t, &ce_db, CHURN_N, {Position, Velocity, Health, Inventory}) != nil do panic("untyped create_entity table init failed")

    ce_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(ce_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&ce_t)
            if err != nil do panic("untyped create_entity failed")
            ecs.set_component(&ce_t, eid, Position{ x = f32(i), y = 0 })
            ecs.set_component(&ce_t, eid, Velocity{ dx = 1, dy = f32(i) })
            ecs.set_component(&ce_t, eid, Health{ hp = 100 })
            ecs.set_component(&ce_t, eid, Inventory{ gold = i })
            ce_eids[i] = eid
        }
        for eid in ce_eids {
            if ecs.destroy_entity(&ce_db, eid) != nil do panic("untyped create_entity destroy failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&ce_t))

    report("create_entity (untyped+set x4)", best, CHURN_N)

    if ecs.terminate(&ce_db) != nil do panic("untyped create_entity db terminate failed")
}

bench_create_entity_typed :: proc() {
    ce_db: ecs.Database
    ce_t: ecs.Table

    if ecs.init(&ce_db, CHURN_N, context.allocator) != nil do panic("typed create_entity db init failed")
    if ecs.table__init(&ce_t, &ce_db, CHURN_N, {Position, Velocity, Health, Inventory}) != nil do panic("typed create_entity table init failed")

    ce_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(ce_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        for i in 0..<CHURN_N {
            eid, err := ecs.create_entity(&ce_t,
                Position{ x = f32(i), y = 0 },
                Velocity{ dx = 1, dy = f32(i) },
                Health{ hp = 100 },
                Inventory{ gold = i },
            )
            if err != nil do panic("typed create_entity failed")
            ce_eids[i] = eid
        }
        for eid in ce_eids {
            if ecs.destroy_entity(&ce_db, eid) != nil do panic("typed create_entity destroy failed")
        }

        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.table_len(&ce_t))

    report("create_entity (typed x4)", best, CHURN_N)

    if ecs.terminate(&ce_db) != nil do panic("typed create_entity db terminate failed")
}

//
// Entity destruction with many tables attached
//

bench_destroy :: proc(table_count: int) {
    des_db: ecs.Database
    tabs := make([]ecs.Table, table_count)
    defer delete(tabs)

    if ecs.init(&des_db, CHURN_N, context.allocator) != nil do panic("destroy db init failed")
    for &tb in tabs {
        if ecs.table__init(&tb, &des_db, CHURN_N, {Position}) != nil do panic("table init failed")
    }

    des_eids := make([]ecs.entity_id, CHURN_N)
    defer delete(des_eids)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        for i in 0..<CHURN_N {
            eid, err := ecs.table__create_entity(&tabs[0]) // the OTHER tables just add to db.tables' size
            if err != nil do panic("create_entity failed")
            des_eids[i] = eid
        }

        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for eid in des_eids {
            if ecs.destroy_entity(&des_db, eid) != nil do panic("destroy failed")
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }
    g_sink += f64(ecs.entities_len(&des_db))

    report(fmt.tprintf("destroy (%v tables in db)", table_count), best, CHURN_N)

    if ecs.terminate(&des_db) != nil do panic("destroy db terminate failed")
}

WH_ROOTS :: 100

bench_setup_forest :: proc(db: ^ecs.Database, rt: ^ecs.Relations_Table) {
    chain_len := CHURN_N / WH_ROOTS
    for r in 0..<WH_ROOTS {
        prev, err := ecs.create_entity(db)
        if err != nil do panic("create_entity failed")
        for i in 1..<chain_len {
            next, nerr := ecs.create_entity(db)
            if nerr != nil do panic("create_entity failed")
            if ecs.set_parent(db, next, prev) != nil do panic("set_parent failed")
            prev = next
        }
    }
}

bench_walk_hierarchy :: proc() {
    wh_db: ecs.Database
    wh_rt: ecs.Relations_Table

    if ecs.init(&wh_db, CHURN_N, context.allocator) != nil do panic("walk_hierarchy db init failed")
    if ecs.relations_init(&wh_rt, &wh_db, CHURN_N) != nil do panic("walk_hierarchy relations init failed")
    bench_setup_forest(&wh_db, &wh_rt)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        entities, _, err := ecs.walk_hierarchy(&wh_db)
        time.stopwatch_stop(&sw)
        if err != nil do panic("walk_hierarchy failed")
        g_sink += f64(len(entities))
        best = min(best, elapsed_ns(&sw))
    }

    report("walk_hierarchy", best, CHURN_N)

    if ecs.terminate(&wh_db) != nil do panic("walk_hierarchy db terminate failed")
}

bench_roots :: proc() {
    r_db: ecs.Database
    r_rt: ecs.Relations_Table

    if ecs.init(&r_db, CHURN_N, context.allocator) != nil do panic("roots db init failed")
    if ecs.relations_init(&r_rt, &r_db, CHURN_N) != nil do panic("roots relations init failed")
    bench_setup_forest(&r_db, &r_rt)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        roots, err := ecs.roots(&r_db)
        time.stopwatch_stop(&sw)
        if err != nil do panic("roots failed")
        g_sink += f64(len(roots))
        best = min(best, elapsed_ns(&sw))
    }

    report("roots", best, CHURN_N)

    if ecs.terminate(&r_db) != nil do panic("roots db terminate failed")
}

PAIR_FANOUT :: 16
PAIR_HOLDERS :: CHURN_N / PAIR_FANOUT

bench_setup_pairs :: proc(db: ^ecs.Database, pt: ^ecs.Pair_Table(Pair_Data)) -> (holders: []ecs.entity_id) {
    holders = make([]ecs.entity_id, PAIR_HOLDERS)
    for i in 0..<PAIR_HOLDERS {
        h, err := ecs.create_entity(db)
        if err != nil do panic("create_entity failed")
        holders[i] = h
        for j in 0..<PAIR_FANOUT {
            t, terr := ecs.create_entity(db)
            if terr != nil do panic("create_entity failed")
            _, aerr := ecs.pair_add(pt, h, t, Pair_Data{ weight = f32(j) })
            if aerr != nil do panic("pair_add failed")
        }
    }
    return
}

bench_pair_first_target :: proc() {
    p_db: ecs.Database
    p_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&p_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("pair_first_target db init failed")
    if ecs.pair_init(&p_pt, &p_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("pair_first_target pair_init failed")
    holders := bench_setup_pairs(&p_db, &p_pt)
    defer delete(holders)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for h in holders {
            target, ok := ecs.pair_first_target(&p_pt, h)
            if ok do g_sink += f64(target.ix)
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    report("pair_first_target", best, PAIR_HOLDERS)

    if ecs.terminate(&p_db) != nil do panic("pair_first_target db terminate failed")
}

bench_pair_targets_of :: proc() {
    p_db: ecs.Database
    p_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&p_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("pair_targets_of db init failed")
    if ecs.pair_init(&p_pt, &p_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("pair_targets_of pair_init failed")
    holders := bench_setup_pairs(&p_db, &p_pt)
    defer delete(holders)

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for h in holders {
            targets, err := ecs.pair_targets_of(&p_pt, h)
            if err != nil do panic("pair_targets_of failed")
            g_sink += f64(len(targets))
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    report("pair_targets_of", best, PAIR_HOLDERS)

    if ecs.terminate(&p_db) != nil do panic("pair_targets_of db terminate failed")
}

bench_pair_churn :: proc() {
    c_db: ecs.Database
    c_pt: ecs.Pair_Table(Pair_Data)

    if ecs.init(&c_db, PAIR_HOLDERS * (PAIR_FANOUT + 1), context.allocator) != nil do panic("churn_pair db init failed")
    if ecs.pair_init(&c_pt, &c_db, holders_cap = PAIR_HOLDERS, pairs_cap = PAIR_HOLDERS * PAIR_FANOUT) != nil do panic("churn_pair pair_init failed")

    holders := make([]ecs.entity_id, PAIR_HOLDERS)
    defer delete(holders)
    targets := make([]ecs.entity_id, PAIR_HOLDERS * PAIR_FANOUT)
    defer delete(targets)

    for i in 0..<PAIR_HOLDERS {
        h, err := ecs.create_entity(&c_db)
        if err != nil do panic("create_entity failed")
        holders[i] = h
        for j in 0..<PAIR_FANOUT {
            t, terr := ecs.create_entity(&c_db)
            if terr != nil do panic("create_entity failed")
            targets[i * PAIR_FANOUT + j] = t
        }
    }

    sw: time.Stopwatch
    best: i64 = max(i64)

    for _ in 0..<REPS {
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)
        for i in 0..<PAIR_HOLDERS {
            h := holders[i]
            for j in 0..<PAIR_FANOUT {
                _, aerr := ecs.pair_add(&c_pt, h, targets[i * PAIR_FANOUT + j], Pair_Data{ weight = f32(j) })
                if aerr != nil do panic("pair_add failed")
            }
        }
        for h in holders {
            if ecs.pair_remove_all(&c_pt, h) != nil do panic("pair_remove_all failed")
        }
        time.stopwatch_stop(&sw)
        best = min(best, elapsed_ns(&sw))
    }

    g_sink += f64(ecs.pair_table__len(&c_pt))
    report("churn_pair", best, PAIR_HOLDERS * PAIR_FANOUT * 2)

    if ecs.terminate(&c_db) != nil do panic("churn_pair db terminate failed")
}
