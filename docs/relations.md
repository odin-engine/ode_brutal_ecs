# Relations (parent/child)

`Relations_Table` is an optional table that adds **parent/child relations** between entities: every entity can have at most one parent and any number of children. Typical uses: transform hierarchies, inventories, squads, attachments.

Like everything else in ODE_BRUTAL_ECS, all memory is preallocated at init, and set/remove/re-parent are all **O(1)** (intrusive linked-tree arrays indexed by `eid.ix` — direct array accesses, no hashing).

At most **one** `Relations_Table` per [Database](database.md) (a second `relations_init` returns `Relations_Table_Already_Exists`).

> **NOTE:** Relations are *not* components — they carry no queryable table membership of their own. `roots`/`walk_hierarchy` below cover "iterate entities that participate in the hierarchy" directly; if you specifically need that to be queryable as a table, move the entity into a dedicated `Table` on `set_parent` instead (see [You do stuff manually](do_manually.md)).

## Setup

```odin
import ecs "ode_brutal_ecs/src"

my_ecs: ecs.Database
rt:     ecs.Relations_Table

ecs.init(&my_ecs, entities_cap = 1000)

// cap = max number of concurrent parent links (child→parent edges),
// must be <= entities_cap
ecs.relations_init(&rt, &my_ecs, cap = 500) // long form: ecs.relations_table__init
```

The table is terminated automatically with the database. Memory cost: `entities_cap * 36` bytes + `cap * 32 + 16` bytes.

Once initialized, relation operations are usually called through **database-level procedures** (`ecs.set_parent(&my_ecs, ...)`, etc.) — calling them before `relations_init` returns `API_Error.Relations_Table_Not_Created`. The same short names also work directly on `&rt` (`ecs.set_parent(&rt, ...)`) for code that's holding the `Relations_Table` itself rather than the database; that path has no database to check against, so it asserts (under `ECS_VALIDATIONS`) that `rt` is already initialized instead of returning an error.

## Linking and unlinking

```odin
squad,   _ := ecs.create_entity(&my_ecs)
soldier, _ := ecs.create_entity(&my_ecs)

// Make `squad` the parent of `soldier`
ecs.set_parent(&my_ecs, soldier, squad)

// Re-parenting is in place — just call set_parent again;
// the previous link is replaced (O(1))
other_squad, _ := ecs.create_entity(&my_ecs)
ecs.set_parent(&my_ecs, soldier, other_squad)

// Remove the link (alias: ecs.unparent)
ecs.remove_parent(&my_ecs, soldier)   // Not_Found if soldier has no parent
```

`set_parent` errors:

- `Relation_Cycle` — `child == parent`, or the link would make an entity its own ancestor. The check walks the new parent's ancestor chain (O(tree depth)) **before** any mutation, so nothing changes on failure.
- `Container_Is_Full` — creating a **new** link would exceed `cap`. Re-parenting an already-linked child always succeeds.
- `Entity_Id_Expired` / `Entity_Id_Out_of_Bounds` — stale or invalid entity IDs.

## Queries

```odin
p, _   := ecs.parent_of(&my_ecs, soldier)      // parent id, or p.ix == ecs.DELETED_INDEX if none
kids, _ := ecs.children_of(&my_ecs, squad)     // []entity_id — use immediately, see note below
n, _    := ecs.children_count(&my_ecs, squad)

yes, _ := ecs.is_child_of(&my_ecs, soldier, squad)     // is `soldier` a child of `squad`?
yes, _  = ecs.is_parent_of(&my_ecs, squad, soldier)    // is `squad` the parent of `soldier`?
yes, _  = ecs.has_relations(&my_ecs, soldier)          // does it have a parent or any children?
yes, _  = ecs.is_relation_of(&my_ecs, squad, soldier)  // direct link in either direction
```

To check for "no parent", compare `parent_of`'s result against `ecs.DELETED_INDEX` — or use `is_root` below, which additionally requires at least one child (see why in "Hierarchy walk"):

```odin
p, _ := ecs.parent_of(&my_ecs, eid)
if p.ix == ecs.DELETED_INDEX {
    // eid has no parent
}
```

> **NOTE:** The slice returned by `children_of` points into an internal preallocated scratch buffer. It is valid only until the next `children_of` call or any structural change (`set_parent` / `remove_parent` / `destroy_entity` / `clear`) — use it immediately, do not store it and do not mutate relations while walking it. Copy it first if you need to.

## Hierarchy walk

Read-only traversal helpers, always parent-before-child order — the same order `destroy_entity(..., destroy_children = true)` relies on internally (reversed, to destroy deepest-first), exposed here for reading instead.

```odin
is_r, _ := ecs.is_root(&my_ecs, squad)   // no parent AND at least one child
                                          // (an entity that never touched relations
                                          // at all is not a root, just untouched)

roots, _ := ecs.roots(&my_ecs)           // every root, O(entities_cap) scan —
                                          // no dense index of "has relations" exists

desc, _ := ecs.walk_subtree(&my_ecs, squad)   // squad's descendants, breadth-first
                                                // (squad itself is not included, same
                                                // convention as children_of)

entities, levels, _ := ecs.walk_hierarchy(&my_ecs)
// entities: every root, then their children, then grandchildren, ... (whole forest)
// levels:   level boundaries — levels[i]..<levels[i+1] indexes `entities` for depth i
for i in 0..<len(levels)-1 {
    level := entities[levels[i]:levels[i+1]]
    // process one full depth level at a time, e.g. propagate a transform top-down
}
```

> **NOTE:** `roots`, `walk_subtree`, and `walk_hierarchy` all return slices of internal buffers, valid only until the next call to any of them, or any structural change — same "use immediately, don't store" contract as `children_of`.

`walk_hierarchy` discovers every root itself, so it is a materially different (and more expensive) traversal than repeated `walk_subtree` calls — reach for `walk_subtree` when you already have a specific root and don't need level boundaries, `walk_hierarchy` when you need the whole forest or per-level processing.

See [Sample08](/samples/sample08/main.odin) for a complete example, including per-level transform propagation.

## Automatic cleanup on destroy

`destroy_entity` keeps relations consistent — every `entity_id` stored in the relations table is always alive:

```odin
// Default: unlink from parent, ORPHAN the children (their parent link is cleared)
ecs.destroy_entity(&my_ecs, squad)

// Cascade: destroy the entity AND all of its descendants
ecs.destroy_entity(&my_ecs, squad, destroy_children = true)
```

The cascade is iterative (no recursion, uses the preallocated scratch buffer) and destroys the deepest entities first; each destroyed entity is removed from all its component tables as usual. Without a `Relations_Table`, `destroy_children = true` is a harmless no-op.

## Complete example

```odin
Transform :: struct { x, y: f32 }

my_ecs:     ecs.Database
rt:         ecs.Relations_Table
transforms: ecs.Table

main :: proc() {
    defer ecs.terminate(&my_ecs)
    ecs.init(&my_ecs, entities_cap = 100)
    ecs.relations_init(&rt, &my_ecs, cap = 100)
    ecs.table_init(&transforms, &my_ecs, 100, component_types = {Transform})

    ship, _    := ecs.create_entity(&my_ecs)
    turret1, _ := ecs.create_entity(&my_ecs)
    turret2, _ := ecs.create_entity(&my_ecs)

    for eid in ([]ecs.entity_id{ship, turret1, turret2}) {
        ecs.add_entity(&transforms, eid)
        t := ecs.get_component(&transforms, eid, Transform)
        t^ = { 10, 20 }
    }

    ecs.set_parent(&my_ecs, turret1, ship)
    ecs.set_parent(&my_ecs, turret2, ship)

    // Move all direct children of the ship
    kids, _ := ecs.children_of(&my_ecs, ship)
    for kid in kids {
        t := ecs.get_component(&transforms, kid, Transform)
        t.x += 5
    }

    // Ship explodes — turrets go with it
    ecs.destroy_entity(&my_ecs, ship, destroy_children = true)

    ecs.is_expired(&my_ecs, turret1) // true
}
```

## Other operations

```odin
ecs.table_len(&rt)        // current number of parent links
ecs.table_cap(&rt)        // cap (max concurrent links)
ecs.clear(&rt)            // remove ALL relations (entities themselves are untouched)
ecs.memory_usage(&rt)     // bytes
ecs.is_valid(&rt)
```

Tests with more usage patterns: [tests/relations_table_test.odin](../tests/relations_table_test.odin).
