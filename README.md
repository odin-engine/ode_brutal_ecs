![alt text](/img/banner.png?raw=true)
# 👊 Be a savage, use brutal ECS

One problem with modern [ECS](/docs/what_is_ecs.md) libraries is the excessive _overhead_ for the sake of comfort of programmers. They might have a nice query API that can do magic for you, but I'd rather sacrifice comfort for raw execution speed and transparency. 

ODE_BRUTAL_ECS is a minimal, manual, pure archetype-based, stripped-down version of [ODE_ECS](https://github.com/odin-engine/ode_ecs). No queries or views, no tags. [You do stuff manually](/docs/do_manually.md), but in return you get lean, highly performant and transparent ECS.

_The main idea: sacrifice a little bit of the comfort (debatable) of programmers for raw speed and clarity._

#### Brutal high-performance
- Extremely fast.
- Gives you full control over what's happening.
- No reallocations in the frame loop.
- Data is cache-friendly since there's no extra per-row metadata.
- Micro-optimized and benchmarked for maximum throughput.
- Frame-to-frame stability from both CPU and memory standpoints.

#### Low-level

#### Other features (exist on top of ECS core without overhead)
- [Relations](/docs/relations.md) — for modeling parent/child links between entities.
- [Pair_Table](/docs/pair_table.md) — for many-to-many relations between entities (holder → target, with an optional typed payload).
- [Pause/resume packing](#️-pausing-a-single-table) — a way to mutate tables safely while iterating.
- [Binary snapshots](/docs/serialization.md) — save/load a whole Database (entities, components, relations, pairs) to a buffer or file, with entity IDs staying valid after reload.
- [Overbase](/docs/overbase.md) — a way to share one entity-ID space across multiple Databases.

#### Tested & documented 
- Well [tested](/tests/) and comprehensively [documented](/docs/_index.md).
- Includes [samples](/docs/_index.md#-samples) for all main features.

# Quick start

```Odin
    import ecs "ode_brutal_ecs/src"

    Position :: struct { x, y: f32 } 
    Velocity :: struct { vx, vy: f32 }

    main :: proc() {

        db: ecs.Database

        ecs.init(&db, entities_cap = 100)
        defer ecs.terminate(&db)

        table1: ecs.Table
        ecs.table_init(&table1, &db, 50, {Position, Velocity})

        player, _ := ecs.create_entity(&table1, Position{10, 0}, Velocity{1, 1})

        positions    := ecs.slice(&table1, Position)
        velocities   := ecs.slice(&table1, Velocity)

        for i in 0..< len(positions) {
            positions[i].x += velocities[i].vx
            positions[i].y += velocities[i].vy
        }
    }
```

See the [API reference](/docs/api.md) for more details.

# How to install

Use `git clone` to clone this repository into your project folder, and then `import ecs "ode_brutal_ecs/src"`: 
```  
    git clone https://github.com/odin-engine/ode_brutal_ecs.git
```  
Don't forget to pull the latest changes from time to time. We usually don't break the API.

## 🧩 Database  
 
An ECS **_Database_** is analogous to a relational database instance, but for entities and components. Other ECS libraries refer to this concept as _Worlds_ or _Scenes_. However, I believe `Database` is a better term because a single game world can use multiple ECS databases, and a single game scene can also use multiple ECS databases.  

When initializing a `Database`, you can specify the maximum `entities_cap` as well as the allocator:  

```odin
    import ecs "ode_brutal_ecs/src"

    my_ecs: ecs.Database

    // in some procedure:
    ecs.init(&my_ecs, entities_cap=100, allocator=my_allocator)
```  

Every other object (tables) linked to `my_ecs` will now use `my_allocator` to allocate memory.  

>**NOTE:** ODE_BRUTAL_ECS never reallocates memory automatically during the frame loop. This follows the same reasoning as avoiding garbage collectors — to prevent performance drops caused by unexpected memory allocations, deallocations, or memory copying. Usually, you know the maximum number of entities you want in your game, so you can preallocate that amount ahead of time.  

You can have as many ECS databases in your game as you want:  

```odin
    ecs1: ecs.Database
    ecs2: ecs.Database

    ecs.init(&ecs1, entities_cap=100)
    ecs.init(&ecs2, entities_cap=200)
```  

`Database`s share **nothing** (by default) and can use different allocators.

`Table` is the only component-storage type in ODE_BRUTAL_ECS. `Pair_Table` (many-to-many relations) and `Relations_Table` (parent/child hierarchy) are the other main objects a `Database` can own.

## 🧬 **Table**

A **_Table_** is ODE_BRUTAL_ECS's archetype-style table: a single struct holding N component columns that share one row index, so every column of a row moves together as one unit. Component types are declared once, at init, as a `[]typeid`:

```odin
    Position :: struct { x, y: int } // component
    AI       :: struct { IQ: f32, neurons_count: int }

    units: ecs.Table  // holds Position + AI columns

    ecs.table_init(&units, db=&my_ecs, cap=100, component_types={Position, AI})
```
>**NOTE:** None of the declared component types can be zero-sized (`size_of(T) == 0`).

To create an entity, you can do this:

```odin
    robot, _ := ecs.create_entity(&my_ecs)
```

Now you can add a row (every declared column at once — there is no per-component add for an archetype) to the `robot` entity:

```odin
    ecs.add_entity(&units, robot)

    pos := ecs.get_component(&units, robot, Position)
    pos.x = 67
    pos.y = 43
```

Or create the entity and its row in one call:

```odin
    robot, _ := ecs.create_entity(&units)
```

To iterate over an archetype's columns, use `slice(&units, T)` to get each column as `[]T` and `slice(&units)` for the matching entity ids:

```odin
    pos_slice := ecs.slice(&units, Position)
    ai_slice := ecs.slice(&units, AI)
    eids := ecs.slice(&units) // or entities_slice(&units)

    for i in 0..<len(eids) {
        eid := eids[i]
        pos := &pos_slice[i]
        ai := &ai_slice[i]
        // ...
    }
```

>**NOTE:** Iterating a `Table`'s columns is as fast as possible because it's just iterating over slices/arrays. There are no "empty" or "deleted" rows in a live `slice`.

>**NOTE:** Removing a row tail-swaps the last row into the vacated slot — component **pointers are only valid until the archetype is mutated**. Store `entity_id`s, not component pointers, and re-`get_component` after mutations.

Table documentation is [here](/docs/table.md).

>**NOTE:** Creating databases and tables should happen outside the game's frame loop.

>**NOTE:** You can have an unlimited number of Tables or components. <u>There is no limit.</u>

## 🪸 Mutating tables (destroying entities/removing components) while iterating over them

### TIP: Be aware that component locations might shift within tables.

ODE_BRUTAL_ECS performs tail swaps (packing) when you remove an entity's row from a table (mutating a table) to optimize iteration speeds and avoid empty slots. This means you should avoid re-using pointers to components after a table has been mutated (e.g., by destroying the row's owning entity). Instead, save and use entity IDs to retrieve the updated component pointer after each table mutation. (Exception: while packing is paused, pointers stay stable until the table is packed.)

### TIP: Avoid mutating tables while iterating over them 

For example, avoid doing this:

```odin
for d in ecs.slice(&my_table) {
    ecs.destroy_entity(&my_db, d)  // Mutates my_table during iteration!
}
```
Correct pattern: Drain the table by repeatedly taking row `0` until it is empty:
```odin
for ecs.table_len(&my_table) > 0 {
    d := ecs.slice(&my_table)[0]
    ecs.destroy_entity(&my_db, d)   
}
```
Or pause packing (tail swapping) for the duration of the iteration — see the next section.

### Mutating tables while iterating: pause_packing / resume_packing / pack

`ecs.pause_packing(&db)` switches all tables into deferred-tail-swap mode: destroying an entity clears its row **in place** instead of tail-swapping, so no other row moves — rows and component pointers stay stable while you iterate. The vacated row becomes a *hole*: `get_entity` for it returns an id with `ix == ecs.DELETED_INDEX` (check with `ecs.is_not_set`), and `table_len` keeps reporting the full row span (holes included).

```odin
ecs.pause_packing(&db)

for i in 0..<ecs.table_len(&monsters) {
    eid := ecs.get_entity(&monsters, i)
    if ecs.is_not_set(eid) do continue // hole (already removed this frame)

    monster := ecs.get_component(&monsters, eid, Monster)
    if monster.hp <= 0 do ecs.destroy_entity(&db, eid) // safe: nothing moves
}

ecs.resume_packing(&db) // packs all tables with holes and re-enables tail swap
```

`ecs.resume_packing(&db)` restores normal tail swapping and *packs* every table that accumulated holes. `ecs.pack(&table)` is also available directly — for example mid-pause, when a table with many holes reports full (new components are always appended at the tail, so holes don't free capacity until packed).

### ⏸️ Pausing a single table

`pause_packing`/`resume_packing`/`pack` also accept a table directly, independent of the database-wide pause — useful in a multithreading scenario where one thread wants to safely mutate/iterate one table while other threads keep working on unrelated tables, without deferring packing everywhere:

```odin
ecs.pause_packing(&monsters)          // pause just this table
ecs.destroy_entity(&db, eid)          // leaves a hole in monsters, other tables tail-swap as normal
ecs.resume_packing(&monsters)         // packs just this table
```

Table-level pauses compose with (OR into) the database-wide pause: a database-wide `resume_packing` still packs every table, but does not forcibly clear a table's own independent pause — that pause stays in effect until its own `resume_packing` is called.

# How to manually do stuff in ODE_BRUTAL_ECS

See [here](/docs/do_manually.md).

# How to run samples and tests  

To run samples, navigate to the appropriate folder (`samples/basics` or `samples/sample02`) and execute:  

```  
    odin run . -o:speed
```  

To run tests, go to the `tests` folder and execute:  

```  
    odin test .  
```  

# Advanced

### Entity  

In ODE_BRUTAL_ECS, an entity is simply an ID. In the `ecs.odin` file, an entity is defined as follows:  

```odin
    entity_id ::        oc.ix_gen
```  

The `ix_gen` is defined like this:  

```odin
    ix_gen :: bit_field i64 {
        ix: int | 32,       // index
        gen: uint | 32,     // generation
    }
```  

This approach is very useful because it ensures that if you save an entity ID somewhere and the entity is destroyed, any new entity created with the same index will have a different generation, letting you know it is not the same entity.  

If an entity has been destroyed via `ecs.destroy_entity()`, use `is_expired` to check its status:

```odin
    ecs.is_expired(&db, my_entity_id) // returns true if the entity expired (was destroyed)
```

This procedure compares the entity's generation (`gen`) against the database records. 

# 📄 Documentation
* [Documentation](/docs/_index.md)
* [Updates Timeline](/docs/updates.md)    
* [FAQ](/docs/faq.md)
---
‼️ If you have any questions about ODE_BRUTAL_ECS or encounter any issues, please open an issue ticket, and I'll try to answer, fix, or add new functionality.
