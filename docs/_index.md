# 📄 Docs

* [README.md](/README.md)

Main:
* [API Reference](api.md)
* [Database](database.md)
* [Table (Archetype Table)](table.md)

Optional:
* [Relations](relations.md)
* [Pairs (many-to-many relations)](pair_table.md)
* [Serialization](serialization.md)
* [Overbase](overbase.md)

Other:
* [What is ECS?](what_is_ecs.md)
* [Archetype ECS vs. Sparse-Dense ECS](ecs_types.md)
* [Fat Struct vs. ECS discussion](fat_struct_vs_ecs.md)
* ❓[Frequently Asked Questions (F.A.Q)](faq.md)

# 🍕 Samples

* [Basics](/samples/basics/main.odin) – A minimal starting point: init a database, a `Table`, create entities, iterate.
* [Sample01](/samples/sample01/main.odin) – Demonstrates the "do stuff manually" workflow.
* [Sample02](/samples/sample02/main.odin) – How to optimize your ECS usage (Approach 1 vs. Approach 2).
* [Sample03](/samples/sample03/main.odin) – Demonstrates entity relations (`relations_init`, `set_parent`, `children_of`).
* [Sample04](/samples/sample04/main.odin) – Demonstrates serialization: snapshot a database, save/load it from a file.
* [Sample05](/samples/sample05/main.odin) – Demonstrates `Overbase`: sharing one entity ID space across two Databases.
* [Sample06](/samples/sample06/main.odin) – Demonstrates `Overbase` serialization: saving and restoring a shared entity ID space and two attached Databases.
* [Sample07](/samples/sample07/main.odin) – Demonstrates `Table`: whole-row create/get_component/iteration with `slice(&units)`/`slice(&units, T)`.
* [Sample08](/samples/sample08/main.odin) – Demonstrates relations hierarchy walk.
* [Sample09](/samples/sample09/main.odin) – Demonstrates `Pair_Table`: many-to-many relations.


# 📖 How to read the source code

To check the main **ODE\_BRUTAL\_ECS** procedures, you can go to [ecs.odin](/src/ecs.odin) and scroll down to the **aliases** section. Those are the main or most commonly used procedures, though not all of them.

If you want to find all procedures related to a specific object—for example, **Table** (or [Pair\_Table](/src/pair_table.odin), [Relations\_Table](/src/relations_table.odin), etc.)—you can go to its respective file. For **Table**, that would be [table.odin](/src/table.odin). All source lives under [`/src`](/src).

# 🕑 Performance tuning

ODE_BRUTAL_ECS ships with a micro-benchmark suite in `benchmarks/` — the referee for any performance work on the library. Run it before and after a change and compare ns/op:

```
    cd benchmarks
    odin run . -o:speed -out:out/bench.exe
```

Compiler flags that matter for release builds of your game:

- `-o:speed` — enables optimizations; the single biggest factor.
- `-define:ECS_VALIDATIONS=false` — strips the library's parameter/state asserts.
- `-disable-assert` — strips all remaining asserts globally.
- `-no-bounds-check` — disables bounds checking globally. The library already annotates its provably-safe hot paths with `#no_bounds_check`, so this mostly affects your own code.
- `-microarch:native` — allows the compiler to use your CPU's full instruction set.

# 💪 Benchmarks (ODE_ECS vs other ECSes)

- ODE_ECS (the pre-reset, relational-style predecessor of ODE_BRUTAL_ECS) vs moecs vs odecs benchmark is [here](https://github.com/zm69/ecs_bench) — it predates the ODE_BRUTAL_ECS reset and hasn't been re-run against it.

# ‼️ When to open an issue ticket
If you have any questions about ODE_BRUTAL_ECS or encounter any issues, please open an issue ticket, and I’ll try to answer, fix, or add new functionality.
