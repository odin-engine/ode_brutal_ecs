/*
    2026 (c) Zaya, https://github.com/zm69

    Be a savage ;)
    ODE_BRUTAL_ECS
*/
package ode_ecs

// Base
    import "base:runtime"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    VALIDATIONS :: #config(ECS_VALIDATIONS, true)

    //
    // Tables
    // 

        // Caps are initial, not hard limits: tables grow as needed outside of the frame loop.
        TABLES_CAP ::  #config(ECS_TABLES_CAP, 16)

        PAIR_TABLES_CAP :: #config(ECS_PAIR_TABLES_CAP, 8)

    //
    // Sync - delta-change replication.
    //

        SYNC_ENABLED :: #config(ECS_SYNC_ENABLED, false)

        SYNC_CHANNELS_CAP :: #config(ECS_SYNC_CHANNELS_CAP, 8)

        SYNC_MAX_FIELDS :: 32

    //
    // Other
    //

        DELETED_INDEX :: oc.DELETED_INDEX

///////////////////////////////////////////////////////////////////////////////
// Aliases
//

    //
    // Database
    //
        init                    :: database__init
        terminate               :: database__terminate
        pause_tail_swap         :: database__pause_packing
        resume_tail_swap        :: database__resume_packing

    //
    // Overbase
    //
        overbase_init           :: overbase__init
        overbase_terminate      :: overbase__terminate
        init_from_overbase      :: database__init_from_overbase

        entities_len :: proc {
            database__entities_len,
            overbase__entities_len,
        }

        create_entity :: proc {
            database__create_entity,
            overbase__create_entity,
            table__create_entity,
            table__create_entity1,
            table__create_entity2,
            table__create_entity3,
            table__create_entity4,
            table__create_entity5,
            table__create_entity6,
            table__create_entity7,
            table__create_entity8,
        }

        destroy_entity :: proc {
            database__destroy_entity,
            overbase__destroy_entity,
        }

        is_in :: proc {
            database__is_in,
            table__is_in,
        }

        get_table :: database__get_table

        table_init      :: table__init
        table_terminate :: table__terminate
        add_entity      :: table__add_entity
        remove_entity   :: table__remove_entity

        move       :: table__move_entity
        sudo_move  :: table__sudo_move_entity
        copy       :: table__copy_entity
        sudo_copy  :: table__sudo_copy_entity

        is_expired :: proc {
            database__is_entity_expired,
            overbase__is_entity_expired,
        }

    //
    // Serialization (binary snapshot of a whole Database)
    //
        serialized_size         :: database__serialized_size
        serialize               :: database__serialize
        deserialize              :: database__deserialize
        save_to_file            :: database__save_to_file
        load_from_file          :: database__load_from_file

    //
    // Overbase serialization
    //
        overbase_serialized_size :: overbase__serialized_size
        overbase_serialize       :: overbase__serialize
        overbase_deserialize     :: overbase__deserialize
        overbase_save_to_file    :: overbase__save_to_file
        overbase_load_from_file  :: overbase__load_from_file

    //
    // Sync (delta-change replication over an unreliable transport)
    //
        sync_channel_init      :: sync_channel__init
        sync_channel_terminate :: sync_channel__terminate
        sync_decoder_init      :: sync_decoder__init
        sync_decoder_terminate :: sync_decoder__terminate

        sync_register :: proc {
            sync_channel__register_table,
            sync_decoder__register_table,
        }
        sync_unregister :: sync_channel__unregister_table

        collect_delta  :: sync_collect_delta
        delta_max_size :: sync_delta_max_size
        apply_delta    :: sync_apply_delta
        resync         :: sync_channel__resync

    //
    // Relations (parent/child); requires a Relations_Table on the database
    //
        relations_init      :: relations_table__init
        relations_terminate :: relations_table__terminate

        set_parent :: proc {
            database__set_parent,
            relations_table__set_parent,
        }
        remove_parent :: proc {
            database__remove_parent,
            relations_table__remove_parent,
        }
        unparent :: remove_parent
        parent_of :: proc {
            database__parent_of,
            relations_table__parent_of,
        }
        children_of :: proc {
            database__children_of,
            relations_table__children_of,
        }
        children_count :: proc {
            database__children_count,
            relations_table__children_count,
        }
        is_child_of :: proc {
            database__is_child_of,
            relations_table__is_child_of,
        }
        is_parent_of :: proc {
            database__is_parent_of,
            relations_table__is_parent_of,
        }
        has_relations :: proc {
            database__has_relations,
            relations_table__has_relations,
        }
        is_relation_of :: proc {
            database__is_relation_of,
            relations_table__is_relation_of,
        }

        is_root :: proc {
            database__is_root,
            relations_table__is_root,
        }
        roots :: proc {
            database__roots,
            relations_table__roots,
        }
        walk_subtree :: proc {
            database__walk_subtree,
            relations_table__walk_subtree,
        }
        walk_hierarchy :: proc {
            database__walk_hierarchy,
            relations_table__walk_hierarchy,
        }

    //
    // Proc groups
    //

        //
        // Entity
        //

        get_entity          :: proc {
            database__get_entity,
            overbase__get_entity,
            table__get_entity_by_row_number,
        }

        get_entity_by_row_number :: table__get_entity_by_row_number

        //
        // Component
        //

        get_component       :: proc {
            table__get_component,
            table__get_component_by_row,
            table__get_component_by_col,
        }

        set_component       :: table__set_component

        get_column_ix       :: table__get_column_ix

        has_component       :: table__has_entity

        //
        // Pairs
        //

        pair_init       :: pair_table__init
        pair_terminate  :: pair_table__terminate

        pair_add        :: pair_table__add
        pair_remove     :: pair_table__remove
        pair_remove_all :: pair_table__remove_all

        pair_has_pair   :: pair_table__has_pair
        pair_has_any    :: pair_table__has_any
        pair_first_target :: pair_table__first_target
        pair_first_data   :: pair_table__first_data
        pair_targets_of   :: pair_table__targets_of

        //
        // Other
        //

        clear               :: proc {
            database__clear,
            table__clear,
            relations_table__clear,
            sync_channel__clear,
        }

        pack                :: proc {
            table__pack,
        }

        pause_packing       :: proc {
            database__pause_packing,
            table__pause_packing,
        }

        resume_packing      :: proc {
            database__resume_packing,
            table__resume_packing,
        }

        table_len           :: proc {
            table__len,
            relations_table__len,
            pair_table__len,
        }

        table_cap           :: proc {
            table__cap,
            relations_table__cap,
            pair_table__cap,
        }

        entities_slice :: proc {
            table__entities_slice,
        }

        slice :: proc {
            table__column_slice,   // slice(&table, T) -> []T 
            table__entities_slice, // slice(&table) -> []entity_id
        }

        // Memory in bytes
        memory_usage        :: proc {
            database__memory_usage,
            overbase__memory_usage,
            table__memory_usage,
            relations_table__memory_usage,
            sync_channel__memory_usage,
            sync_decoder__memory_usage,
            pair_table__memory_usage,
        }

        is_valid            :: proc {
            database__is_valid,
            overbase__is_valid,
            table__is_valid,
            relations_table__is_valid,
            sync_channel__is_valid,
            sync_decoder__is_valid,
            pair_table__is_valid,
        }

///////////////////////////////////////////////////////////////////////////////
// Basic types

    //
    // IDs
    //

        entity_id ::            oc.ix_gen
        table_id ::             distinct int
        table_record_id ::      distinct int
        pair_table_id ::        distinct int

    //
    // Enums
    //

        Object_State :: enum {
            Not_Initialized = 0,
            Normal,
            Invalid,
            Terminated,
        }

        // ECS specific errors
        API_Error :: enum {
            None = 0,
            Entities_Cap_Should_Be_Greater_Than_Zero,
            Component_Already_Exist,
            Tables_Array_Should_Not_Be_Empty,
            Unexpected_Error,
            Entity_Id_Out_of_Bounds,
            Entity_Id_Expired,
            Object_Invalid,
            Component_Size_Cannot_Be_Zero,
            Relations_Table_Already_Exists,
            Relations_Table_Not_Created,
            Relation_Cycle,
            Snapshot_Invalid,
            Snapshot_Version_Mismatch,
            Snapshot_Schema_Mismatch,
            Snapshot_Capacity_Too_Small,
            Snapshot_Component_Not_POD,
            Cannot_Serialize_While_Packing_Paused,
            Serialize_Buffer_Too_Small,
            File_Error,
            Sync_Too_Many_Fields,
            Sync_Table_Already_Registered,
            Sync_Buffer_Too_Small,
            Sync_Feature_Disabled,
            Entity_Already_In_Table,
            Entity_Not_In_Table,
            Table_To_Cannot_Contain_Entity,
        }

        Error :: union #shared_nil {
            API_Error,
            oc.Core_Error,
            oc.Error,
            runtime.Allocator_Error
        }

///////////////////////////////////////////////////////////////////////////////
// Globals

    is_not_set :: #force_inline proc "contextless" (e: entity_id) -> bool {
        return e.ix == DELETED_INDEX
    }
