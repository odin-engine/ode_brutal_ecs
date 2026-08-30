/*
    2026 (c) Zaya, https://github.com/zm69

    Tests for binary snapshot serialization (serialization.odin).
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:slice"
    import "core:mem"
    import "core:os"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Components (Position and AI are defined in ecs_test.odin)

    Speed :: struct {
        value: f32,
    }

    Non_Pod :: struct {
        target: ^int,
        value: int,
    }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    Snapshot_World :: struct {
        db: ecs.Database,
        positions: ecs.Table,
        speeds: ecs.Table,
        ais: ecs.Table,
        relations: ecs.Relations_Table,
    }

    snapshot_world__init :: proc(t: ^testing.T, w: ^Snapshot_World, entities_cap: int, allocator: mem.Allocator) {
        testing.expect(t, ecs.init(&w.db, entities_cap = u32(entities_cap), allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&w.positions, &w.db, 20, {Position}) == nil)
        testing.expect(t, ecs.table__init(&w.speeds, &w.db, 20, {Speed}) == nil)
        testing.expect(t, ecs.table__init(&w.ais, &w.db, 20, {AI}) == nil)
        testing.expect(t, ecs.relations_table__init(&w.relations, &w.db, 10) == nil)
    }

    snapshot_world__terminate :: proc(w: ^Snapshot_World) {
        ecs.terminate(&w.db)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    serialization_round_trip__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            a: Snapshot_World
            b: Snapshot_World

        //
        // Test
        //
            defer snapshot_world__terminate(&a)
            defer snapshot_world__terminate(&b)

            snapshot_world__init(t, &a, 20, allocator)

            eids: [20]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 20; i += 1 {
                eids[i], err = ecs.create_entity(&a.db)
                testing.expect(t, err == nil)
            }

            // Components across all table kinds — each entity belongs to exactly one table.
            for i := 0; i < 8; i += 1 {
                testing.expect(t, ecs.table__add_entity(&a.positions, eids[i]) == nil)
                pos := ecs.get_component(&a.positions, eids[i], Position)
                pos^ = Position{ x = i, y = i * 10 }
            }
            for i := 8; i < 14; i += 1 {
                testing.expect(t, ecs.table__add_entity(&a.speeds, eids[i]) == nil)
                spd := ecs.get_component(&a.speeds, eids[i], Speed)
                spd.value = f32(i) * 0.5
            }
            for i := 14; i < 20; i += 1 {
                testing.expect(t, ecs.table__add_entity(&a.ais, eids[i]) == nil)
                ai := ecs.get_component(&a.ais, eids[i], AI)
                ai^ = AI{ IQ = f32(100 + i), neurons_count = i * 1000 }
            }

            // Relations: eids[0] parents eids[1] and eids[2]; eids[1] parents eids[3]
            testing.expect(t, ecs.set_parent(&a.db, eids[1], eids[0]) == nil)
            testing.expect(t, ecs.set_parent(&a.db, eids[2], eids[0]) == nil)
            testing.expect(t, ecs.set_parent(&a.db, eids[3], eids[1]) == nil)

            // Destroy a few entities so the factory freelist and generations round-trip
            testing.expect(t, ecs.destroy_entity(&a.db, eids[5]) == nil)
            testing.expect(t, ecs.destroy_entity(&a.db, eids[11]) == nil)
            testing.expect(t, ecs.destroy_entity(&a.db, eids[16]) == nil)

            //
            // Serialize A
            //
            size, size_err := ecs.serialized_size(&a.db)
            testing.expect(t, size_err == nil)
            testing.expect(t, size > 0)

            buf_a := make([]byte, size, allocator)
            defer delete(buf_a, allocator)

            written, werr := ecs.serialize(&a.db, buf_a)
            testing.expect(t, werr == nil)
            testing.expect(t, written == size)

            //
            // Deserialize into B (same schema, same init order)
            //
            snapshot_world__init(t, &b, 20, allocator)
            testing.expect(t, ecs.deserialize(&b.db, buf_a) == nil)

            testing.expect(t, ecs.entities_len(&b.db) == ecs.entities_len(&a.db))

            for i := 0; i < 20; i += 1 {
                eid := eids[i]
                expired_a := ecs.is_expired(&a.db, eid)
                expired_b := ecs.is_expired(&b.db, eid)
                testing.expect(t, expired_a == expired_b)
                if expired_a do continue

                pa := ecs.get_component(&a.positions, eid, Position)
                pb := ecs.get_component(&b.positions, eid, Position)
                testing.expect(t, (pa == nil) == (pb == nil))
                if pa != nil do testing.expect(t, pa^ == pb^)

                sa := ecs.get_component(&a.speeds, eid, Speed)
                sb := ecs.get_component(&b.speeds, eid, Speed)
                testing.expect(t, (sa == nil) == (sb == nil))
                if sa != nil do testing.expect(t, sa^ == sb^)

                aa := ecs.get_component(&a.ais, eid, AI)
                ab := ecs.get_component(&b.ais, eid, AI)
                testing.expect(t, (aa == nil) == (ab == nil))
                if aa != nil do testing.expect(t, aa^ == ab^)
            }

            // Relations
            for i := 0; i < 20; i += 1 {
                eid := eids[i]
                if ecs.is_expired(&a.db, eid) do continue

                parent_a, pa_err := ecs.parent_of(&a.db, eid)
                parent_b, pb_err := ecs.parent_of(&b.db, eid)
                testing.expect(t, pa_err == nil && pb_err == nil)
                testing.expect(t, parent_a == parent_b)

                count_a, _ := ecs.children_count(&a.db, eid)
                count_b, _ := ecs.children_count(&b.db, eid)
                testing.expect(t, count_a == count_b)
            }
            is_child, cerr := ecs.is_child_of(&b.db, eids[3], eids[1])
            testing.expect(t, cerr == nil && is_child)

            // Canonical form: serializing B again yields a byte-identical buffer
            size_b, size_b_err := ecs.serialized_size(&b.db)
            testing.expect(t, size_b_err == nil)
            testing.expect(t, size_b == size)

            buf_b := make([]byte, size_b, allocator)
            defer delete(buf_b, allocator)

            written_b, werr_b := ecs.serialize(&b.db, buf_b)
            testing.expect(t, werr_b == nil)
            testing.expect(t, written_b == written)
            testing.expect(t, slice.equal(buf_a, buf_b))
    }

    @(test)
    serialization_expired_ids__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db_a: ecs.Database
            db_b: ecs.Database
            positions_a: ecs.Table
            positions_b: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db_a)
            defer ecs.terminate(&db_b)

            testing.expect(t, ecs.init(&db_a, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions_a, &db_a, 10, {Position}) == nil)

            eids: [5]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 5; i += 1 {
                eids[i], err = ecs.create_entity(&db_a)
                testing.expect(t, err == nil)
            }
            testing.expect(t, ecs.destroy_entity(&db_a, eids[2]) == nil)

            size, _ := ecs.serialized_size(&db_a)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            testing.expect(t, ecs.init(&db_b, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions_b, &db_b, 10, {Position}) == nil)
            testing.expect(t, ecs.deserialize(&db_b, buf) == nil)

            // The destroyed id is expired in B, live ids are not
            testing.expect(t, ecs.is_expired(&db_b, eids[2]))
            testing.expect(t, !ecs.is_expired(&db_b, eids[0]))
            testing.expect(t, !ecs.is_expired(&db_b, eids[4]))

            // Creating a new entity behaves identically in A and B:
            // same recycled index, same bumped generation
            new_a, aerr := ecs.create_entity(&db_a)
            new_b, berr := ecs.create_entity(&db_b)
            testing.expect(t, aerr == nil && berr == nil)
            testing.expect(t, new_a == new_b)
            testing.expect(t, new_b.ix == eids[2].ix)
            testing.expect(t, new_b.gen == eids[2].gen + 1)
    }

    @(test)
    serialization_capacity_and_schema__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db_a: ecs.Database
            positions_a: ecs.Table
            ais_a: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db_a)

            testing.expect(t, ecs.init(&db_a, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions_a, &db_a, 10, {Position}) == nil)
            testing.expect(t, ecs.table__init(&ais_a, &db_a, 10, {AI}) == nil)

            eids: [6]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 6; i += 1 {
                eids[i], err = ecs.create_entity(&db_a)
                testing.expect(t, err == nil)
                testing.expect(t, ecs.table__add_entity(&positions_a, eids[i]) == nil)
            }

            size, _ := ecs.serialized_size(&db_a)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db_a, buf)
            testing.expect(t, serr == nil)

            // entities_cap too small
            {
                db: ecs.Database
                positions: ecs.Table
                ais: ecs.Table
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 5, allocator = allocator) == nil)
                testing.expect(t, ecs.table__init(&positions, &db, 5, {Position}) == nil)
                testing.expect(t, ecs.table__init(&ais, &db, 5, {AI}) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // table cap smaller than saved row count
            {
                db: ecs.Database
                positions: ecs.Table
                ais: ecs.Table
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table__init(&positions, &db, 3, {Position}) == nil) // 3 < 6 saved rows
                testing.expect(t, ecs.table__init(&ais, &db, 10, {AI}) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // larger entities_cap loads fine and stays usable
            {
                db: ecs.Database
                positions: ecs.Table
                ais: ecs.Table
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 30, allocator = allocator) == nil)
                testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
                testing.expect(t, ecs.table__init(&ais, &db, 10, {AI}) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == nil)
                testing.expect(t, ecs.entities_len(&db) == 6)
                testing.expect(t, ecs.table_len(&positions) == 6)

                new_eid, neerr := ecs.create_entity(&db)
                testing.expect(t, neerr == nil)
                testing.expect(t, new_eid.ix == 6) // continues after the loaded entities
            }

            // wrong component type at the same id (name/size differ)
            {
                db: ecs.Database
                positions: ecs.Table
                ais: ecs.Table
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
                testing.expect(t, ecs.table__init(&ais, &db, 10, {Speed}) == nil) // Speed, not AI
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
            }

            // missing table (table count differs)
            {
                db: ecs.Database
                positions: ecs.Table
                defer ecs.terminate(&db)

                testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
                testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
                testing.expect(t, ecs.deserialize(&db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
            }
    }

    @(test)
    serialization_robustness__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__add_entity(&positions, eid) == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            // buffer too small for serialize
            {
                small := make([]byte, size - 1, allocator)
                defer delete(small, allocator)
                _, e := ecs.serialize(&db, small)
                testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)
            }

            // serialize refused while packing is paused
            {
                ecs.pause_packing(&db)
                _, e := ecs.serialize(&db, buf)
                testing.expect(t, e == ecs.API_Error.Cannot_Serialize_While_Packing_Paused)
                testing.expect(t, ecs.resume_packing(&db) == nil)
            }

            // truncated buffer
            testing.expect(t, ecs.deserialize(&db, buf[:len(buf) - 10]) == ecs.API_Error.Snapshot_Invalid)

            // trailing garbage
            {
                bigger := make([]byte, size + 8, allocator)
                defer delete(bigger, allocator)
                copy(bigger, buf)
                testing.expect(t, ecs.deserialize(&db, bigger) == ecs.API_Error.Snapshot_Invalid)
            }

            // bad magic
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[0] ~= 0xFF
                testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            }

            // wrong version (version is the u32 right after the u64 magic)
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[8] = 0xFF
                testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Version_Mismatch)
            }

            // missing file
            testing.expect(t, ecs.load_from_file(&db, "does_not_exist.snap", allocator) == ecs.API_Error.File_Error)

            // the original buffer still loads fine after all the failed attempts
            testing.expect(t, ecs.deserialize(&db, buf) == nil)
            testing.expect(t, ecs.entities_len(&db) == 1)
    }

    @(test)
    serialization_old_version_rejected__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table
        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__add_entity(&positions, eid) == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            v1 := make([]byte, size, allocator)
            defer delete(v1, allocator)
            copy(v1, buf)
            v1[8] = 1

            testing.expect(t, ecs.deserialize(&db, v1) == ecs.API_Error.Snapshot_Version_Mismatch)
    }

    @(test)
    serialization_non_pod__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            non_pods: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&non_pods, &db, 10, {Non_Pod}) == nil)

            eid, err := ecs.create_entity(&db)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table__add_entity(&non_pods, eid) == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)

            // a component with a pointer field is rejected...
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == ecs.API_Error.Snapshot_Component_Not_POD)

            // ...unless explicitly allowed
            written, serr2 := ecs.serialize(&db, buf, allow_non_pod = true)
            testing.expect(t, serr2 == nil)
            testing.expect(t, written == size)
    }

    @(test)
    serialization_in_place_restore__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&db)
                testing.expect(t, err == nil)
                testing.expect(t, ecs.table__add_entity(&positions, eids[i]) == nil)
                pos := ecs.get_component(&positions, eids[i], Position)
                pos^ = Position{ x = 100 + i, y = 0 }
            }

            // Save
            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            // Mutate: destroy an entity, change a component
            testing.expect(t, ecs.destroy_entity(&db, eids[1]) == nil)
            pos0 := ecs.get_component(&positions, eids[0], Position)
            pos0.x = 9999

            // Restore the snapshot into the SAME database
            testing.expect(t, ecs.deserialize(&db, buf) == nil)

            testing.expect(t, ecs.entities_len(&db) == 3)
            testing.expect(t, !ecs.is_expired(&db, eids[1])) // alive again

            pos0 = ecs.get_component(&positions, eids[0], Position)
            testing.expect(t, pos0 != nil && pos0.x == 100) // value restored

            pos1 := ecs.get_component(&positions, eids[1], Position)
            testing.expect(t, pos1 != nil && pos1.x == 101)
    }

    @(test)
    serialization_malformed_snapshot__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ENTITIES_CAP :: 8

            db: ecs.Database
            positions: ecs.Table
            relations: ecs.Relations_Table

        //
        // Build a small world: p is parent of c1 and c2; a and b are loose
        //
            defer ecs.terminate(&db)

            testing.expect(t, ecs.init(&db, entities_cap = ENTITIES_CAP, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&positions, &db, ENTITIES_CAP, {Position}) == nil)
            testing.expect(t, ecs.relations_table__init(&relations, &db, ENTITIES_CAP) == nil)

            err: ecs.Error
            p, c1, c2, a, b: ecs.entity_id
            p, err  = ecs.create_entity(&db); testing.expect(t, err == nil)
            c1, err = ecs.create_entity(&db); testing.expect(t, err == nil)
            c2, err = ecs.create_entity(&db); testing.expect(t, err == nil)
            a, err  = ecs.create_entity(&db); testing.expect(t, err == nil)
            b, err  = ecs.create_entity(&db); testing.expect(t, err == nil)

            testing.expect(t, ecs.table__add_entity(&positions, p) == nil)
            testing.expect(t, ecs.table__add_entity(&positions, c1) == nil)

            testing.expect(t, ecs.set_parent(&db, parent = p, child = c1) == nil)
            testing.expect(t, ecs.set_parent(&db, parent = p, child = c2) == nil)

            size, _ := ecs.serialized_size(&db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&db, buf)
            testing.expect(t, serr == nil)

            cc_padded := (ENTITIES_CAP * 4 + 7) &~ 7
            rel_start := len(buf) - (16 + 4 * ENTITIES_CAP * 8 + cc_padded)
            parent_off := rel_start + 16
            fc_off := parent_off + ENTITIES_CAP * 8
            ns_off := fc_off + ENTITIES_CAP * 8
            ps_off := ns_off + ENTITIES_CAP * 8
            cc_off := ps_off + ENTITIES_CAP * 8

            rel_arrays :: proc(buf: []byte, off: int) -> []ecs.entity_id {
                return slice.reinterpret([]ecs.entity_id, buf[off:][:ENTITIES_CAP * size_of(ecs.entity_id)])
            }
            rel_cc :: proc(buf: []byte, off: int) -> []i32 {
                return slice.reinterpret([]i32, buf[off:][:ENTITIES_CAP * size_of(i32)])
            }

            // the DB must come through every failed load untouched
            verify_intact :: proc(t: ^testing.T, db: ^ecs.Database, positions: ^ecs.Table, p: ecs.entity_id) {
                testing.expect(t, ecs.entities_len(db) == 5)
                testing.expect(t, ecs.table_len(positions) == 2)
                kids, kerr := ecs.children_of(db, p)
                testing.expect(t, kerr == nil && len(kids) == 2)
            }

            corrupt := make([]byte, size, allocator)
            defer delete(corrupt, allocator)

            copy(corrupt, buf)
            rel_arrays(corrupt, ns_off)[c1.ix] = c2
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // Case 2: prev/next mutual-inverse violation (self prev link)
        //
            copy(corrupt, buf)
            rel_arrays(corrupt, ps_off)[c2.ix] = c2
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // Case 3: a child's parent[] disagrees with the list it sits in
        //
            copy(corrupt, buf)
            rel_arrays(corrupt, parent_off)[c1.ix] = c2
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // Case 4: children_count doesn't match the actual list length
        //
            copy(corrupt, buf)
            rel_cc(corrupt, cc_off)[p.ix] = 5
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // Case 5: header count doesn't match the actual number of links
        // (pass 2 would install it as rt.count unverified)
        //
            copy(corrupt, buf)
            (slice.reinterpret([]i64, corrupt[rel_start:][:16]))[1] = 3 // rh.count
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // Case 6: a never-created (dead) slot carries a link
        //
            copy(corrupt, buf)
            rel_arrays(corrupt, parent_off)[ENTITIES_CAP - 1] = p
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

            copy(corrupt, buf)
            rel_arrays(corrupt, parent_off)[a.ix] = b
            rel_arrays(corrupt, parent_off)[b.ix] = a
            rel_arrays(corrupt, fc_off)[a.ix] = b
            rel_arrays(corrupt, fc_off)[b.ix] = a
            rel_cc(corrupt, cc_off)[a.ix] = 1
            rel_cc(corrupt, cc_off)[b.ix] = 1
            (slice.reinterpret([]i64, corrupt[rel_start:][:16]))[1] = 4 // rh.count: 2 old + 2 new links
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

            copy(corrupt, buf)
            section_off := 64 + ENTITIES_CAP * 8 // Snapshot_Header + entity-id section, both 8-byte aligned already
            cih_off := section_off + 32 // Snap_Table_Header is 32 bytes (table_id, cap, len, column_count)
            name_len := (slice.reinterpret([]i64, corrupt[cih_off:][:24]))[2] // Snap_Table_Column_Header.name_len field
            eids_off := cih_off + 24 + int((name_len + 7) &~ 7)
            section_eids := slice.reinterpret([]ecs.entity_id, corrupt[eids_off:][:2 * size_of(ecs.entity_id)])
            testing.expect(t, section_eids[0] == p && section_eids[1] == c1) // layout sanity
            section_eids[1] = p
            testing.expect(t, ecs.deserialize(&db, corrupt) == ecs.API_Error.Snapshot_Invalid)
            verify_intact(t, &db, &positions, p)

        //
        // The untouched original still loads fine after all rejections
        //
            testing.expect(t, ecs.deserialize(&db, buf) == nil)
            verify_intact(t, &db, &positions, p)
    }

    // save_to_file → load_from_file round trip through an actual file on disk
    // (the in-memory buffer path is covered by serialization_round_trip__test).
    @(test)
    serialization_save_load_file__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            a: Snapshot_World
            b: Snapshot_World

        //
        // Test
        //
            defer snapshot_world__terminate(&a)
            defer snapshot_world__terminate(&b)

            snapshot_world__init(t, &a, 20, allocator)

            eids: [10]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 10; i += 1 {
                eids[i], err = ecs.create_entity(&a.db)
                testing.expect(t, err == nil)
            }
            for i := 0; i < 6; i += 1 {
                testing.expect(t, ecs.table__add_entity(&a.positions, eids[i]) == nil)
                pos := ecs.get_component(&a.positions, eids[i], Position)
                pos^ = Position{ x = i, y = -i }
            }
            for i := 6; i < 10; i += 1 {
                testing.expect(t, ecs.table__add_entity(&a.speeds, eids[i]) == nil)
                spd := ecs.get_component(&a.speeds, eids[i], Speed)
                spd.value = f32(i)
            }
            testing.expect(t, ecs.set_parent(&a.db, eids[1], eids[0]) == nil)

            // cwd-relative: works both from tests/ (odin test .) and tests/out/
            // (the ECS Tests task); *.snap is gitignored and removed below
            path :: "save_load_round_trip.snap"
            defer os.remove(path)

            testing.expect(t, ecs.save_to_file(&a.db, path, allocator) == nil)

            // Load into a fresh database with the same schema
            snapshot_world__init(t, &b, 20, allocator)
            testing.expect(t, ecs.load_from_file(&b.db, path, allocator) == nil)

            testing.expect(t, ecs.entities_len(&b.db) == ecs.entities_len(&a.db))
            for i := 0; i < 10; i += 1 {
                pa := ecs.get_component(&a.positions, eids[i], Position)
                pb := ecs.get_component(&b.positions, eids[i], Position)
                testing.expect(t, (pa == nil) == (pb == nil))
                if pa != nil && pb != nil do testing.expect(t, pa^ == pb^)

                sa := ecs.get_component(&a.speeds, eids[i], Speed)
                sb := ecs.get_component(&b.speeds, eids[i], Speed)
                testing.expect(t, (sa == nil) == (sb == nil))
                if sa != nil && sb != nil do testing.expect(t, sa^ == sb^)
            }
            is_child, cerr := ecs.is_child_of(&b.db, eids[1], eids[0])
            testing.expect(t, cerr == nil && is_child)
    }
