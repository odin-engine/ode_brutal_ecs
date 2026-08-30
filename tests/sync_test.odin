/*
    2026 (c) Zaya, https://github.com/zm69
*/
package ode_ecs__tests

// Core
    import "core:testing"
    import "core:mem"

// ODE
    import ecs "../src"

when ecs.SYNC_ENABLED {

///////////////////////////////////////////////////////////////////////////////
// Sender + receiver share entity identity via a common Overbase — mirrors how
// two real processes in a client/server pair agree on entity ids.

    Sync_Pub_World :: struct {
        ob:      ecs.Overbase,
        db_send: ecs.Database,
        db_recv: ecs.Database,
        pos_send: ecs.Table,
        pos_recv: ecs.Table,
        ch:  ecs.Sync_Channel,
        dec: ecs.Sync_Decoder,
    }

    sync_pub_world__init :: proc(t: ^testing.T, w: ^Sync_Pub_World, entities_cap: int, allocator: mem.Allocator) {
        testing.expect(t, ecs.overbase_init(&w.ob, u32(entities_cap), 2, allocator) == nil)
        testing.expect(t, ecs.init_from_overbase(&w.db_send, &w.ob) == nil)
        testing.expect(t, ecs.init_from_overbase(&w.db_recv, &w.ob) == nil)

        testing.expect(t, ecs.table__init(&w.pos_send, &w.db_send, entities_cap, {Position}) == nil)
        testing.expect(t, ecs.table__init(&w.pos_recv, &w.db_recv, entities_cap, {Position}) == nil)

        testing.expect(t, ecs.sync_channel_init(&w.ch, &w.db_send, 4) == nil)
        testing.expect(t, ecs.sync_decoder_init(&w.dec, &w.db_recv, 4) == nil)

        testing.expect(t, ecs.sync_register(&w.ch, &w.pos_send) == nil)
        testing.expect(t, ecs.sync_register(&w.dec, &w.pos_recv) == nil)
    }

    sync_pub_world__terminate :: proc(w: ^Sync_Pub_World) {
        ecs.sync_channel_terminate(&w.ch)
        ecs.sync_decoder_terminate(&w.dec)
        ecs.terminate(&w.db_send)
        ecs.terminate(&w.db_recv)
        ecs.overbase_terminate(&w.ob)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    sync_public_table_structural_and_data__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        w: Sync_Pub_World
        defer sync_pub_world__terminate(&w)
        sync_pub_world__init(t, &w, 20, allocator)

        eid, eerr := ecs.create_entity(&w.ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, ecs.table__add_entity(&w.pos_send, eid) == nil)
        ecs.get_component(&w.pos_send, eid, Position)^ = Position{ x = 7, y = 9 }

        buf := make([]byte, ecs.delta_max_size(&w.ch), allocator)
        defer delete(buf, allocator)

        written, werr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written]) == nil)
        testing.expect(t, ecs.has_component(&w.pos_recv, eid))
        recv_pos := ecs.get_component(&w.pos_recv, eid, Position)
        testing.expect(t, recv_pos != nil && recv_pos.x == 7 && recv_pos.y == 9)

        testing.expect(t, ecs.table__remove_entity(&w.pos_send, eid) == nil)
        written2, werr2 := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, ecs.apply_delta(&w.dec, buf[:written2]) == nil)
        testing.expect(t, !ecs.has_component(&w.pos_recv, eid))
    }

    @(test)
    sync_public_resync_after_snapshot__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        w: Sync_Pub_World
        defer sync_pub_world__terminate(&w)
        sync_pub_world__init(t, &w, 20, allocator)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        // baseline: header-only size with nothing pending, learned from the
        // channel itself rather than assuming its private wire-format layout
        header_only_size, hoerr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, hoerr == nil)

        eid, eerr := ecs.create_entity(&w.ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, ecs.table__add_entity(&w.pos_send, eid) == nil)
        ecs.get_component(&w.pos_send, eid, Position)^ = Position{ x = 3, y = 4 }

        // simulate an out-of-band full snapshot having already delivered the row
        testing.expect(t, ecs.table__add_entity(&w.pos_recv, eid) == nil)
        ecs.get_component(&w.pos_recv, eid, Position)^ = Position{ x = 3, y = 4 }

        testing.expect(t, ecs.resync(&w.ch) == nil)

        // nothing pending: resync dropped the structural-add event and
        // resynced the shadow, since the snapshot already covers it
        written, werr := ecs.collect_delta(&w.ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, written == header_only_size, "resync must leave no pending structural or data records behind")
    }

} // when ecs.SYNC_ENABLED
