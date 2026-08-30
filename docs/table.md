# Table (Archetype Table)

`Table` is ODE_BRUTAL_ECS's archetype-style table: a single struct holding **N component columns that share one row index**, so every column of a row moves together as one unit when a tail-swap happens.

Reach for `Table` when a fixed set of components always travels together on the same entities and you iterate that combination in a hot loop (e.g. `Position` + `Velocity` + `Sprite` on thousands of entities every frame) — see [Archetype ECS vs. Sparse-Dense ECS](ecs_types.md) for the general trade-off.

## Declaring an archetype

Component types are passed once, at init, as a `[]typeid`:

```odin
import ecs "ode_brutal_ecs/src"

Position :: struct { x, y: int }
AI       :: struct { IQ: f32, neurons_count: int }

my_ecs: ecs.Database
units:  ecs.Table

ecs.init(&my_ecs, entities_cap = 1000)
ecs.table_init(&units, &my_ecs, cap = 500, component_types = {Position, AI})
```

There is no per-component `add_component`/`remove_component` for an archetype — an entity either has the whole row (every declared column) or none of it.

None of the declared `component_types` may be zero-sized — `table_init`/`create_entity`/`add_entity` assert on this (`API_Error.Component_Size_Cannot_Be_Zero` when validations are compiled out).

## Creating, adding, removing

```odin
// allocates an entity id AND its archetype row in one call
robot, err := ecs.create_entity(&units)

// or: entity created elsewhere, add it to the archetype afterwards
soldier, _ := ecs.create_entity(&my_ecs)
ecs.add_entity(&units, soldier)

// remove the whole row (every column) — one tail-swap moves all columns at once
ecs.remove_entity(&units, soldier)
```

`add_entity` returns `API_Error.Component_Already_Exist` if the entity already has a row in *this* table, `API_Error.Entity_Already_In_Table` if it's already in a *different* table (recall an entity belongs to at most one `Table`), and `Container_Is_Full` once `cap` is reached.

## Reading and writing components

```odin
pos := ecs.get_component(&units, robot, Position)
pos.x = 67
pos.y = 43

ai := ecs.get_component(&units, robot, AI)
ai.neurons_count = 42

ecs.has_component(&units, robot)   // true
```

`get_component` returns `nil` for an entity with no row. Passing a type that isn't one of this archetype's columns is treated as a programmer error: it asserts under `ECS_VALIDATIONS` (the default) and only returns `nil` when validations are compiled out.

> **NOTE:** Removing a row tail-swaps the last row into the vacated slot — component **pointers are only valid until the archetype is mutated**. Store `entity_id`s, not component pointers, and re-`get_component` after mutations.

## Iterating with `slice(&units, T)`

`slice(&units, T)` hands you a column as `[]T` — row order, always packed, no alignment check
needed — and `slice(&units)` gives the matching entity ids in the same order:

```odin
eids     := ecs.slice(&units)
pos_slice := ecs.slice(&units, Position)
ai_slice  := ecs.slice(&units, AI)

for i in 0..<len(eids) {
    pos_slice[i].x += ai_slice[i].neurons_count
    fmt.println(eids[i], pos_slice[i])
}
```

The slices are re-derived from the archetype's column storage each call — no allocation — but
they're only valid until the next structural change (add/remove entity); don't hold them across
one. Splitting the range into batches (e.g. across worker threads) is plain index math on
`eids`/the column slices.

## Other operations

```odin
ecs.table_len(&units)          // number of rows currently stored
ecs.table_cap(&units)          // capacity
ecs.clear(&units)              // remove all rows, keep the archetype initialized
ecs.pack(&units)                // compact holes left while tail swap was paused
ecs.pause_packing(&units)       // defer this archetype's removals to holes
ecs.resume_packing(&units)      // resume and pack
ecs.memory_usage(&units)        // bytes
ecs.is_valid(&units)
ecs.slice(&units, Position)    // []Position, row order, always packed (no alignment check needed)
ecs.slice(&units)              // []entity_id, same row order
```

## Serialization

`Table` participates in whole-database snapshots automatically — see [Serialization](serialization.md). No extra steps are needed; `serialize`/`deserialize` write and validate every column of every archetype.
