# API Reference

The full public ODE_BRUTAL_ECS surface, grouped by object. This is a flat reference — for
narrative explanations and examples see [Database](database.md), [Table](table.md),
[Overbase](overbase.md), [Relations](relations.md), [Pairs](pair_table.md) and
[Serialization](serialization.md).

Every short name below (`ecs.init`, `ecs.create_entity`, ...) is an alias or proc-group entry
defined in [`/src/ecs.odin`](/src/ecs.odin) that resolves to a `typename__action` procedure in
that object's own file (`database.odin`, `table.odin`, ...). A `proc group` note means the short
name is overloaded across several object types — the compiler picks the match by argument types.
`loc := #caller_location` parameters are omitted below for brevity; they exist on most procedures
for better assert/error messages and never need to be passed explicitly.

All procedures take their object by pointer (`self: ^Database`, `self: ^Table`, ...) as the first
argument, shown here as `self`.

---

## Database

The "world" object — owns entities, tables, and (optionally) a relations table and pair tables.

```odin
init(self, entities_cap: u32, allocator := context.allocator,
     tables_cap: int = TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP) -> Error
init_from_overbase(self, overbase: ^Overbase, allocator: Maybe(runtime.Allocator) = nil,
     tables_cap: int = TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP) -> Error
terminate(self) -> Error
clear(self) -> Error                                    // proc group: also Table, Relations_Table, Sync_Channel

create_entity(self) -> (entity_id, Error)                // proc group: also Overbase, Table (create_entity/1..8)
destroy_entity(self, eid: entity_id, destroy_children := false) -> Error  // proc group: also Overbase
get_entity(self, index: int) -> entity_id                 // proc group: also Overbase, Table (by row number)
entities_len(self) -> int                                 // proc group: also Overbase
is_expired(self, eid: entity_id) -> bool                  // proc group: also Overbase

get_table(self, eid: entity_id) -> (table: ^Table, err: Error)
is_in(self, eid: entity_id, table: ^Table) -> bool         // proc group: also Table (table-only overload)

pause_tail_swap(self)                                      // = database__pause_packing
resume_tail_swap(self) -> Error                             // = database__resume_packing
pause_packing(self)                                         // proc group: also Table
resume_packing(self) -> Error                                // proc group: also Table

memory_usage(self) -> int                                   // proc group: also every other object
is_valid(self) -> bool                                      // proc group: also every other object
```

### Relations shortcuts (require a `Relations_Table`, see [Relations](relations.md))

`relations_init`/`relations_terminate` only take `self: ^Relations_Table`. Every other name below
is a proc group overloaded on `self: ^Database` (the usual, documented path — forwards into the
database's attached `Relations_Table`) *or* `self: ^Relations_Table` directly, for code that's
holding the table itself rather than the database.

```odin
relations_init(self: ^Relations_Table, db: ^Database, cap: int) -> Error
relations_terminate(self: ^Relations_Table) -> Error

set_parent(self: ^Database | ^Relations_Table, child: entity_id, parent: entity_id) -> Error
remove_parent(self: ^Database | ^Relations_Table, child: entity_id) -> Error
unparent(self: ^Database | ^Relations_Table, child: entity_id) -> Error   // alias of remove_parent
parent_of(self: ^Database | ^Relations_Table, eid: entity_id) -> (entity_id, Error)
children_of(self: ^Database | ^Relations_Table, parent: entity_id) -> ([]entity_id, Error)
children_count(self: ^Database | ^Relations_Table, eid: entity_id) -> (int, Error)
is_child_of(self: ^Database | ^Relations_Table, a: entity_id, b: entity_id) -> (bool, Error)
is_parent_of(self: ^Database | ^Relations_Table, a: entity_id, b: entity_id) -> (bool, Error)
has_relations(self: ^Database | ^Relations_Table, eid: entity_id) -> (bool, Error)
is_relation_of(self: ^Database | ^Relations_Table, target: entity_id, eid: entity_id) -> (bool, Error)

is_root(self: ^Database | ^Relations_Table, eid: entity_id) -> (bool, Error)
roots(self: ^Database | ^Relations_Table) -> ([]entity_id, Error)
walk_subtree(self: ^Database | ^Relations_Table, root: entity_id) -> ([]entity_id, Error)
walk_hierarchy(self: ^Database | ^Relations_Table) -> (entities: []entity_id, level_offsets: []int, Error)
```

---

## Table (Archetype Table)

A true-SoA archetype: N type-erased columns sharing one row index. See [Table](table.md).

```odin
table_init(self: ^Table, db: ^Database, cap: int, component_types: []typeid,
     sync_channels_cap: int = SYNC_CHANNELS_CAP) -> Error         // = table__init
table_terminate(self: ^Table) -> Error                            // = table__terminate — usually not needed; database__terminate handles it
add_entity(self: ^Table, eid: entity_id) -> Error                 // = table__add_entity — adds an existing entity to this table; the entity must not already be in any table
remove_entity(self: ^Table, eid: entity_id) -> Error   // = table__remove_entity, table-only removal, not database-wide; use destroy_entity(&db, eid) for the full teardown (relations, pair tables, etc.)

create_entity(self: ^Table) -> (eid: entity_id, err: Error)                          // 0 components
create_entity(self: ^Table, c1: $T1) -> (eid: entity_id, err: Error)                 // 1 component
create_entity(self: ^Table, c1: $T1, c2: $T2) -> (eid: entity_id, err: Error)        // 2 components
// ... up to create_entity8, one typed value per column, filled in argument order

get_entity_by_row_number(self: ^Table, row_number: int) -> entity_id  // also under get_entity proc group
get_component(self: ^Table, eid: entity_id, $T: typeid) -> ^T                  // proc group
get_component(self: ^Table, row: int, $T: typeid) -> ^T                        // by_row overload
get_component(self: ^Table, eid: entity_id, col_ix: int, $T: typeid) -> ^T      // by_col overload
set_component(self: ^Table, eid: entity_id, value: $T) -> ^T
get_column_ix(self: ^Table, $T: typeid) -> int
has_component(self: ^Table, eid: entity_id) -> bool             // = table__has_entity
is_in(self: ^Table, eid: entity_id) -> bool                       // proc group, table-only overload

move(eid: entity_id, from: ^Table, to: ^Table) -> Error            // = table__move_entity; `to` must be a superset of `from`'s columns
sudo_move(eid: entity_id, from: ^Table, to: ^Table) -> Error       // = table__sudo_move_entity; drops columns `to` doesn't have
copy(eid: entity_id, from: ^Table, to: ^Table) -> (new_eid: entity_id, err: Error)      // = table__copy_entity
sudo_copy(eid: entity_id, from: ^Table, to: ^Table) -> (new_eid: entity_id, err: Error) // = table__sudo_copy_entity

clear(self: ^Table) -> Error                    // proc group
pack(self: ^Table) -> Error                     // = table__pack — compacts holes left by a paused tail-swap
pause_packing(self: ^Table) -> Error            // proc group
resume_packing(self: ^Table) -> Error           // proc group
table_len(self: ^Table) -> int                  // proc group
table_cap(self: ^Table) -> int                  // proc group

entities_slice(self: ^Table) -> []entity_id     // = slice(&t) — row-order entity ids
slice(self: ^Table, $T: typeid) -> []T          // = table__column_slice — row-order column, by value

memory_usage(self: ^Table) -> int               // proc group
is_valid(self: ^Table) -> bool                  // proc group
```

---

## Overbase

A shareable entity-id space: multiple `Database`s can attach to one `Overbase` so an `entity_id`
means the same logical entity across all of them. See [Overbase](overbase.md).

```odin
overbase_init(self: ^Overbase, entities_cap: u32, databases_cap := 1,
     allocator := context.allocator) -> Error
overbase_terminate(self: ^Overbase) -> Error
init_from_overbase(db: ^Database, overbase: ^Overbase, ...) -> Error   // see Database section — attaches a Database to this Overbase

create_entity(self: ^Overbase) -> (entity_id, Error)          // proc group
destroy_entity(self: ^Overbase, eid: entity_id, destroy_children := false) -> Error  // proc group
get_entity(self: ^Overbase, index: int) -> entity_id            // proc group
entities_len(self: ^Overbase) -> int                             // proc group
is_expired(self: ^Overbase, eid: entity_id) -> bool              // proc group

memory_usage(self: ^Overbase) -> int   // proc group
is_valid(self: ^Overbase) -> bool      // proc group
```

---

## Pairs (`Pair_Table($T)`)

Many-to-many relations between entities (holder → target, optional typed payload `T`), independent
of `Table`/`Relations_Table` membership. See [Pairs](pair_table.md).

```odin
pair_init(self: ^Pair_Table($T), db: ^Database, holders_cap: int, pairs_cap: int) -> Error
pair_terminate(self: ^Pair_Table($T)) -> Error

pair_add(self: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T) -> (row: Pair_Row_Id, err: Error)
pair_remove(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> Error
pair_remove_all(self: ^Pair_Table($T), holder: entity_id) -> Error   // removes every pair for that holder

pair_has_pair(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> bool
pair_has_any(self: ^Pair_Table($T), holder: entity_id) -> bool             // O(1): does holder have >= 1 pair?
pair_first_target(self: ^Pair_Table($T), holder: entity_id) -> (target: entity_id, ok: bool)
pair_first_data(self: ^Pair_Table($T), holder: entity_id) -> (data: ^T, ok: bool)
pair_targets_of(self: ^Pair_Table($T), holder: entity_id) -> (res: []entity_id, err: Error)  // valid until next call or structural change

table_len(self: ^Pair_Table($T)) -> int   // proc group — = pair_table__len
table_cap(self: ^Pair_Table($T)) -> int   // proc group — = pair_table__cap

memory_usage(self: ^Pair_Table($T)) -> int   // proc group
is_valid(self: ^Pair_Table($T)) -> bool      // proc group
```

---

## Relations (`Relations_Table`)

Single-parent/many-children tree relations, one `Relations_Table` per `Database`. See
[Relations](relations.md). Object lifecycle (`relations_init`/`relations_terminate`) and
`table_len`/`table_cap`/`memory_usage`/`is_valid` proc groups take `^Relations_Table` directly; every
other operation (listed under **Database** above) is a proc group that accepts either `^Database`
(the usual path — forwards into the attached table) or `^Relations_Table` directly.

```odin
relations_init(self: ^Relations_Table, db: ^Database, cap: int) -> Error
relations_terminate(self: ^Relations_Table) -> Error

table_len(self: ^Relations_Table) -> int    // proc group
table_cap(self: ^Relations_Table) -> int    // proc group
clear(self: ^Relations_Table) -> Error      // proc group

memory_usage(self: ^Relations_Table) -> int   // proc group
is_valid(self: ^Relations_Table) -> bool      // proc group
```

---

## Serialization (whole-`Database` binary snapshot)

Round-trips a whole `Database` — entities, every table's components, relations, and pairs. See
[Serialization](serialization.md).

```odin
serialized_size(self: ^Database) -> (size: int, err: Error)
serialize(self: ^Database, buf: []byte, allow_non_pod := false) -> (written: int, err: Error)
deserialize(self: ^Database, data: []byte) -> Error
save_to_file(self: ^Database, path: string, allocator := context.allocator,
     allow_non_pod := false) -> Error
load_from_file(self: ^Database, path: string, allocator := context.allocator) -> Error
```

## Overbase serialization

Same idea, for a shared `Overbase`'s id space (its attached `Database`s are serialized separately,
via the calls above).

```odin
overbase_serialized_size(self: ^Overbase) -> (size: int, err: Error)
overbase_serialize(self: ^Overbase, buf: []byte) -> (written: int, err: Error)
overbase_deserialize(self: ^Overbase, data: []byte) -> Error
overbase_save_to_file(self: ^Overbase, path: string, allocator := context.allocator) -> Error
overbase_load_from_file(self: ^Overbase, path: string, allocator := context.allocator) -> Error
```

---

## Sync (`Sync_Channel` / `Sync_Decoder`) — experimental

Delta-change replication for an unreliable transport (e.g. UDP). **Off by default** — compile with
`-define:ECS_SYNC_ENABLED=true`. Without it, `sync_register` returns `API_Error.Sync_Feature_Disabled`
(so nothing ever gets registered); the rest of the procedures below still compile and run, just
against empty state. The API may still change.

```odin
sync_channel_init(self: ^Sync_Channel, db: ^Database, tables_cap: int,
     structural_events_cap: int = 256) -> Error
sync_channel_terminate(self: ^Sync_Channel) -> Error
sync_decoder_init(self: ^Sync_Decoder, db: ^Database, tables_cap: int) -> Error
sync_decoder_terminate(self: ^Sync_Decoder) -> Error

sync_register(self: ^Sync_Channel, table: ^Table, allow_non_pod := false) -> Error   // proc group
sync_register(self: ^Sync_Decoder, table: ^Table, allow_non_pod := false) -> Error   // proc group
sync_unregister(self: ^Sync_Channel, table: ^Table) -> Error

collect_delta(self: ^Sync_Channel, buf: []byte) -> (written: int, err: Error)  // = sync_collect_delta
delta_max_size(self: ^Sync_Channel) -> int                                     // upper bound for buf's size
apply_delta(self: ^Sync_Decoder, data: []byte) -> Error                       // = sync_apply_delta
resync(self: ^Sync_Channel) -> Error   // rebuild the shadow copy + drop pending structural events

clear(self: ^Sync_Channel) -> Error   // proc group — zeroes shadow copies + pending events

memory_usage(self: ^Sync_Channel | ^Sync_Decoder) -> int   // proc group
is_valid(self: ^Sync_Channel | ^Sync_Decoder) -> bool      // proc group
```

---

## Core types & errors

```odin
entity_id :: oc.ix_gen                  // bit_field i64 { ix: int | 32, gen: uint | 32 }
table_id :: distinct int
table_record_id :: distinct int
pair_table_id :: distinct int
Pair_Row_Id :: distinct int             // row handle returned by pair_add, stable until pair_remove

is_not_set(e: entity_id) -> bool        // true when e.ix == DELETED_INDEX (a "no entity" value)
DELETED_INDEX                            // sentinel index value ( = oc.DELETED_INDEX)

Object_State :: enum {
    Not_Initialized, Normal, Invalid, Terminated,
}

API_Error :: enum {
    None,
    Entities_Cap_Should_Be_Greater_Than_Zero, Component_Already_Exist,
    Tables_Array_Should_Not_Be_Empty, Unexpected_Error,
    Entity_Id_Out_of_Bounds, Entity_Id_Expired, Object_Invalid,
    Component_Size_Cannot_Be_Zero,
    Relations_Table_Already_Exists, Relations_Table_Not_Created, Relation_Cycle,
    Snapshot_Invalid, Snapshot_Version_Mismatch, Snapshot_Schema_Mismatch,
    Snapshot_Capacity_Too_Small, Snapshot_Component_Not_POD,
    Cannot_Serialize_While_Packing_Paused, Serialize_Buffer_Too_Small, File_Error,
    Sync_Too_Many_Fields, Sync_Table_Already_Registered, Sync_Buffer_Too_Small,
    Sync_Feature_Disabled,
    Entity_Already_In_Table, Entity_Not_In_Table, Table_To_Cannot_Contain_Entity,
}

Error :: union #shared_nil {
    API_Error, oc.Core_Error, oc.Error, runtime.Allocator_Error,
}
```

### Compile-time configuration

| Define | Default | Meaning |
|---|---|---|
| `ECS_VALIDATIONS` | `true` | Assert-based parameter/state validation (`VALIDATIONS`) |
| `ECS_TABLES_CAP` | `16` | Initial preallocation for `Database.tables` (auto-growing, not a hard ceiling) |
| `ECS_PAIR_TABLES_CAP` | `8` | Initial preallocation for attached `Pair_Table`s |
| `ECS_SYNC_ENABLED` | `false` | Compiles in `Sync_Channel`/`Sync_Decoder` |
| `ECS_SYNC_CHANNELS_CAP` | `8` | Max sync channels a single `Table` can be registered to |
