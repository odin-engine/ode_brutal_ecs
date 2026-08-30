/*
    2026 (c) Zaya, https://github.com/zm69
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

///////////////////////////////////////////////////////////////////////////////
// Overbase-only round trip

    @(test)
    overbase_serialize_standalone__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator() // no allocations outside provided allocator

            ob: ecs.Overbase
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, allocator = allocator) == nil)

            eids: [5]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 5; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
            }
            testing.expect(t, ecs.destroy_entity(&ob, eids[2]) == nil)

            size, size_err := ecs.overbase_serialized_size(&ob)
            testing.expect(t, size_err == nil)
            testing.expect(t, size > 0)

            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)

            written, werr := ecs.overbase_serialize(&ob, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, written == size)

            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == eids[2].ix)
            testing.expect(t, ecs.destroy_entity(&ob, eids[0]) == nil)

            testing.expect(t, ecs.overbase_deserialize(&ob, buf) == nil)

            testing.expect(t, ecs.entities_len(&ob) == 4)
            testing.expect(t, ecs.is_expired(&ob, eids[2])) // destroyed before the snapshot, still gone
            testing.expect(t, !ecs.is_expired(&ob, eids[0])) // destroyed only after the snapshot -> alive again
            testing.expect(t, !ecs.is_expired(&ob, eids[1]))
            testing.expect(t, !ecs.is_expired(&ob, eids[3]))
            testing.expect(t, !ecs.is_expired(&ob, eids[4]))
            testing.expect(t, ecs.is_expired(&ob, new_eid)) // created only after the snapshot -> rolled back

            new_eid_2, nerr2 := ecs.create_entity(&ob)
            testing.expect(t, nerr2 == nil)
            testing.expect(t, new_eid_2 == new_eid)
    }

    @(test)
    overbase_serialize_robustness__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, allocator = allocator) == nil)

            _, err := ecs.create_entity(&ob)
            testing.expect(t, err == nil)

            size, _ := ecs.overbase_serialized_size(&ob)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.overbase_serialize(&ob, buf)
            testing.expect(t, serr == nil)

            // buffer too small for serialize
            {
                small := make([]byte, size - 1, allocator)
                defer delete(small, allocator)
                _, e := ecs.overbase_serialize(&ob, small)
                testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)
            }

            // truncated buffer
            testing.expect(t, ecs.overbase_deserialize(&ob, buf[:len(buf) - 10]) == ecs.API_Error.Snapshot_Invalid)

            // trailing garbage
            {
                bigger := make([]byte, size + 8, allocator)
                defer delete(bigger, allocator)
                copy(bigger, buf)
                testing.expect(t, ecs.overbase_deserialize(&ob, bigger) == ecs.API_Error.Snapshot_Invalid)
            }

            // bad magic
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[0] ~= 0xFF
                testing.expect(t, ecs.overbase_deserialize(&ob, corrupt) == ecs.API_Error.Snapshot_Invalid)
            }

            // wrong version (version is the u32 right after the u64 magic)
            {
                corrupt := make([]byte, size, allocator)
                defer delete(corrupt, allocator)
                copy(corrupt, buf)
                corrupt[8] = 0xFF
                testing.expect(t, ecs.overbase_deserialize(&ob, corrupt) == ecs.API_Error.Snapshot_Version_Mismatch)
            }

            // capacity too small
            {
                small_ob: ecs.Overbase
                defer ecs.overbase_terminate(&small_ob)
                testing.expect(t, ecs.overbase_init(&small_ob, entities_cap = 1, allocator = allocator) == nil)
                testing.expect(t, ecs.overbase_deserialize(&small_ob, buf) == ecs.API_Error.Snapshot_Capacity_Too_Small)
            }

            // missing file
            testing.expect(t, ecs.overbase_load_from_file(&ob, "does_not_exist_overbase.snap", allocator) == ecs.API_Error.File_Error)

            // the original buffer still loads fine after all the failed attempts
            testing.expect(t, ecs.overbase_deserialize(&ob, buf) == nil)
            testing.expect(t, ecs.entities_len(&ob) == 1)
    }

///////////////////////////////////////////////////////////////////////////////
// Database serialize/deserialize on a SHARED Overbase never touches the
// shared id-space — the fix for docs/overbase.md's old "Serialization caveat"

    @(test)
    overbase_deserialize_shared_never_touches_id_space__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table
            sprites: ecs.Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&positions, &world_db, 10, {Ob_Position}) == nil)
            testing.expect(t, ecs.table__init(&sprites, &render_db, 10, {Ob_Sprite}) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
                perr := ecs.table__add_entity(&positions, eids[i])
                testing.expect(t, perr == nil)
                ecs.get_component(&positions, eids[i], Ob_Position)^ = Ob_Position{ x = i, y = 0 }
                serr := ecs.table__add_entity(&sprites, eids[i])
                testing.expect(t, serr == nil)
            }

            size, size_err := ecs.serialized_size(&world_db)
            testing.expect(t, size_err == nil)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, werr := ecs.serialize(&world_db, buf)
            testing.expect(t, werr == nil)

            testing.expect(t, ecs.destroy_entity(&world_db, eids[1]) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == eids[1].ix) // LIFO reuse
            nsprerr := ecs.table__add_entity(&sprites, new_eid)
            testing.expect(t, nsprerr == nil)
            testing.expect(t, ecs.entities_len(&render_db) == 3) // eids[0], eids[2], new_eid

            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            testing.expect(t, ecs.entities_len(&render_db) == 3)
            testing.expect(t, ecs.is_expired(&render_db, eids[1]))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
            testing.expect(t, ecs.get_component(&positions, eids[0], Ob_Position).x == 0)

            // Fresh snapshot of world_db's current state (only eids[0]/eids[2]), then mutate again.
            size2, _ := ecs.serialized_size(&world_db)
            buf2 := make([]byte, size2, allocator)
            defer delete(buf2, allocator)
            _, werr2 := ecs.serialize(&world_db, buf2)
            testing.expect(t, werr2 == nil)

            pos0 := ecs.get_component(&positions, eids[0], Ob_Position)
            pos0.x = 9999

            testing.expect(t, ecs.deserialize(&world_db, buf2) == nil)
            testing.expect(t, ecs.get_component(&positions, eids[0], Ob_Position).x == 0)
            testing.expect(t, ecs.entities_len(&render_db) == 3)
            testing.expect(t, ecs.is_expired(&render_db, eids[1]))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
            testing.expect(t, ecs.has_component(&sprites, new_eid))
    }

    @(test)
    overbase_serialize_with_attached_databases__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table
            sprites: ecs.Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&positions, &world_db, 10, {Ob_Position}) == nil)
            testing.expect(t, ecs.table__init(&sprites, &render_db, 10, {Ob_Sprite}) == nil)

            eids: [3]ecs.entity_id
            err: ecs.Error
            for i := 0; i < 3; i += 1 {
                eids[i], err = ecs.create_entity(&ob)
                testing.expect(t, err == nil)
                perr := ecs.table__add_entity(&positions, eids[i])
                testing.expect(t, perr == nil)
                ecs.get_component(&positions, eids[i], Ob_Position)^ = Ob_Position{ x = 100 + i, y = 0 }
                serr := ecs.table__add_entity(&sprites, eids[i])
                testing.expect(t, serr == nil)
                ecs.get_component(&sprites, eids[i], Ob_Sprite).texture_id = 200 + i
            }

            // Save all three pieces.
            ob_size, _ := ecs.overbase_serialized_size(&ob)
            buf_ob := make([]byte, ob_size, allocator)
            defer delete(buf_ob, allocator)
            _, ob_err := ecs.overbase_serialize(&ob, buf_ob)
            testing.expect(t, ob_err == nil)

            world_size, _ := ecs.serialized_size(&world_db)
            buf_world := make([]byte, world_size, allocator)
            defer delete(buf_world, allocator)
            _, world_err := ecs.serialize(&world_db, buf_world)
            testing.expect(t, world_err == nil)

            render_size, _ := ecs.serialized_size(&render_db)
            buf_render := make([]byte, render_size, allocator)
            defer delete(buf_render, allocator)
            _, render_err := ecs.serialize(&render_db, buf_render)
            testing.expect(t, render_err == nil)

            testing.expect(t, ecs.destroy_entity(&world_db, eids[1]) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            perr := ecs.table__add_entity(&positions, new_eid)
            testing.expect(t, perr == nil)
            serr := ecs.table__add_entity(&sprites, new_eid)
            testing.expect(t, serr == nil)
            ecs.get_component(&positions, eids[0], Ob_Position).x = -1
            ecs.get_component(&sprites, eids[0], Ob_Sprite).texture_id = -1

            testing.expect(t, ecs.overbase_deserialize(&ob, buf_ob) == nil)
            testing.expect(t, ecs.deserialize(&world_db, buf_world) == nil)
            testing.expect(t, ecs.deserialize(&render_db, buf_render) == nil)

            testing.expect(t, ecs.entities_len(&ob) == 3)
            for i := 0; i < 3; i += 1 {
                testing.expect(t, !ecs.is_expired(&ob, eids[i]))
                testing.expect(t, ecs.get_component(&positions, eids[i], Ob_Position).x == 100 + i)
                testing.expect(t, ecs.get_component(&sprites, eids[i], Ob_Sprite).texture_id == 200 + i)
            }
            testing.expect(t, ecs.is_expired(&ob, new_eid)) // rolled back away
    }

///////////////////////////////////////////////////////////////////////////////
// Reconnecting a standalone-serialized Database (own private Overbase) into a
// freshly restored shared Overbase.

    @(test)
    overbase_reconnect_previously_standalone_database__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            standalone_db: ecs.Database
            standalone_positions: ecs.Table
        //
        // Test
        //
            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&standalone_positions, &standalone_db, 10, {Ob_Position}) == nil)

            e0, e0_err := ecs.create_entity(&standalone_db)
            testing.expect(t, e0_err == nil)
            e1, e1_err := ecs.create_entity(&standalone_db)
            testing.expect(t, e1_err == nil)

            p0err := ecs.table__add_entity(&standalone_positions, e0)
            testing.expect(t, p0err == nil)
            ecs.get_component(&standalone_positions, e0, Ob_Position)^ = Ob_Position{ x = 7, y = 0 }
            p1err := ecs.table__add_entity(&standalone_positions, e1)
            testing.expect(t, p1err == nil)
            ecs.get_component(&standalone_positions, e1, Ob_Position)^ = Ob_Position{ x = 8, y = 0 }

            standalone_size, _ := ecs.serialized_size(&standalone_db)
            buf_standalone := make([]byte, standalone_size, allocator)
            defer delete(buf_standalone, allocator)
            _, sderr := ecs.serialize(&standalone_db, buf_standalone)
            testing.expect(t, sderr == nil)

            ecs.terminate(&standalone_db) // done with it — only its bytes matter now

            ob_source: ecs.Overbase
            testing.expect(t, ecs.overbase_init(&ob_source, entities_cap = 10, allocator = allocator) == nil)
            src_e0, src_e0_err := ecs.create_entity(&ob_source)
            testing.expect(t, src_e0_err == nil)
            src_e1, src_e1_err := ecs.create_entity(&ob_source)
            testing.expect(t, src_e1_err == nil)
            testing.expect(t, src_e0 == e0 && src_e1 == e1)

            ob_size, _ := ecs.overbase_serialized_size(&ob_source)
            buf_ob := make([]byte, ob_size, allocator)
            defer delete(buf_ob, allocator)
            _, oberr := ecs.overbase_serialize(&ob_source, buf_ob)
            testing.expect(t, oberr == nil)
            ecs.overbase_terminate(&ob_source)

            ob2: ecs.Overbase
            defer ecs.overbase_terminate(&ob2)
            testing.expect(t, ecs.overbase_init(&ob2, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.overbase_deserialize(&ob2, buf_ob) == nil)

            db2: ecs.Database
            defer ecs.terminate(&db2)
            testing.expect(t, ecs.init_from_overbase(&db2, &ob2) == nil)

            positions2: ecs.Table
            testing.expect(t, ecs.table__init(&positions2, &db2, 10, {Ob_Position}) == nil)

            entities_len_before := ecs.entities_len(&ob2)

            testing.expect(t, ecs.deserialize(&db2, buf_standalone) == nil)

            testing.expect(t, ecs.get_component(&positions2, e0, Ob_Position).x == 7)
            testing.expect(t, ecs.get_component(&positions2, e1, Ob_Position).x == 8)

            testing.expect(t, ecs.entities_len(&ob2) == entities_len_before) // ob2's id-space untouched
    }

///////////////////////////////////////////////////////////////////////////////
// Relations_Table and a second Table on a shared-Overbase Database — separate
// row/link validation branches from the named-component case above.

    @(test)
    overbase_deserialize_shared_relations__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            positions: ecs.Table
            rt: ecs.Relations_Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&positions, &world_db, 10, {Ob_Position}) == nil)
            testing.expect(t, ecs.relations_table__init(&rt, &world_db, 10) == nil)

            parent, perr := ecs.create_entity(&ob)
            testing.expect(t, perr == nil)
            child, cerr := ecs.create_entity(&ob)
            testing.expect(t, cerr == nil)

            pperr := ecs.table__add_entity(&positions, parent)
            testing.expect(t, pperr == nil)
            pos_p := ecs.get_component(&positions, parent, Ob_Position)
            pos_p^ = Ob_Position{ x = 1, y = 0 }
            pcerr := ecs.table__add_entity(&positions, child)
            testing.expect(t, pcerr == nil)

            testing.expect(t, ecs.set_parent(&world_db, child, parent) == nil)

            size, _ := ecs.serialized_size(&world_db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&world_db, buf)
            testing.expect(t, serr == nil)

            pos_p.x = -1
            testing.expect(t, ecs.deserialize(&world_db, buf) == nil)

            testing.expect(t, ecs.get_component(&positions, parent, Ob_Position).x == 1)
            is_child, icerr := ecs.is_child_of(&world_db, child, parent)
            testing.expect(t, icerr == nil && is_child)
            testing.expect(t, ecs.entities_len(&render_db) == 2)
            testing.expect(t, !ecs.is_expired(&render_db, parent))
            testing.expect(t, !ecs.is_expired(&render_db, child))

            testing.expect(t, ecs.destroy_entity(&world_db, child) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == child.ix) // LIFO reuse

            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            testing.expect(t, ecs.entities_len(&render_db) == 2) // parent, new_eid
            testing.expect(t, ecs.is_expired(&render_db, child))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))
    }

    @(test)
    overbase_deserialize_shared_second_table__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            render_db: ecs.Database
            is_alive: ecs.Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&render_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 2, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.init_from_overbase(&render_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&is_alive, &world_db, 10, {Ob_Sprite}) == nil)

            e0, e0err := ecs.create_entity(&ob)
            testing.expect(t, e0err == nil)
            e1, e1err := ecs.create_entity(&ob)
            testing.expect(t, e1err == nil)

            testing.expect(t, ecs.table__add_entity(&is_alive, e0) == nil)
            testing.expect(t, ecs.table__add_entity(&is_alive, e1) == nil)

            size, _ := ecs.serialized_size(&world_db)
            buf := make([]byte, size, allocator)
            defer delete(buf, allocator)
            _, serr := ecs.serialize(&world_db, buf)
            testing.expect(t, serr == nil)

            //
            // (a) Happy path
            //
            testing.expect(t, ecs.deserialize(&world_db, buf) == nil)
            testing.expect(t, ecs.table_len(&is_alive) == 2)
            testing.expect(t, ecs.has_component(&is_alive, e0))
            testing.expect(t, ecs.has_component(&is_alive, e1))
            testing.expect(t, ecs.entities_len(&render_db) == 2)

            testing.expect(t, ecs.destroy_entity(&world_db, e1) == nil)
            new_eid, nerr := ecs.create_entity(&ob)
            testing.expect(t, nerr == nil)
            testing.expect(t, new_eid.ix == e1.ix) // LIFO reuse

            derr := ecs.deserialize(&world_db, buf)
            testing.expect(t, derr == ecs.API_Error.Snapshot_Invalid)

            testing.expect(t, ecs.entities_len(&render_db) == 2) // e0, new_eid
            testing.expect(t, ecs.is_expired(&render_db, e1))
            testing.expect(t, !ecs.is_expired(&render_db, new_eid))

            testing.expect(t, ecs.has_component(&is_alive, e1) == false)
    }

///////////////////////////////////////////////////////////////////////////////
// serialized_size/serialize buffer-sizing for a shared Database — the branch that
// omits the id-section cost.

    @(test)
    overbase_shared_database_serialize_buffer_too_small__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ob: ecs.Overbase
            world_db: ecs.Database
            positions: ecs.Table

            standalone_db: ecs.Database
            standalone_positions: ecs.Table
        //
        // Test
        //
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)
            defer ecs.terminate(&standalone_db)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&positions, &world_db, 10, {Ob_Position}) == nil)

            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&standalone_positions, &standalone_db, 10, {Ob_Position}) == nil)

            // Same schema, same data, on both.
            for i := 0; i < 3; i += 1 {
                eid, err := ecs.create_entity(&world_db)
                testing.expect(t, err == nil)
                perr := ecs.table__add_entity(&positions, eid)
                testing.expect(t, perr == nil)
                ecs.get_component(&positions, eid, Ob_Position)^ = Ob_Position{ x = i, y = 0 }

                seid, serr2 := ecs.create_entity(&standalone_db)
                testing.expect(t, serr2 == nil)
                sperr := ecs.table__add_entity(&standalone_positions, seid)
                testing.expect(t, sperr == nil)
                ecs.get_component(&standalone_positions, seid, Ob_Position)^ = Ob_Position{ x = i, y = 0 }
            }

            shared_size, shared_size_err := ecs.serialized_size(&world_db)
            testing.expect(t, shared_size_err == nil)
            standalone_size, standalone_size_err := ecs.serialized_size(&standalone_db)
            testing.expect(t, standalone_size_err == nil)

            testing.expect(t, shared_size < standalone_size) // id-section genuinely omitted, not just ignored on read

            small := make([]byte, shared_size - 1, allocator)
            defer delete(small, allocator)
            _, e := ecs.serialize(&world_db, small)
            testing.expect(t, e == ecs.API_Error.Serialize_Buffer_Too_Small)

            buf := make([]byte, shared_size, allocator)
            defer delete(buf, allocator)
            written, werr := ecs.serialize(&world_db, buf)
            testing.expect(t, werr == nil)
            testing.expect(t, written == shared_size)
    }

///////////////////////////////////////////////////////////////////////////////
// Adversarial: flipping SNAPSHOT_FLAG__HAS_ENTITY_ID_SECTION itself

    @(test)
    overbase_serialize_flag_bit_corruption__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            standalone_db: ecs.Database
            standalone_positions: ecs.Table

            ob: ecs.Overbase
            world_db: ecs.Database
            positions: ecs.Table
        //
        // Test
        //
            defer ecs.terminate(&standalone_db)
            defer ecs.overbase_terminate(&ob)
            defer ecs.terminate(&world_db)

            testing.expect(t, ecs.init(&standalone_db, entities_cap = 10, allocator = allocator) == nil)
            testing.expect(t, ecs.table__init(&standalone_positions, &standalone_db, 10, {Ob_Position}) == nil)
            s_eid, s_err := ecs.create_entity(&standalone_db)
            testing.expect(t, s_err == nil)
            s_perr := ecs.table__add_entity(&standalone_positions, s_eid)
            testing.expect(t, s_perr == nil)

            s_size, _ := ecs.serialized_size(&standalone_db)
            s_buf := make([]byte, s_size, allocator)
            defer delete(s_buf, allocator)
            _, s_serr := ecs.serialize(&standalone_db, s_buf)
            testing.expect(t, s_serr == nil)

            s_corrupt := make([]byte, s_size, allocator)
            defer delete(s_corrupt, allocator)
            copy(s_corrupt, s_buf)
            s_corrupt[16] ~= 0x02 // flip HAS_ENTITY_ID_SECTION off

            testing.expect(t, ecs.deserialize(&standalone_db, s_corrupt) != nil)
            testing.expect(t, ecs.deserialize(&standalone_db, s_buf) == nil)

            testing.expect(t, ecs.overbase_init(&ob, entities_cap = 10, databases_cap = 1, allocator = allocator) == nil)
            testing.expect(t, ecs.init_from_overbase(&world_db, &ob) == nil)
            testing.expect(t, ecs.table__init(&positions, &world_db, 10, {Ob_Position}) == nil)

            w_eid, w_err := ecs.create_entity(&ob)
            testing.expect(t, w_err == nil)
            w_perr := ecs.table__add_entity(&positions, w_eid)
            testing.expect(t, w_perr == nil)

            w_size, _ := ecs.serialized_size(&world_db)
            w_buf := make([]byte, w_size, allocator)
            defer delete(w_buf, allocator)
            _, w_serr := ecs.serialize(&world_db, w_buf)
            testing.expect(t, w_serr == nil)

            w_corrupt := make([]byte, w_size, allocator)
            defer delete(w_corrupt, allocator)
            copy(w_corrupt, w_buf)
            w_corrupt[16] ~= 0x02 // flip HAS_ENTITY_ID_SECTION on

            testing.expect(t, ecs.deserialize(&world_db, w_corrupt) != nil)
            testing.expect(t, ecs.deserialize(&world_db, w_buf) == nil)
    }
