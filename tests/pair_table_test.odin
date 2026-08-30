/*
    2026 (c) Zaya, https://github.com/zm69
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"
    import "core:slice"

// ODE
    import ecs "../src"
    import oc "../src/ode_core"

///////////////////////////////////////////////////////////////////////////////
// Pair_Table

    Likes_Data :: struct {
        strength: int,
    }

    @(test)
    pair_table__init__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=5, pairs_cap=8) == nil)
            testing.expect(t, ecs.is_valid(&pt))
            testing.expect(t, ecs.pair_table__len(&pt) == 0)
            testing.expect(t, ecs.pair_table__cap(&pt) == 8)
            testing.expect(t, ecs.pair_table__memory_usage(&pt) > 0)

            // A second, independent Pair_Table on the same Database is fine.
            pt2: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&pt2, &db, 5, 8) == nil)
            testing.expect(t, ecs.pair_table__terminate(&pt2) == nil)

            // Terminate + re-init on the same struct works (issue #8 convention)
            testing.expect(t, ecs.pair_table__terminate(&pt) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, 5, 8) == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 0)
    }

    @(test)
    pair_table__add_remove__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)
            e, _ := ecs.create_entity(&db)

            // a likes b (strength 5)
            row1, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=5})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_has_pair(&pt, a, b))
            testing.expect(t, ecs.pair_has_any(&pt, a))
            testing.expect(t, ecs.pair_table__len(&pt) == 1)

            // Re-adding the exact same pair is a no-op: same row, original data untouched.
            row1_again, err2 := ecs.pair_add(&pt, a, b, Likes_Data{strength=999})
            testing.expect(t, err2 == nil)
            testing.expect(t, row1_again == row1)
            testing.expect(t, ecs.pair_table__len(&pt) == 1)
            data, dok := ecs.pair_first_data(&pt, a)
            testing.expect(t, dok && data.strength == 5) // NOT overwritten to 999

            // a also likes c: many-to-many, one holder -> many targets.
            _, err = ecs.pair_add(&pt, a, c, Likes_Data{strength=1})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            targets, terr := ecs.pair_targets_of(&pt, a)
            testing.expect(t, terr == nil)
            testing.expect(t, len(targets) == 2)
            testing.expect(t, slice.contains(targets, b))
            testing.expect(t, slice.contains(targets, c))

            // d and e both like c: many-to-many, one target -> many holders.
            testing.expect(t, ecs.pair_has_any(&pt, d) == false)
            _, err = ecs.pair_add(&pt, d, c, Likes_Data{strength=2})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, e, c, Likes_Data{strength=3})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_has_any(&pt, d))
            testing.expect(t, ecs.pair_has_any(&pt, e))
            testing.expect(t, ecs.pair_table__len(&pt) == 4)

            // Removing one of a's two pairs keeps a's presence tag.
            testing.expect(t, ecs.pair_remove(&pt, a, b) == nil)
            testing.expect(t, !ecs.pair_has_pair(&pt, a, b))
            testing.expect(t, ecs.pair_has_any(&pt, a)) // still likes c
            testing.expect(t, ecs.pair_table__len(&pt) == 3)

            // Removing a's LAST pair drops its presence tag too.
            testing.expect(t, ecs.pair_remove(&pt, a, c) == nil)
            testing.expect(t, !ecs.pair_has_any(&pt, a))
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            // d/e -> c untouched by a's removals.
            testing.expect(t, ecs.pair_has_pair(&pt, d, c))
            testing.expect(t, ecs.pair_has_pair(&pt, e, c))

            // Removing a pair that doesn't exist (already removed, or never added).
            testing.expect(t, ecs.pair_remove(&pt, a, b) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.pair_remove(&pt, e, b) == oc.Core_Error.Not_Found)

            // remove_all
            testing.expect(t, ecs.pair_remove_all(&pt, d) == nil)
            testing.expect(t, !ecs.pair_has_any(&pt, d))
            testing.expect(t, ecs.pair_has_pair(&pt, e, c)) // e untouched
            testing.expect(t, ecs.pair_table__len(&pt) == 1)
            testing.expect(t, ecs.pair_remove_all(&pt, d) == nil) // no-op, not an error
    }

    @(test)
    pair_table__first_target__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)

            _, ok := ecs.pair_first_target(&pt, a)
            testing.expect(t, !ok) // no pairs yet

            _, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=1})
            testing.expect(t, err == nil)
            tgt, ok2 := ecs.pair_first_target(&pt, a)
            testing.expect(t, ok2 && tgt == b)

            // Most-recently-added among several (head-insert).
            _, err = ecs.pair_add(&pt, a, c, Likes_Data{strength=2})
            testing.expect(t, err == nil)
            tgt, ok2 = ecs.pair_first_target(&pt, a)
            testing.expect(t, ok2 && tgt == c)
    }

    @(test)
    pair_table__capacity__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            // holders_cap=10 (plenty), pairs_cap=2 (tight) -> pairs_cap exhausted first.
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=2) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            c, _ := ecs.create_entity(&db)
            d, _ := ecs.create_entity(&db)

            _, err := ecs.pair_add(&pt, a, b, Likes_Data{})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, a, c, Likes_Data{})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            // Third row exceeds pairs_cap -> fails cleanly, presence unaffected.
            _, err = ecs.pair_add(&pt, d, a, Likes_Data{})
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)
            testing.expect(t, !ecs.pair_has_any(&pt, d)) // no partial mutation

            // Separately: holders_cap exhaustion on a genuinely new holder.
            db2: ecs.Database
            pt2: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db2)
            defer ecs.pair_table__terminate(&pt2)

            testing.expect(t, ecs.init(&db2, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt2, &db2, holders_cap=1, pairs_cap=10) == nil)

            x, _ := ecs.create_entity(&db2)
            y, _ := ecs.create_entity(&db2)
            z, _ := ecs.create_entity(&db2)

            _, err = ecs.pair_add(&pt2, x, y, Likes_Data{})
            testing.expect(t, err == nil) // fills the one holder slot

            // y (a different, brand-new holder) needs a new presence slot -> full.
            _, err = ecs.pair_add(&pt2, y, z, Likes_Data{})
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs.pair_table__len(&pt2) == 1) // no partial row added

            // But adding another pair to the EXISTING holder x still works —
            // it doesn't need a new presence slot.
            _, err = ecs.pair_add(&pt2, x, z, Likes_Data{})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt2) == 2)
    }

    @(test)
    pair_table__target_destroy_cleaned_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db) // holder with a single target
            b, _ := ecs.create_entity(&db) // that target
            c, _ := ecs.create_entity(&db) // holder with two targets
            d, _ := ecs.create_entity(&db) // one of c's targets (destroyed)
            e, _ := ecs.create_entity(&db) // c's other target (survives)

            _, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=1})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, c, d, Likes_Data{strength=2})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, c, e, Likes_Data{strength=3})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 3)

            // b was a's ONLY target: destroying it must remove a's one pair row
            // AND drop a's presence tag.
            testing.expect(t, ecs.destroy_entity(&db, b) == nil)
            testing.expect(t, ecs.is_expired(&db, b))
            testing.expect(t, !ecs.pair_has_any(&pt, a))
            targets_a, terr_a := ecs.pair_targets_of(&pt, a)
            testing.expect(t, terr_a == nil)
            testing.expect(t, len(targets_a) == 0)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            testing.expect(t, ecs.destroy_entity(&db, d) == nil)
            testing.expect(t, ecs.is_expired(&db, d))
            testing.expect(t, ecs.pair_has_any(&pt, c))
            testing.expect(t, ecs.pair_has_pair(&pt, c, e))
            testing.expect(t, !ecs.pair_has_pair(&pt, c, d))
            targets_c, terr_c := ecs.pair_targets_of(&pt, c)
            testing.expect(t, terr_c == nil)
            testing.expect(t, len(targets_c) == 1)
            testing.expect(t, targets_c[0] == e)
            testing.expect(t, ecs.pair_table__len(&pt) == 1)
    }

    @(test)
    pair_table__holder_destroy_cleaned_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db) // holder, destroyed below
            b, _ := ecs.create_entity(&db) // a's target, survives

            _, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=1})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 1)
            testing.expect(t, ecs.pair_has_any(&pt, a))

            // Destroying the HOLDER must remove its own outgoing pair row and
            // presence tag, same as destroying a TARGET already does.
            testing.expect(t, ecs.destroy_entity(&db, a) == nil)
            testing.expect(t, ecs.is_expired(&db, a))
            testing.expect(t, ecs.pair_table__len(&pt) == 0)

            // The freed row must be reusable — recycling a's index for a
            // brand-new entity must NOT resurrect the destroyed holder's
            // stale pair data (classic ABA / index-reuse hazard).
            a2, _ := ecs.create_entity(&db)
            testing.expect(t, a2.ix == a.ix) // sanity: index really was recycled
            testing.expect(t, !ecs.pair_has_any(&pt, a2))
            targets_a2, terr := ecs.pair_targets_of(&pt, a2)
            testing.expect(t, terr == nil)
            testing.expect(t, len(targets_a2) == 0)
    }

    @(test)
    pair_table__self_pair_destroy_cleaned_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)

            // a is simultaneously holder AND target of the same row (self-pair) —
            // destroying it must not double-unlink/double-free that one row.
            _, err := ecs.pair_add(&pt, a, a, Likes_Data{strength=1})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, a, b, Likes_Data{strength=2})
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            testing.expect(t, ecs.destroy_entity(&db, a) == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 0)

            // b was never a holder or a target of anything else; untouched.
            testing.expect(t, !ecs.pair_has_any(&pt, b))
    }

    @(test)
    pair_table__holder_and_target_destroy_cleaned_up__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            pt: ecs.Pair_Table(Likes_Data)
            defer ecs.terminate(&db)
            defer ecs.pair_table__terminate(&pt)

            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db) // destroyed: holder of one row, target of another
            b, _ := ecs.create_entity(&db) // a's target, survives
            c, _ := ecs.create_entity(&db) // a's holder (c -> a), survives

            _, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=1}) // a holds -> b
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&pt, c, a, Likes_Data{strength=2}) // c holds -> a
            testing.expect(t, err == nil)
            testing.expect(t, ecs.pair_table__len(&pt) == 2)

            testing.expect(t, ecs.destroy_entity(&db, a) == nil)

            // Both of a's rows (as holder AND as target) must be gone.
            testing.expect(t, ecs.pair_table__len(&pt) == 0)
            testing.expect(t, !ecs.pair_has_any(&pt, b))
            testing.expect(t, !ecs.pair_has_any(&pt, c)) // c's only pair was -> a
    }

    @(test)
    pair_table__database_auto_terminate__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db: ecs.Database
            testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

            pt: ecs.Pair_Table(Likes_Data)
            testing.expect(t, ecs.pair_init(&pt, &db, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db)
            b, _ := ecs.create_entity(&db)
            _, err := ecs.pair_add(&pt, a, b, Likes_Data{strength=1})
            testing.expect(t, err == nil)

            // No explicit pair_table__terminate — database termination alone
            // must free it (and not double-free if it happens to run twice).
            testing.expect(t, ecs.terminate(&db) == nil)
            testing.expect(t, pt.state == ecs.Object_State.Not_Initialized)

            // Explicitly terminating an already-database-terminated Pair_Table
            // is a clean, expected no-op error, not a crash/double-free.
            testing.expect(t, ecs.pair_table__terminate(&pt) == ecs.API_Error.Object_Invalid)
    }

    // cmd_pair_add / cmd_pair_remove: recorded now, applied at replay.
    @(test)
    pair_table__serialization_round_trip__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()
        //
        // Test
        //
            db_a: ecs.Database
            likes_a: ecs.Pair_Table(Likes_Data)   // real payload
            blocks_a: ecs.Pair_Table(struct{})    // tag-only
            defer ecs.terminate(&db_a)
            defer ecs.pair_table__terminate(&likes_a)
            defer ecs.pair_table__terminate(&blocks_a)

            testing.expect(t, ecs.init(&db_a, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&likes_a, &db_a, holders_cap=10, pairs_cap=10) == nil)
            testing.expect(t, ecs.pair_init(&blocks_a, &db_a, holders_cap=10, pairs_cap=10) == nil)

            a, _ := ecs.create_entity(&db_a)
            b, _ := ecs.create_entity(&db_a)
            c, _ := ecs.create_entity(&db_a)
            d, _ := ecs.create_entity(&db_a)

            _, err := ecs.pair_add(&likes_a, a, b, Likes_Data{strength=5})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&likes_a, a, c, Likes_Data{strength=9})
            testing.expect(t, err == nil)
            _, err = ecs.pair_add(&blocks_a, b, d, struct{}{})
            testing.expect(t, err == nil)

            size, size_err := ecs.serialized_size(&db_a)
            testing.expect(t, size_err == nil)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            db_b: ecs.Database
            likes_b: ecs.Pair_Table(Likes_Data)
            blocks_b: ecs.Pair_Table(struct{})
            defer ecs.terminate(&db_b)
            defer ecs.pair_table__terminate(&likes_b)
            defer ecs.pair_table__terminate(&blocks_b)

            testing.expect(t, ecs.init(&db_b, entities_cap=10, allocator=allocator) == nil)
            testing.expect(t, ecs.pair_init(&likes_b, &db_b, holders_cap=10, pairs_cap=10) == nil)
            testing.expect(t, ecs.pair_init(&blocks_b, &db_b, holders_cap=10, pairs_cap=10) == nil)

            testing.expect(t, ecs.deserialize(&db_b, buf) == nil)

            testing.expect(t, ecs.pair_table__len(&likes_b) == 2)
            testing.expect(t, ecs.pair_has_pair(&likes_b, a, b))
            testing.expect(t, ecs.pair_has_pair(&likes_b, a, c))
            data_b, dok := ecs.pair_first_data(&likes_b, a)
            testing.expect(t, dok)
            testing.expect(t, data_b.strength == 5 || data_b.strength == 9) // either row (head-inserted, order unspecified)
            targets_b, terr := ecs.pair_targets_of(&likes_b, a)
            testing.expect(t, terr == nil)
            testing.expect(t, len(targets_b) == 2)
            testing.expect(t, slice.contains(targets_b, b))
            testing.expect(t, slice.contains(targets_b, c))

            testing.expect(t, ecs.pair_table__len(&blocks_b) == 1)
            testing.expect(t, ecs.pair_has_pair(&blocks_b, b, d))

            // presence tag survived the round trip.
            testing.expect(t, ecs.pair_has_any(&likes_b, a))
    }
