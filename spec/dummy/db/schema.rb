# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_08_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gin"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "actor_experiences", force: :cascade do |t|
    t.bigint "actor_id", null: false
    t.datetime "created_at", null: false
    t.bigint "experience_id", null: false
    t.string "relation_type", default: "participates_in"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["actor_id", "experience_id"], name: "index_actor_experiences_on_actor_id_and_experience_id", unique: true
    t.index ["actor_id"], name: "index_actor_experiences_on_actor_id"
    t.index ["experience_id"], name: "index_actor_experiences_on_experience_id"
  end

  create_table "actor_manifests", force: :cascade do |t|
    t.bigint "actor_id", null: false
    t.datetime "created_at", null: false
    t.bigint "manifest_id", null: false
    t.string "relation_type", default: "interacts_with"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["actor_id", "manifest_id"], name: "index_actor_manifests_on_actor_id_and_manifest_id", unique: true
    t.index ["actor_id"], name: "index_actor_manifests_on_actor_id"
    t.index ["manifest_id"], name: "index_actor_manifests_on_manifest_id"
  end

  create_table "actors", force: :cascade do |t|
    t.jsonb "affiliations", default: []
    t.jsonb "capabilities", default: []
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.jsonb "permissions"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.string "role"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["name"], name: "index_actors_on_name"
    t.index ["provenance_and_rights_id"], name: "index_actors_on_provenance_and_rights_id"
    t.index ["role"], name: "index_actors_on_role"
    t.index ["valid_time_start", "valid_time_end"], name: "index_actors_on_valid_time_start_and_valid_time_end"
  end

  create_table "ahoy_events", force: :cascade do |t|
    t.string "name"
    t.jsonb "properties"
    t.datetime "time"
    t.bigint "user_id"
    t.bigint "visit_id"
    t.index ["name", "time"], name: "index_ahoy_events_on_name_and_time"
    t.index ["properties"], name: "index_ahoy_events_on_properties", opclass: :jsonb_path_ops, using: :gin
    t.index ["user_id"], name: "index_ahoy_events_on_user_id"
    t.index ["visit_id"], name: "index_ahoy_events_on_visit_id"
  end

  create_table "ahoy_visits", force: :cascade do |t|
    t.string "app_version"
    t.string "browser"
    t.string "city"
    t.string "country"
    t.string "device_type"
    t.string "ip"
    t.text "landing_page"
    t.float "latitude"
    t.float "longitude"
    t.string "os"
    t.string "os_version"
    t.string "platform"
    t.text "referrer"
    t.string "referring_domain"
    t.string "region"
    t.datetime "started_at"
    t.text "user_agent"
    t.bigint "user_id"
    t.string "utm_campaign"
    t.string "utm_content"
    t.string "utm_medium"
    t.string "utm_source"
    t.string "utm_term"
    t.string "visit_token"
    t.string "visitor_token"
    t.index ["user_id"], name: "index_ahoy_visits_on_user_id"
    t.index ["visit_token"], name: "index_ahoy_visits_on_visit_token", unique: true
    t.index ["visitor_token", "started_at"], name: "index_ahoy_visits_on_visitor_token_and_started_at"
  end

  create_table "api_calls", force: :cascade do |t|
    t.float "audio_duration"
    t.string "batch_id"
    t.boolean "cached_response", default: false
    t.integer "cached_tokens"
    t.integer "completion_tokens"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.bigint "ekn_id"
    t.string "endpoint", null: false
    t.string "environment"
    t.string "error_code"
    t.jsonb "error_details", default: {}
    t.text "error_message"
    t.integer "image_count"
    t.string "image_quality"
    t.string "image_size"
    t.decimal "input_cost", precision: 12, scale: 8
    t.jsonb "metadata", default: {}
    t.string "model_used"
    t.string "model_version"
    t.decimal "output_cost", precision: 12, scale: 8
    t.float "processing_time_ms"
    t.integer "prompt_tokens"
    t.float "queue_time_ms"
    t.integer "reasoning_tokens"
    t.string "request_id"
    t.jsonb "request_params", default: {}
    t.string "response_cache_key"
    t.jsonb "response_data", default: {}
    t.jsonb "response_headers", default: {}
    t.float "response_time_ms"
    t.string "response_type"
    t.integer "retry_count", default: 0
    t.string "service_name", null: false
    t.string "session_id"
    t.string "status", default: "pending", null: false
    t.decimal "total_cost", precision: 12, scale: 8
    t.integer "total_tokens"
    t.bigint "trackable_id"
    t.string "trackable_type"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "voice_id"
    t.index ["batch_id"], name: "index_api_calls_on_batch_id"
    t.index ["created_at"], name: "index_api_calls_on_created_at"
    t.index ["ekn_id", "created_at"], name: "index_api_calls_on_ekn_id_and_created_at"
    t.index ["ekn_id", "endpoint"], name: "index_api_calls_on_ekn_id_and_endpoint"
    t.index ["ekn_id"], name: "index_api_calls_on_ekn_id"
    t.index ["model_used"], name: "index_api_calls_on_model_used"
    t.index ["request_id"], name: "index_api_calls_on_request_id"
    t.index ["service_name", "status", "created_at"], name: "index_api_calls_on_service_name_and_status_and_created_at"
    t.index ["service_name"], name: "index_api_calls_on_service_name"
    t.index ["session_id", "created_at"], name: "index_api_calls_on_session_id_and_created_at"
    t.index ["session_id"], name: "index_api_calls_on_session_id"
    t.index ["status"], name: "index_api_calls_on_status"
    t.index ["trackable_type", "trackable_id"], name: "idx_api_calls_trackable"
    t.index ["trackable_type", "trackable_id"], name: "index_api_calls_on_trackable"
    t.index ["type", "created_at"], name: "index_api_calls_on_type_and_created_at"
    t.index ["type", "model_used", "created_at"], name: "index_api_calls_on_type_and_model_used_and_created_at"
    t.index ["type"], name: "index_api_calls_on_type"
    t.index ["user_id", "created_at"], name: "index_api_calls_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_api_calls_on_user_id"
  end

  create_table "characters", force: :cascade do |t|
    t.boolean "active"
    t.integer "batch_id"
    t.text "biography"
    t.datetime "created_at", null: false
    t.string "entity_id"
    t.boolean "has_agency"
    t.string "label"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text"
    t.string "role_type"
    t.string "title"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_characters_on_provenance_and_rights_id"
  end

  create_table "conversation_histories", force: :cascade do |t|
    t.text "content"
    t.string "conversation_id"
    t.datetime "created_at", null: false
    t.jsonb "metadata"
    t.integer "position"
    t.string "role"
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.index ["conversation_id"], name: "index_conversation_histories_on_conversation_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.jsonb "context", default: {}
    t.datetime "created_at", null: false
    t.bigint "ekn_id"
    t.string "expertise_level"
    t.bigint "ingest_batch_id"
    t.datetime "last_activity_at"
    t.jsonb "model_config", default: {}
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["ekn_id"], name: "index_conversations_on_ekn_id"
    t.index ["ingest_batch_id"], name: "index_conversations_on_ingest_batch_id"
    t.index ["last_activity_at"], name: "index_conversations_on_last_activity_at"
    t.index ["status"], name: "index_conversations_on_status"
  end

  create_table "ekn_personality_profiles", force: :cascade do |t|
    t.string "base_archetype"
    t.json "canonical_vocabulary"
    t.json "communication_signature", default: {}
    t.datetime "created_at", null: false
    t.json "domain_expertise"
    t.bigint "ekn_id", null: false
    t.json "evolution_history"
    t.json "expertise_depth_map", default: {}
    t.json "interaction_patterns"
    t.json "knowledge_sources_fingerprint"
    t.datetime "last_significant_change_at"
    t.json "learning_adaptation_style", default: {}
    t.json "mcp_tool_preferences", default: {}
    t.integer "personality_version", default: 1, null: false
    t.json "query_transformation_style", default: {}
    t.json "relationship_styles"
    t.json "response_patterns"
    t.json "ten_pool_preferences"
    t.datetime "updated_at", null: false
    t.json "visualization_driving_patterns", default: {}
    t.json "voice_characteristics"
    t.index ["base_archetype"], name: "index_ekn_personality_profiles_on_base_archetype"
    t.index ["ekn_id"], name: "index_ekn_personality_profiles_on_ekn_id", unique: true
    t.index ["last_significant_change_at"], name: "index_ekn_personality_profiles_on_last_significant_change_at"
    t.index ["personality_version"], name: "index_ekn_personality_profiles_on_personality_version"
  end

  create_table "ekn_pipeline_runs", force: :cascade do |t|
    t.boolean "auto_advance", default: true
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "current_stage"
    t.integer "current_stage_number", default: 0
    t.bigint "ekn_id", null: false
    t.jsonb "error_details", default: {}
    t.text "error_message"
    t.string "failed_stage"
    t.bigint "ingest_batch_id", null: false
    t.datetime "last_retry_at"
    t.float "literacy_score"
    t.jsonb "options", default: {}
    t.integer "retry_count", default: 0
    t.boolean "skip_failed_items", default: false
    t.datetime "stage_completed_at"
    t.jsonb "stage_metrics", default: {}
    t.datetime "stage_started_at"
    t.jsonb "stage_statuses", default: {}
    t.datetime "started_at"
    t.string "status", default: "initialized", null: false
    t.integer "total_items_processed", default: 0
    t.integer "total_nodes_created", default: 0
    t.integer "total_relationships_created", default: 0
    t.datetime "updated_at", null: false
    t.index ["current_stage"], name: "index_ekn_pipeline_runs_on_current_stage"
    t.index ["ekn_id", "created_at"], name: "index_ekn_pipeline_runs_on_ekn_id_and_created_at"
    t.index ["ekn_id", "status"], name: "index_ekn_pipeline_runs_on_ekn_id_and_status"
    t.index ["ekn_id"], name: "index_ekn_pipeline_runs_on_ekn_id"
    t.index ["ingest_batch_id"], name: "index_ekn_pipeline_runs_on_ingest_batch_id"
    t.index ["status"], name: "index_ekn_pipeline_runs_on_status"
  end

  create_table "ekns", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "domain_type", default: "general"
    t.float "literacy_score"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "personality", default: "friendly"
    t.integer "session_id"
    t.jsonb "settings", default: {}
    t.string "slug"
    t.string "status", default: "initializing"
    t.integer "total_items", default: 0
    t.integer "total_nodes", default: 0
    t.integer "total_relationships", default: 0
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "visibility", default: "private", null: false
    t.index ["metadata"], name: "index_ekns_on_metadata", using: :gin
    t.index ["session_id"], name: "index_ekns_on_session_id"
    t.index ["slug"], name: "index_ekns_on_slug", unique: true
    t.index ["status"], name: "index_ekns_on_status"
    t.index ["user_id", "visibility"], name: "index_ekns_on_user_id_and_visibility"
    t.index ["user_id"], name: "index_ekns_on_user_id"
    t.index ["visibility"], name: "index_ekns_on_visibility"
  end

  create_table "emanation_ideas", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "emanation_id", null: false
    t.bigint "idea_id", null: false
    t.string "relation_type"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["emanation_id", "idea_id", "relation_type"], name: "index_eman_idea_on_ids_and_type", unique: true
    t.index ["emanation_id"], name: "index_emanation_ideas_on_emanation_id"
    t.index ["idea_id"], name: "index_emanation_ideas_on_idea_id"
  end

  create_table "emanation_relationals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "emanation_id", null: false
    t.string "relation_type", default: "diffuses_through"
    t.bigint "relational_id", null: false
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["emanation_id", "relational_id"], name: "index_emanation_relationals_on_emanation_id_and_relational_id", unique: true
    t.index ["emanation_id"], name: "index_emanation_relationals_on_emanation_id"
    t.index ["relational_id"], name: "index_emanation_relationals_on_relational_id"
  end

  create_table "emanations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "directness", default: 0, null: false
    t.text "evidence"
    t.integer "evidence_quality", default: 0, null: false
    t.jsonb "evidence_refs", default: []
    t.integer "impact_level", default: 0, null: false
    t.string "influence_type", null: false
    t.text "pathway"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.float "strength"
    t.text "target_context"
    t.jsonb "temporal_extent", default: {}
    t.integer "temporal_scope", default: 0, null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["evidence_quality"], name: "index_emanations_on_evidence_quality"
    t.index ["impact_level"], name: "index_emanations_on_impact_level"
    t.index ["influence_type"], name: "index_emanations_on_influence_type"
    t.index ["provenance_and_rights_id"], name: "index_emanations_on_provenance_and_rights_id"
    t.index ["temporal_scope"], name: "index_emanations_on_temporal_scope"
    t.index ["valid_time_start", "valid_time_end"], name: "index_emanations_on_valid_time_start_and_valid_time_end"
  end

  create_table "enliterator_claims", force: :cascade do |t|
    t.string "attributed_to"
    t.float "confidence"
    t.datetime "created_at", null: false
    t.jsonb "derived_from", default: []
    t.string "key", null: false
    t.boolean "locked", default: false, null: false
    t.string "review_state", default: "pending", null: false
    t.string "status", default: "draft", null: false
    t.bigint "superseded_by_id"
    t.string "tendable_id", null: false
    t.string "tendable_type", null: false
    t.string "tier"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.bigint "visit_id"
    t.index ["superseded_by_id"], name: "idx_enliterator_claims_on_superseded_by_id"
    t.index ["tendable_type", "tendable_id", "key"], name: "idx_enliterator_claims_on_tendable_and_key"
  end

  create_table "enliterator_embeddings", force: :cascade do |t|
    t.string "content_hash"
    t.datetime "created_at", null: false
    t.integer "dimensions"
    t.string "embeddable_id", null: false
    t.string "embeddable_type", null: false
    t.vector "embedding", limit: 1536
    t.string "kind", default: "primary", null: false
    t.string "model"
    t.datetime "updated_at", null: false
    t.index ["embeddable_type", "embeddable_id", "kind"], name: "idx_enliterator_embeddings_on_embeddable_and_kind", unique: true
    t.index ["embedding"], name: "idx_enliterator_embeddings_on_embedding_hnsw", opclass: :vector_cosine_ops, using: :hnsw
  end

  create_table "enliterator_facets", force: :cascade do |t|
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.float "score"
    t.jsonb "signals", default: {}
    t.string "tendable_id", null: false
    t.string "tendable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["tendable_type", "tendable_id", "name"], name: "idx_enliterator_facets_on_tendable_and_name", unique: true
  end

  create_table "enliterator_suggestions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "example_value", default: {}
    t.string "mapped_to"
    t.string "model"
    t.string "proposed_key"
    t.text "rationale"
    t.text "review_note"
    t.string "status", default: "pending", null: false
    t.string "stream"
    t.string "tendable_id"
    t.string "tendable_type"
    t.string "tier"
    t.datetime "updated_at", null: false
    t.bigint "visit_id"
    t.index ["proposed_key", "status"], name: "idx_enliterator_suggestions_on_key_and_status"
    t.index ["stream", "status"], name: "idx_enliterator_suggestions_on_stream_and_status"
    t.index ["tendable_type", "tendable_id"], name: "idx_enliterator_suggestions_on_tendable"
  end

  create_table "enliterator_visits", force: :cascade do |t|
    t.boolean "applied", default: true, null: false
    t.float "confidence"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error"
    t.bigint "escalated_from_id"
    t.integer "escalation_step", default: 0, null: false
    t.datetime "finished_at"
    t.jsonb "input_refs", default: {}
    t.string "model"
    t.string "prompt_version"
    t.jsonb "raw_response", default: {}
    t.jsonb "reconciliation", default: {}
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.string "stream", null: false
    t.string "tendable_id", null: false
    t.string "tendable_type", null: false
    t.string "tier"
    t.jsonb "tokens", default: {}
    t.datetime "updated_at", null: false
    t.index ["tendable_type", "tendable_id", "created_at"], name: "idx_enliterator_visits_on_tendable_and_created_at"
    t.index ["tendable_type", "tendable_id", "stream"], name: "idx_enliterator_visits_on_tendable_and_stream"
    t.index ["tendable_type", "tendable_id", "tier"], name: "idx_enliterator_visits_on_tendable_and_tier"
  end

  create_table "evidence_experiences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "evidence_id", null: false
    t.bigint "experience_id", null: false
    t.string "relation_type", default: "supports"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["evidence_id", "experience_id"], name: "index_evidence_experiences_on_evidence_id_and_experience_id", unique: true
    t.index ["evidence_id"], name: "index_evidence_experiences_on_evidence_id"
    t.index ["experience_id"], name: "index_evidence_experiences_on_experience_id"
  end

  create_table "evidences", force: :cascade do |t|
    t.float "confidence_score"
    t.jsonb "corroboration", default: []
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "evidence_type", null: false
    t.datetime "observed_at", null: false
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.jsonb "source_refs", default: []
    t.datetime "updated_at", null: false
    t.index ["confidence_score"], name: "index_evidences_on_confidence_score"
    t.index ["evidence_type"], name: "index_evidences_on_evidence_type"
    t.index ["observed_at"], name: "index_evidences_on_observed_at"
    t.index ["provenance_and_rights_id"], name: "index_evidences_on_provenance_and_rights_id"
  end

  create_table "evolutionaries", force: :cascade do |t|
    t.text "change_note", null: false
    t.text "change_summary", null: false
    t.datetime "created_at", null: false
    t.jsonb "delta_metrics", default: {}
    t.bigint "manifest_version_id"
    t.bigint "prior_ref_id"
    t.string "prior_ref_type"
    t.bigint "provenance_and_rights_id", null: false
    t.bigint "refined_idea_id"
    t.text "repr_text", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.string "version_id"
    t.index ["manifest_version_id"], name: "index_evolutionaries_on_manifest_version_id"
    t.index ["prior_ref_type", "prior_ref_id"], name: "index_evolutionaries_on_prior_ref"
    t.index ["prior_ref_type", "prior_ref_id"], name: "index_evolutionaries_on_prior_ref_type_and_prior_ref_id"
    t.index ["provenance_and_rights_id"], name: "index_evolutionaries_on_provenance_and_rights_id"
    t.index ["refined_idea_id"], name: "index_evolutionaries_on_refined_idea_id"
    t.index ["valid_time_start", "valid_time_end"], name: "index_evolutionaries_on_valid_time_start_and_valid_time_end"
    t.index ["version_id"], name: "index_evolutionaries_on_version_id"
  end

  create_table "experience_emanations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "emanation_id", null: false
    t.bigint "experience_id", null: false
    t.string "relation_type", default: "inspires"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["emanation_id"], name: "index_experience_emanations_on_emanation_id"
    t.index ["experience_id", "emanation_id"], name: "index_experience_emanations_on_experience_id_and_emanation_id", unique: true
    t.index ["experience_id"], name: "index_experience_emanations_on_experience_id"
  end

  create_table "experience_practicals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "experience_id", null: false
    t.bigint "practical_id", null: false
    t.string "relation_type"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["experience_id", "practical_id", "relation_type"], name: "index_exp_prac_on_ids_and_type", unique: true
    t.index ["experience_id"], name: "index_experience_practicals_on_experience_id"
    t.index ["practical_id"], name: "index_experience_practicals_on_practical_id"
  end

  create_table "experiences", force: :cascade do |t|
    t.bigint "actor_id"
    t.string "agent_label"
    t.text "context"
    t.datetime "created_at", null: false
    t.integer "emotional_intensity", default: 0, null: false
    t.integer "experience_type", default: 0, null: false
    t.text "narrative_text", null: false
    t.datetime "observed_at", null: false
    t.integer "privacy_level", default: 0, null: false
    t.bigint "provenance_and_rights_id", null: false
    t.integer "reliability_level", default: 0, null: false
    t.text "repr_text", null: false
    t.string "sentiment"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_experiences_on_actor_id"
    t.index ["agent_label"], name: "index_experiences_on_agent_label"
    t.index ["emotional_intensity"], name: "index_experiences_on_emotional_intensity"
    t.index ["experience_type"], name: "index_experiences_on_experience_type"
    t.index ["narrative_text"], name: "index_experiences_on_narrative_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["observed_at"], name: "index_experiences_on_observed_at"
    t.index ["privacy_level"], name: "index_experiences_on_privacy_level"
    t.index ["provenance_and_rights_id"], name: "index_experiences_on_provenance_and_rights_id"
    t.index ["reliability_level"], name: "index_experiences_on_reliability_level"
    t.index ["sentiment"], name: "index_experiences_on_sentiment"
  end

  create_table "feedback_responses", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.bigint "feedback_id", null: false
    t.boolean "internal", default: false
    t.string "new_status"
    t.boolean "read", default: false
    t.boolean "status_changed", default: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["created_at"], name: "index_feedback_responses_on_created_at"
    t.index ["feedback_id"], name: "index_feedback_responses_on_feedback_id"
    t.index ["read"], name: "index_feedback_responses_on_read"
    t.index ["user_id"], name: "index_feedback_responses_on_user_id"
  end

  create_table "feedbacks", force: :cascade do |t|
    t.string "browser_info"
    t.integer "category", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.jsonb "metadata", default: {}
    t.string "page_url"
    t.integer "priority", default: 2
    t.datetime "resolved_at"
    t.bigint "resolved_by_id"
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["category"], name: "index_feedbacks_on_category"
    t.index ["created_at"], name: "index_feedbacks_on_created_at"
    t.index ["priority"], name: "index_feedbacks_on_priority"
    t.index ["resolved_by_id"], name: "index_feedbacks_on_resolved_by_id"
    t.index ["status"], name: "index_feedbacks_on_status"
    t.index ["user_id"], name: "index_feedbacks_on_user_id"
  end

  create_table "fine_tune_jobs", force: :cascade do |t|
    t.string "base_model", null: false
    t.datetime "created_at", null: false
    t.string "dataset_path"
    t.text "error_message"
    t.integer "example_count"
    t.string "fine_tuned_model"
    t.datetime "finished_at"
    t.jsonb "hyperparameters", default: {}
    t.bigint "ingest_batch_id"
    t.string "openai_file_id"
    t.string "openai_job_id", null: false
    t.datetime "started_at"
    t.string "status", null: false
    t.integer "trained_tokens"
    t.decimal "training_cost", precision: 10, scale: 4
    t.jsonb "training_metrics", default: {}
    t.datetime "updated_at", null: false
    t.index ["fine_tuned_model"], name: "index_fine_tune_jobs_on_fine_tuned_model"
    t.index ["ingest_batch_id"], name: "index_fine_tune_jobs_on_ingest_batch_id"
    t.index ["openai_job_id"], name: "index_fine_tune_jobs_on_openai_job_id", unique: true
    t.index ["status"], name: "index_fine_tune_jobs_on_status"
  end

  create_table "friendly_id_slugs", force: :cascade do |t|
    t.datetime "created_at"
    t.string "scope"
    t.string "slug", null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true
    t.index ["slug", "sluggable_type"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type"
    t.index ["sluggable_type", "sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_type_and_sluggable_id"
  end

  create_table "idea_emanations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "emanation_id", null: false
    t.bigint "idea_id", null: false
    t.string "relation_type", default: "influences"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["emanation_id"], name: "index_idea_emanations_on_emanation_id"
    t.index ["idea_id", "emanation_id"], name: "index_idea_emanations_on_idea_id_and_emanation_id", unique: true
    t.index ["idea_id"], name: "index_idea_emanations_on_idea_id"
  end

  create_table "idea_manifests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "idea_id", null: false
    t.bigint "manifest_id", null: false
    t.string "relation_type", default: "embodies"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["idea_id", "manifest_id"], name: "index_idea_manifests_on_idea_id_and_manifest_id", unique: true
    t.index ["idea_id"], name: "index_idea_manifests_on_idea_id"
    t.index ["manifest_id"], name: "index_idea_manifests_on_manifest_id"
  end

  create_table "idea_practicals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "idea_id", null: false
    t.bigint "practical_id", null: false
    t.string "relation_type", default: "codifies"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["idea_id", "practical_id"], name: "index_idea_practicals_on_idea_id_and_practical_id", unique: true
    t.index ["idea_id"], name: "index_idea_practicals_on_idea_id"
    t.index ["practical_id"], name: "index_idea_practicals_on_practical_id"
  end

  create_table "ideas", force: :cascade do |t|
    t.text "abstract", null: false
    t.string "authorship"
    t.datetime "created_at", null: false
    t.integer "idea_type", default: 0, null: false
    t.date "inception_date", null: false
    t.boolean "is_canonical", default: false, null: false
    t.string "label", null: false
    t.integer "maturity_level", default: 0, null: false
    t.jsonb "principle_tags", default: []
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.integer "scope", default: 0, null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["abstract"], name: "index_ideas_on_abstract_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["idea_type"], name: "index_ideas_on_idea_type"
    t.index ["is_canonical"], name: "index_ideas_on_is_canonical"
    t.index ["label"], name: "index_ideas_on_label"
    t.index ["label"], name: "index_ideas_on_label_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["maturity_level"], name: "index_ideas_on_maturity_level"
    t.index ["principle_tags"], name: "index_ideas_on_principle_tags", using: :gin
    t.index ["provenance_and_rights_id"], name: "index_ideas_on_provenance_and_rights_id"
    t.index ["scope"], name: "index_ideas_on_scope"
    t.index ["valid_time_start", "valid_time_end"], name: "index_ideas_on_valid_time_start_and_valid_time_end"
  end

  create_table "ingest_batches", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.jsonb "deliverables"
    t.text "deliverables_errors"
    t.datetime "deliverables_generated_at"
    t.string "deliverables_path"
    t.bigint "ekn_id"
    t.string "fine_tune_dataset_path"
    t.string "fine_tune_job_id"
    t.datetime "graph_assembled_at"
    t.jsonb "graph_assembly_stats"
    t.jsonb "graph_metadata", default: {}
    t.jsonb "literacy_gaps"
    t.decimal "literacy_score"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "source_type", null: false
    t.datetime "started_at"
    t.jsonb "statistics", default: {}
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_ingest_batches_on_created_at"
    t.index ["ekn_id"], name: "index_ingest_batches_on_ekn_id"
    t.index ["source_type"], name: "index_ingest_batches_on_source_type"
    t.index ["status"], name: "index_ingest_batches_on_status"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])", name: "check_status_values"
  end

  create_table "ingest_items", force: :cascade do |t|
    t.text "content"
    t.integer "content_length_chars"
    t.text "content_sample"
    t.datetime "created_at", null: false
    t.jsonb "embedding_metadata"
    t.string "embedding_status"
    t.integer "estimated_tokens"
    t.string "extraction_method"
    t.string "extraction_model_used"
    t.string "file_hash"
    t.string "file_path", null: false
    t.integer "file_size"
    t.jsonb "graph_metadata"
    t.string "graph_status"
    t.bigint "ingest_batch_id", null: false
    t.jsonb "lexicon_metadata", default: {}
    t.string "lexicon_status", default: "pending"
    t.json "markitdown_metadata"
    t.string "media_type", default: "unknown", null: false
    t.jsonb "metadata", default: {}
    t.bigint "pool_item_id"
    t.string "pool_item_type"
    t.jsonb "pool_metadata", default: {}
    t.string "pool_status", default: "pending"
    t.bigint "provenance_and_rights_id"
    t.boolean "publishable"
    t.string "quarantine_reason"
    t.boolean "quarantined"
    t.string "routing_tier"
    t.bigint "size_bytes"
    t.string "source_hash", null: false
    t.string "source_type"
    t.boolean "training_eligible"
    t.string "triage_error"
    t.jsonb "triage_metadata", default: {}
    t.string "triage_status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["extraction_method"], name: "index_ingest_items_on_extraction_method"
    t.index ["ingest_batch_id"], name: "index_ingest_items_on_ingest_batch_id"
    t.index ["lexicon_status"], name: "index_ingest_items_on_lexicon_status"
    t.index ["media_type"], name: "index_ingest_items_on_media_type"
    t.index ["pool_item_type", "pool_item_id"], name: "index_ingest_items_on_pool_item"
    t.index ["pool_item_type", "pool_item_id"], name: "index_ingest_items_on_pool_item_type_and_pool_item_id"
    t.index ["pool_status"], name: "index_ingest_items_on_pool_status"
    t.index ["provenance_and_rights_id"], name: "index_ingest_items_on_provenance_and_rights_id"
    t.index ["routing_tier"], name: "index_ingest_items_on_routing_tier"
    t.index ["source_hash"], name: "index_ingest_items_on_source_hash", unique: true
    t.index ["triage_status"], name: "index_ingest_items_on_triage_status"
  end

  create_table "intent_and_tasks", force: :cascade do |t|
    t.string "adapter_name"
    t.jsonb "adapter_params", default: {}
    t.jsonb "constraints", default: {}
    t.datetime "created_at", null: false
    t.string "deliverable_type"
    t.jsonb "evaluation", default: {}
    t.jsonb "metadata", default: {}
    t.string "modality"
    t.jsonb "normalized_intent", default: {}
    t.datetime "observed_at", null: false
    t.string "outcome_signal"
    t.jsonb "presentation_preference", default: {}
    t.bigint "provenance_and_rights_id", null: false
    t.text "query_text"
    t.text "raw_intent"
    t.text "repr_text", null: false
    t.datetime "resolved_at"
    t.integer "status", default: 0, null: false
    t.jsonb "success_criteria", default: {}
    t.datetime "updated_at", null: false
    t.text "user_goal", null: false
    t.bigint "user_session_id"
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["deliverable_type"], name: "index_intent_and_tasks_on_deliverable_type"
    t.index ["modality"], name: "index_intent_and_tasks_on_modality"
    t.index ["observed_at"], name: "index_intent_and_tasks_on_observed_at"
    t.index ["provenance_and_rights_id"], name: "index_intent_and_tasks_on_provenance_and_rights_id"
    t.index ["resolved_at"], name: "index_intent_and_tasks_on_resolved_at"
    t.index ["status"], name: "index_intent_and_tasks_on_status"
  end

  create_table "interview_sessions", force: :cascade do |t|
    t.boolean "completed"
    t.datetime "created_at", null: false
    t.jsonb "data"
    t.string "session_id"
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_interview_sessions_on_session_id"
  end

  create_table "lexicon_and_ontologies", force: :cascade do |t|
    t.text "canonical_description"
    t.datetime "created_at", null: false
    t.text "definition"
    t.boolean "is_canonical", default: false, null: false
    t.jsonb "negative_surface_forms", default: []
    t.string "pool_association", null: false
    t.string "pool_association_type"
    t.bigint "provenance_and_rights_id", null: false
    t.jsonb "relations", default: {}
    t.text "repr_text", null: false
    t.string "schema_version"
    t.jsonb "surface_forms", default: []
    t.string "term", null: false
    t.integer "term_type", default: 0, null: false
    t.jsonb "type_mapping", default: {}
    t.string "unit_system"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["negative_surface_forms"], name: "index_lexicon_and_ontologies_on_negative_surface_forms", using: :gin
    t.index ["pool_association_type"], name: "index_lexicon_and_ontologies_on_pool_association_type"
    t.index ["provenance_and_rights_id"], name: "index_lexicon_and_ontologies_on_provenance_and_rights_id"
    t.index ["surface_forms"], name: "index_lexicon_and_ontologies_on_surface_forms", using: :gin
    t.index ["term"], name: "index_lexicon_and_ontologies_on_term", unique: true
    t.index ["term_type"], name: "index_lexicon_and_ontologies_on_term_type"
    t.index ["valid_time_start", "valid_time_end"], name: "idx_on_valid_time_start_valid_time_end_5b95b14d20"
  end

  create_table "lifecycles", force: :cascade do |t|
    t.integer "batch_id"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "entity_id"
    t.boolean "is_active"
    t.string "label"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text"
    t.integer "sequence_order"
    t.string "stage_type"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_lifecycles_on_provenance_and_rights_id"
  end

  create_table "log_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "item_data"
    t.bigint "log_id", null: false
    t.string "log_label"
    t.integer "num"
    t.string "status"
    t.text "text"
    t.datetime "updated_at", null: false
    t.uuid "uuid", null: false
    t.index ["log_id"], name: "index_log_items_on_log_id"
    t.index ["uuid"], name: "index_log_items_on_uuid", unique: true
  end

  create_table "logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label"
    t.bigint "loggable_id", null: false
    t.string "loggable_type", null: false
    t.datetime "updated_at", null: false
    t.uuid "uuid", null: false
    t.index ["loggable_type", "loggable_id"], name: "index_logs_on_loggable"
    t.index ["uuid"], name: "index_logs_on_uuid", unique: true
  end

  create_table "manifest_experiences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "experience_id", null: false
    t.bigint "manifest_id", null: false
    t.string "relation_type", default: "elicits"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["experience_id"], name: "index_manifest_experiences_on_experience_id"
    t.index ["manifest_id", "experience_id"], name: "index_manifest_experiences_on_manifest_id_and_experience_id", unique: true
    t.index ["manifest_id"], name: "index_manifest_experiences_on_manifest_id"
  end

  create_table "manifest_spatials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "manifest_id", null: false
    t.string "relation_type", default: "located_at"
    t.bigint "spatial_id", null: false
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["manifest_id", "spatial_id"], name: "index_manifest_spatials_on_manifest_id_and_spatial_id", unique: true
    t.index ["manifest_id"], name: "index_manifest_spatials_on_manifest_id"
    t.index ["spatial_id"], name: "index_manifest_spatials_on_spatial_id"
  end

  create_table "manifests", force: :cascade do |t|
    t.integer "accessibility_level", default: 0, null: false
    t.integer "artifact_category", default: 0, null: false
    t.integer "completion_status", default: 0, null: false
    t.jsonb "components", default: []
    t.datetime "created_at", null: false
    t.integer "format_type", default: 0, null: false
    t.string "label", null: false
    t.string "manifest_type"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.string "spatial_ref"
    t.jsonb "time_bounds", default: {}
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["accessibility_level"], name: "index_manifests_on_accessibility_level"
    t.index ["artifact_category"], name: "index_manifests_on_artifact_category"
    t.index ["completion_status"], name: "index_manifests_on_completion_status"
    t.index ["components"], name: "index_manifests_on_components", using: :gin
    t.index ["format_type"], name: "index_manifests_on_format_type"
    t.index ["label"], name: "index_manifests_on_label"
    t.index ["label"], name: "index_manifests_on_label_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["manifest_type"], name: "index_manifests_on_manifest_type"
    t.index ["provenance_and_rights_id"], name: "index_manifests_on_provenance_and_rights_id"
    t.index ["spatial_ref"], name: "index_manifests_on_spatial_ref"
    t.index ["valid_time_start", "valid_time_end"], name: "index_manifests_on_valid_time_start_and_valid_time_end"
  end

  create_table "mcp_intelligent_test_runs", force: :cascade do |t|
    t.json "agent_context"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.bigint "ekn_id", null: false
    t.text "error_message"
    t.json "evaluation_results"
    t.string "evaluator_type", null: false
    t.bigint "mcp_test_case_id", null: false
    t.bigint "mcp_test_run_id", null: false
    t.float "overall_score"
    t.json "performance_metrics"
    t.datetime "started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["ekn_id", "completed_at"], name: "index_mcp_intelligent_test_runs_on_ekn_id_and_completed_at"
    t.index ["ekn_id"], name: "index_mcp_intelligent_test_runs_on_ekn_id"
    t.index ["evaluator_type"], name: "index_mcp_intelligent_test_runs_on_evaluator_type"
    t.index ["mcp_test_case_id"], name: "index_mcp_intelligent_test_runs_on_mcp_test_case_id"
    t.index ["mcp_test_run_id", "status"], name: "index_mcp_intelligent_test_runs_on_mcp_test_run_id_and_status"
    t.index ["mcp_test_run_id"], name: "index_mcp_intelligent_test_runs_on_mcp_test_run_id"
    t.index ["overall_score"], name: "index_mcp_intelligent_test_runs_on_overall_score"
    t.index ["status"], name: "index_mcp_intelligent_test_runs_on_status"
  end

  create_table "mcp_test_cases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.json "expectations"
    t.bigint "mcp_test_suite_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.json "variable_overrides"
    t.index ["enabled"], name: "index_mcp_test_cases_on_enabled"
    t.index ["mcp_test_suite_id", "name"], name: "index_mcp_test_cases_on_mcp_test_suite_id_and_name", unique: true
    t.index ["mcp_test_suite_id"], name: "index_mcp_test_cases_on_mcp_test_suite_id"
  end

  create_table "mcp_test_executions", force: :cascade do |t|
    t.json "assertion_results"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.json "execution_metrics"
    t.bigint "mcp_test_case_id", null: false
    t.bigint "mcp_test_run_id", null: false
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_test_case_id"], name: "index_mcp_test_executions_on_mcp_test_case_id"
    t.index ["mcp_test_run_id", "mcp_test_case_id"], name: "idx_mcp_test_exec_unique", unique: true
    t.index ["mcp_test_run_id"], name: "index_mcp_test_executions_on_mcp_test_run_id"
    t.index ["started_at"], name: "index_mcp_test_executions_on_started_at"
    t.index ["status"], name: "index_mcp_test_executions_on_status"
  end

  create_table "mcp_test_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.bigint "mcp_test_suite_id", null: false
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.json "summary_metrics"
    t.datetime "updated_at", null: false
    t.index ["mcp_test_suite_id", "created_at"], name: "index_mcp_test_runs_on_mcp_test_suite_id_and_created_at"
    t.index ["mcp_test_suite_id"], name: "index_mcp_test_runs_on_mcp_test_suite_id"
    t.index ["started_at"], name: "index_mcp_test_runs_on_started_at"
    t.index ["status"], name: "index_mcp_test_runs_on_status"
  end

  create_table "mcp_test_suites", force: :cascade do |t|
    t.json "base_variables"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "saved_prompt_id", null: false
    t.json "test_config"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_mcp_test_suites_on_name", unique: true
    t.index ["saved_prompt_id"], name: "index_mcp_test_suites_on_saved_prompt_id"
  end

  create_table "mcp_tool_calls", force: :cascade do |t|
    t.jsonb "arguments"
    t.string "client_ip"
    t.string "client_name"
    t.string "client_version"
    t.datetime "completed_at"
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.text "error_message"
    t.boolean "is_external_call", default: false, null: false
    t.bigint "mcp_test_execution_id"
    t.bigint "message_id"
    t.string "openai_request_id"
    t.jsonb "request_data"
    t.jsonb "response_data"
    t.string "server_label"
    t.datetime "started_at"
    t.string "status"
    t.string "tool_id"
    t.string "tool_name"
    t.datetime "updated_at", null: false
    t.index ["client_name", "created_at"], name: "index_mcp_tool_calls_on_client_name_and_created_at"
    t.index ["conversation_id"], name: "index_mcp_tool_calls_on_conversation_id"
    t.index ["ekn_id"], name: "index_mcp_tool_calls_on_ekn_id"
    t.index ["is_external_call"], name: "index_mcp_tool_calls_on_is_external_call"
    t.index ["mcp_test_execution_id"], name: "index_mcp_tool_calls_on_mcp_test_execution_id"
    t.index ["message_id"], name: "index_mcp_tool_calls_on_message_id"
    t.index ["openai_request_id"], name: "index_mcp_tool_calls_on_openai_request_id"
  end

  create_table "messages", force: :cascade do |t|
    t.text "content"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata"
    t.integer "role"
    t.integer "tokens_used"
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "meta_creation_assessments", force: :cascade do |t|
    t.json "assessment_criteria"
    t.integer "assessment_status", default: 0, null: false
    t.integer "assessment_type", null: false
    t.json "context_data"
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.json "evaluation_results"
    t.json "improvement_recommendations"
    t.bigint "mcp_test_run_id"
    t.json "meta_enliterator_performance"
    t.json "meta_learning_evidence"
    t.decimal "overall_score", precision: 4, scale: 3, null: false
    t.json "personality_health_metrics"
    t.datetime "updated_at", null: false
    t.json "user_satisfaction_indicators"
    t.index ["assessment_status"], name: "index_meta_creation_assessments_on_assessment_status"
    t.index ["assessment_type", "overall_score"], name: "idx_on_assessment_type_overall_score_48738b2adf"
    t.index ["assessment_type"], name: "index_meta_creation_assessments_on_assessment_type"
    t.index ["ekn_id", "created_at"], name: "index_meta_creation_assessments_on_ekn_id_and_created_at"
    t.index ["ekn_id"], name: "index_meta_creation_assessments_on_ekn_id"
    t.index ["mcp_test_run_id"], name: "index_meta_creation_assessments_on_mcp_test_run_id"
    t.index ["overall_score"], name: "index_meta_creation_assessments_on_overall_score"
  end

  create_table "method_pool_practicals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "method_pool_id", null: false
    t.bigint "practical_id", null: false
    t.string "relation_type", default: "implements"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["method_pool_id", "practical_id"], name: "idx_on_method_pool_id_practical_id_0f0229a2ca", unique: true
    t.index ["method_pool_id"], name: "index_method_pool_practicals_on_method_pool_id"
    t.index ["practical_id"], name: "index_method_pool_practicals_on_practical_id"
  end

  create_table "method_pools", force: :cascade do |t|
    t.string "category"
    t.integer "complexity_level", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "method_name", null: false
    t.jsonb "outcomes", default: []
    t.jsonb "prerequisites", default: []
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.jsonb "steps", default: []
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["category"], name: "index_method_pools_on_category"
    t.index ["complexity_level"], name: "index_method_pools_on_complexity_level"
    t.index ["method_name"], name: "index_method_pools_on_method_name"
    t.index ["provenance_and_rights_id"], name: "index_method_pools_on_provenance_and_rights_id"
    t.index ["valid_time_start", "valid_time_end"], name: "index_method_pools_on_valid_time_start_and_valid_time_end"
  end

  create_table "negative_knowledges", force: :cascade do |t|
    t.text "affected_pools"
    t.bigint "batch_id"
    t.datetime "created_at", null: false
    t.text "gap_description"
    t.string "gap_type"
    t.text "impact"
    t.jsonb "metadata"
    t.string "severity"
    t.text "suggested_remediation"
    t.datetime "updated_at", null: false
    t.index ["batch_id"], name: "index_negative_knowledges_on_batch_id"
  end

  create_table "openai_settings", force: :cascade do |t|
    t.boolean "active", default: true
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.jsonb "metadata", default: {}
    t.string "model_type"
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["active"], name: "index_openai_settings_on_active"
    t.index ["category"], name: "index_openai_settings_on_category"
    t.index ["key"], name: "index_openai_settings_on_key", unique: true
    t.index ["model_type"], name: "index_openai_settings_on_model_type"
  end

  create_table "pg_search_documents", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.bigint "searchable_id"
    t.string "searchable_type"
    t.datetime "updated_at", null: false
    t.index ["searchable_type", "searchable_id"], name: "index_pg_search_documents_on_searchable"
  end

  create_table "pipeline_artifacts", force: :cascade do |t|
    t.string "artifact_type", null: false
    t.datetime "created_at", null: false
    t.string "file_path", null: false
    t.jsonb "metadata", default: {}
    t.bigint "pipeline_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["artifact_type"], name: "index_pipeline_artifacts_on_artifact_type"
    t.index ["pipeline_run_id"], name: "index_pipeline_artifacts_on_pipeline_run_id"
  end

  create_table "pipeline_errors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error_type", null: false
    t.text "message"
    t.datetime "occurred_at", null: false
    t.bigint "pipeline_run_id", null: false
    t.string "stage", null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id"], name: "index_pipeline_errors_on_pipeline_run_id"
    t.index ["stage"], name: "index_pipeline_errors_on_stage"
  end

  create_table "pipeline_runs", force: :cascade do |t|
    t.string "bundle_path", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "file_count"
    t.jsonb "metrics", default: {}
    t.jsonb "options", default: {}
    t.string "stage", null: false
    t.datetime "started_at", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["stage", "status"], name: "index_pipeline_runs_on_stage_and_status"
    t.index ["stage"], name: "index_pipeline_runs_on_stage"
    t.index ["started_at"], name: "index_pipeline_runs_on_started_at"
    t.index ["status"], name: "index_pipeline_runs_on_status"
  end

  create_table "practical_ideas", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "idea_id", null: false
    t.bigint "practical_id", null: false
    t.string "relation_type"
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["idea_id"], name: "index_practical_ideas_on_idea_id"
    t.index ["practical_id", "idea_id", "relation_type"], name: "index_prac_idea_on_ids_and_type", unique: true
    t.index ["practical_id"], name: "index_practical_ideas_on_practical_id"
  end

  create_table "practicals", force: :cascade do |t|
    t.integer "complexity_level", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "domain", default: 0, null: false
    t.string "goal", null: false
    t.jsonb "hazards", default: []
    t.integer "instruction_type", default: 0, null: false
    t.jsonb "prerequisites", default: []
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.integer "skill_level", default: 0, null: false
    t.jsonb "steps", default: []
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.integer "validation_method", default: 0, null: false
    t.jsonb "validation_refs", default: []
    t.index ["domain"], name: "index_practicals_on_domain"
    t.index ["goal"], name: "index_practicals_on_goal"
    t.index ["instruction_type"], name: "index_practicals_on_instruction_type"
    t.index ["provenance_and_rights_id"], name: "index_practicals_on_provenance_and_rights_id"
    t.index ["skill_level"], name: "index_practicals_on_skill_level"
    t.index ["steps"], name: "index_practicals_on_steps", using: :gin
    t.index ["valid_time_start", "valid_time_end"], name: "index_practicals_on_valid_time_start_and_valid_time_end"
    t.index ["validation_method"], name: "index_practicals_on_validation_method"
  end

  create_table "prompt_templates", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.string "purpose"
    t.string "service_class"
    t.text "system_prompt"
    t.datetime "updated_at", null: false
    t.text "user_prompt_template"
    t.jsonb "variables", default: []
    t.index ["active"], name: "index_prompt_templates_on_active"
    t.index ["name"], name: "index_prompt_templates_on_name", unique: true
    t.index ["purpose"], name: "index_prompt_templates_on_purpose"
    t.index ["service_class"], name: "index_prompt_templates_on_service_class"
  end

  create_table "prompt_versions", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.float "performance_score"
    t.bigint "prompt_id", null: false
    t.integer "status"
    t.datetime "updated_at", null: false
    t.jsonb "variables"
    t.integer "version_number"
    t.index ["prompt_id"], name: "index_prompt_versions_on_prompt_id"
  end

  create_table "prompts", force: :cascade do |t|
    t.boolean "active"
    t.integer "category"
    t.integer "context"
    t.datetime "created_at", null: false
    t.integer "current_version_id"
    t.text "description"
    t.string "key"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_prompts_on_key", unique: true
  end

  create_table "provenance_and_rights", force: :cascade do |t|
    t.string "collection_method", null: false
    t.jsonb "collectors", default: []
    t.integer "consent_status", default: 0, null: false
    t.datetime "created_at", null: false
    t.jsonb "custom_terms", default: {}
    t.datetime "embargo_until"
    t.bigint "ingest_batch_id", null: false
    t.integer "license_type", default: 0, null: false
    t.boolean "publishability", default: false, null: false
    t.string "quarantine_reason"
    t.boolean "quarantined", default: false, null: false
    t.jsonb "source_ids", default: [], null: false
    t.string "source_owner"
    t.boolean "training_eligibility", default: false, null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["embargo_until"], name: "index_provenance_and_rights_on_embargo_until"
    t.index ["ingest_batch_id"], name: "index_provenance_and_rights_on_ingest_batch_id"
    t.index ["publishability", "training_eligibility"], name: "index_p_and_r_on_publish_and_train"
    t.index ["publishability"], name: "index_provenance_and_rights_on_publishability"
    t.index ["quarantined"], name: "index_provenance_and_rights_on_quarantined"
    t.index ["source_ids"], name: "index_provenance_and_rights_on_source_ids", using: :gin
    t.index ["training_eligibility"], name: "index_provenance_and_rights_on_training_eligibility"
    t.index ["valid_time_start", "valid_time_end"], name: "idx_on_valid_time_start_valid_time_end_afad4edcbc"
  end

  create_table "relationals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "period", default: {}
    t.bigint "provenance_and_rights_id", null: false
    t.string "relation_type", null: false
    t.text "repr_text", null: false
    t.bigint "source_id", null: false
    t.string "source_type", null: false
    t.float "strength"
    t.bigint "target_id", null: false
    t.string "target_type", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["provenance_and_rights_id"], name: "index_relationals_on_provenance_and_rights_id"
    t.index ["relation_type"], name: "index_relationals_on_relation_type"
    t.index ["source_type", "source_id"], name: "index_relationals_on_source"
    t.index ["source_type", "source_id"], name: "index_relationals_on_source_type_and_source_id"
    t.index ["target_type", "target_id"], name: "index_relationals_on_target"
    t.index ["target_type", "target_id"], name: "index_relationals_on_target_type_and_target_id"
    t.index ["valid_time_start", "valid_time_end"], name: "index_relationals_on_valid_time_start_and_valid_time_end"
  end

  create_table "relators", force: :cascade do |t|
    t.integer "batch_id"
    t.boolean "bidirectional"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "entity_id"
    t.string "label"
    t.bigint "provenance_and_rights_id", null: false
    t.string "relation_type"
    t.text "repr_text"
    t.string "source_label"
    t.decimal "strength"
    t.string "target_label"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_relators_on_provenance_and_rights_id"
  end

  create_table "risk_practicals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "practical_id", null: false
    t.string "relation_type", default: "mitigated_by"
    t.bigint "risk_id", null: false
    t.float "strength"
    t.datetime "updated_at", null: false
    t.index ["practical_id"], name: "index_risk_practicals_on_practical_id"
    t.index ["risk_id", "practical_id"], name: "index_risk_practicals_on_risk_id_and_practical_id", unique: true
    t.index ["risk_id"], name: "index_risk_practicals_on_risk_id"
  end

  create_table "risks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.jsonb "impacts", default: []
    t.jsonb "mitigations", default: []
    t.float "probability"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.string "risk_type", null: false
    t.string "severity"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.index ["probability"], name: "index_risks_on_probability"
    t.index ["provenance_and_rights_id"], name: "index_risks_on_provenance_and_rights_id"
    t.index ["risk_type"], name: "index_risks_on_risk_type"
    t.index ["severity"], name: "index_risks_on_severity"
    t.index ["valid_time_start", "valid_time_end"], name: "index_risks_on_valid_time_start_and_valid_time_end"
  end

  create_table "sessions", force: :cascade do |t|
    t.string "browser_session_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.datetime "updated_at", null: false
    t.index ["browser_session_id"], name: "index_sessions_on_browser_session_id", unique: true
  end

  create_table "spaces", force: :cascade do |t|
    t.integer "batch_id"
    t.string "country"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "entity_id"
    t.string "label"
    t.decimal "latitude"
    t.decimal "longitude"
    t.bigint "provenance_and_rights_id", null: false
    t.string "region"
    t.text "repr_text"
    t.string "spatial_type"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_spaces_on_provenance_and_rights_id"
  end

  create_table "spatials", force: :cascade do |t|
    t.jsonb "coordinates", default: {}
    t.datetime "created_at", null: false
    t.text "description"
    t.string "location_name", null: false
    t.jsonb "neighbors", default: []
    t.string "placement_type"
    t.string "portal"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text", null: false
    t.string "sector"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_end"
    t.datetime "valid_time_start", null: false
    t.integer "year"
    t.index ["location_name"], name: "index_spatials_on_location_name"
    t.index ["portal"], name: "index_spatials_on_portal"
    t.index ["provenance_and_rights_id"], name: "index_spatials_on_provenance_and_rights_id"
    t.index ["sector"], name: "index_spatials_on_sector"
    t.index ["valid_time_start", "valid_time_end"], name: "index_spatials_on_valid_time_start_and_valid_time_end"
    t.index ["year"], name: "index_spatials_on_year"
  end

  create_table "stage_completions", force: :cascade do |t|
    t.integer "api_calls_made"
    t.decimal "api_cost_usd", precision: 10, scale: 4
    t.datetime "checked_at"
    t.datetime "completed_at"
    t.jsonb "completion_metrics", default: {}
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.bigint "ingest_batch_id", null: false
    t.string "output_fingerprint"
    t.text "skip_reason"
    t.string "stage_name", null: false
    t.integer "stage_number", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["ekn_id", "stage_number"], name: "index_stage_completions_on_ekn_id_and_stage_number"
    t.index ["ekn_id"], name: "index_stage_completions_on_ekn_id"
    t.index ["ingest_batch_id", "stage_number"], name: "index_stage_completions_on_ingest_batch_id_and_stage_number", unique: true
    t.index ["ingest_batch_id"], name: "index_stage_completions_on_ingest_batch_id"
    t.index ["status"], name: "index_stage_completions_on_status"
  end

  create_table "symbolics", force: :cascade do |t|
    t.integer "batch_id"
    t.datetime "created_at", null: false
    t.text "cultural_context"
    t.string "entity_id"
    t.string "label"
    t.text "meaning"
    t.bigint "provenance_and_rights_id", null: false
    t.text "repr_text"
    t.string "symbol_type"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_symbolics_on_provenance_and_rights_id"
  end

  create_table "time_entities", force: :cascade do |t|
    t.integer "batch_id"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "end_time"
    t.string "entity_id"
    t.string "label"
    t.bigint "provenance_and_rights_id", null: false
    t.boolean "recurring"
    t.text "repr_text"
    t.datetime "start_time"
    t.string "temporal_type"
    t.datetime "updated_at", null: false
    t.datetime "valid_time_start"
    t.index ["provenance_and_rights_id"], name: "index_time_entities_on_provenance_and_rights_id"
  end

  create_table "training_question_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "ekn_id", null: false
    t.json "generation_metadata", default: {}
    t.string "generation_method", null: false
    t.string "name", null: false
    t.integer "question_count", default: 0
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.index ["ekn_id", "name"], name: "index_training_question_sets_on_ekn_id_and_name", unique: true
    t.index ["ekn_id"], name: "index_training_question_sets_on_ekn_id"
    t.index ["generation_method"], name: "index_training_question_sets_on_generation_method"
    t.index ["status"], name: "index_training_question_sets_on_status"
  end

  create_table "training_questions", force: :cascade do |t|
    t.boolean "active", default: true
    t.string "archetype_focus"
    t.float "avg_score", default: 0.0
    t.datetime "created_at", null: false
    t.string "difficulty_level", default: "medium"
    t.bigint "ekn_id", null: false
    t.json "evaluation_criteria", default: {}
    t.json "expected_knowledge_areas", default: []
    t.json "generation_source", default: {}
    t.text "ideal_response_outline"
    t.text "question_text", null: false
    t.string "question_type", null: false
    t.integer "times_asked", default: 0
    t.bigint "training_question_set_id", null: false
    t.datetime "updated_at", null: false
    t.index ["difficulty_level", "active"], name: "index_training_questions_on_difficulty_level_and_active"
    t.index ["ekn_id", "archetype_focus"], name: "index_training_questions_on_ekn_id_and_archetype_focus"
    t.index ["ekn_id"], name: "index_training_questions_on_ekn_id"
    t.index ["question_type"], name: "index_training_questions_on_question_type"
    t.index ["training_question_set_id", "question_type"], name: "idx_on_training_question_set_id_question_type_d559b9b2db"
    t.index ["training_question_set_id"], name: "index_training_questions_on_training_question_set_id"
  end

  create_table "training_responses", force: :cascade do |t|
    t.float "accuracy_score", default: 0.0
    t.float "completeness_score", default: 0.0
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.json "evaluation_metadata", default: {}
    t.text "evaluation_notes"
    t.boolean "human_reviewed", default: false
    t.float "overall_score", default: 0.0
    t.float "personality_authenticity_score", default: 0.0
    t.json "personality_metadata", default: {}
    t.text "response_text"
    t.float "response_time_seconds"
    t.json "tool_usage", default: {}
    t.bigint "training_question_id", null: false
    t.bigint "training_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_training_responses_on_created_at"
    t.index ["ekn_id", "overall_score"], name: "index_training_responses_on_ekn_id_and_overall_score"
    t.index ["ekn_id"], name: "index_training_responses_on_ekn_id"
    t.index ["training_question_id"], name: "index_training_responses_on_training_question_id"
    t.index ["training_run_id", "training_question_id"], name: "idx_on_training_run_id_training_question_id_8ca65df8e0"
    t.index ["training_run_id"], name: "index_training_responses_on_training_run_id"
  end

  create_table "training_runs", force: :cascade do |t|
    t.json "archetype_scores", default: {}
    t.datetime "completed_at"
    t.integer "completed_questions", default: 0
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.float "overall_score", default: 0.0
    t.text "run_description"
    t.json "run_metadata", default: {}
    t.string "run_name"
    t.datetime "started_at"
    t.string "status", default: "pending"
    t.integer "total_questions", default: 0
    t.bigint "training_question_set_id", null: false
    t.datetime "updated_at", null: false
    t.index ["ekn_id", "status"], name: "index_training_runs_on_ekn_id_and_status"
    t.index ["ekn_id"], name: "index_training_runs_on_ekn_id"
    t.index ["started_at"], name: "index_training_runs_on_started_at"
    t.index ["training_question_set_id"], name: "index_training_runs_on_training_question_set_id"
  end

  create_table "user_ekns", force: :cascade do |t|
    t.string "access_level", default: "viewer", null: false
    t.datetime "created_at", null: false
    t.bigint "ekn_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["access_level"], name: "index_user_ekns_on_access_level"
    t.index ["ekn_id"], name: "index_user_ekns_on_ekn_id"
    t.index ["user_id", "ekn_id"], name: "index_user_ekns_on_user_id_and_ekn_id", unique: true
    t.index ["user_id"], name: "index_user_ekns_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "name"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "webhook_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.jsonb "headers", default: {}
    t.jsonb "metadata", default: {}
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.string "resource_id"
    t.string "resource_type"
    t.integer "retry_count", default: 0
    t.string "signature"
    t.string "status", default: "pending", null: false
    t.datetime "timestamp", null: false
    t.datetime "updated_at", null: false
    t.string "webhook_id", null: false
    t.index ["created_at"], name: "index_webhook_events_on_created_at"
    t.index ["event_id"], name: "index_webhook_events_on_event_id", unique: true
    t.index ["event_type"], name: "index_webhook_events_on_event_type"
    t.index ["resource_type", "resource_id"], name: "index_webhook_events_on_resource_type_and_resource_id"
    t.index ["status"], name: "index_webhook_events_on_status"
    t.index ["webhook_id"], name: "index_webhook_events_on_webhook_id"
  end

  create_table "widgets", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "actor_experiences", "actors"
  add_foreign_key "actor_experiences", "experiences"
  add_foreign_key "actor_manifests", "actors"
  add_foreign_key "actor_manifests", "manifests"
  add_foreign_key "actors", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "api_calls", "ekns"
  add_foreign_key "characters", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "conversations", "ekns"
  add_foreign_key "conversations", "ingest_batches"
  add_foreign_key "ekn_personality_profiles", "ekns"
  add_foreign_key "ekn_pipeline_runs", "ekns"
  add_foreign_key "ekn_pipeline_runs", "ingest_batches"
  add_foreign_key "ekns", "users"
  add_foreign_key "emanation_ideas", "emanations"
  add_foreign_key "emanation_ideas", "ideas"
  add_foreign_key "emanation_relationals", "emanations"
  add_foreign_key "emanation_relationals", "relationals"
  add_foreign_key "emanations", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "enliterator_claims", "enliterator_claims", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "enliterator_claims", "enliterator_visits", column: "visit_id", on_delete: :nullify
  add_foreign_key "enliterator_visits", "enliterator_visits", column: "escalated_from_id", on_delete: :nullify
  add_foreign_key "evidence_experiences", "evidences"
  add_foreign_key "evidence_experiences", "experiences"
  add_foreign_key "evidences", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "evolutionaries", "ideas", column: "refined_idea_id"
  add_foreign_key "evolutionaries", "manifests", column: "manifest_version_id"
  add_foreign_key "evolutionaries", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "experience_emanations", "emanations"
  add_foreign_key "experience_emanations", "experiences"
  add_foreign_key "experience_practicals", "experiences"
  add_foreign_key "experience_practicals", "practicals"
  add_foreign_key "experiences", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "feedback_responses", "feedbacks"
  add_foreign_key "feedback_responses", "users"
  add_foreign_key "feedbacks", "users"
  add_foreign_key "feedbacks", "users", column: "resolved_by_id"
  add_foreign_key "idea_emanations", "emanations"
  add_foreign_key "idea_emanations", "ideas"
  add_foreign_key "idea_manifests", "ideas"
  add_foreign_key "idea_manifests", "manifests"
  add_foreign_key "idea_practicals", "ideas"
  add_foreign_key "idea_practicals", "practicals"
  add_foreign_key "ideas", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "ingest_batches", "ekns"
  add_foreign_key "ingest_items", "ingest_batches"
  add_foreign_key "ingest_items", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "intent_and_tasks", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "lexicon_and_ontologies", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "lifecycles", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "log_items", "logs"
  add_foreign_key "manifest_experiences", "experiences"
  add_foreign_key "manifest_experiences", "manifests"
  add_foreign_key "manifest_spatials", "manifests"
  add_foreign_key "manifest_spatials", "spatials"
  add_foreign_key "manifests", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "mcp_intelligent_test_runs", "ekns"
  add_foreign_key "mcp_intelligent_test_runs", "mcp_test_cases"
  add_foreign_key "mcp_intelligent_test_runs", "mcp_test_runs"
  add_foreign_key "mcp_test_cases", "mcp_test_suites"
  add_foreign_key "mcp_test_executions", "mcp_test_cases"
  add_foreign_key "mcp_test_executions", "mcp_test_runs"
  add_foreign_key "mcp_test_runs", "mcp_test_suites"
  add_foreign_key "mcp_tool_calls", "conversations"
  add_foreign_key "mcp_tool_calls", "ekns"
  add_foreign_key "mcp_tool_calls", "mcp_test_executions"
  add_foreign_key "mcp_tool_calls", "messages"
  add_foreign_key "messages", "conversations"
  add_foreign_key "meta_creation_assessments", "ekns"
  add_foreign_key "meta_creation_assessments", "mcp_test_runs"
  add_foreign_key "method_pool_practicals", "method_pools"
  add_foreign_key "method_pool_practicals", "practicals"
  add_foreign_key "method_pools", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "negative_knowledges", "ingest_batches", column: "batch_id"
  add_foreign_key "pipeline_artifacts", "pipeline_runs"
  add_foreign_key "pipeline_errors", "pipeline_runs"
  add_foreign_key "practical_ideas", "ideas"
  add_foreign_key "practical_ideas", "practicals"
  add_foreign_key "practicals", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "prompt_versions", "prompts"
  add_foreign_key "provenance_and_rights", "ingest_batches"
  add_foreign_key "relationals", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "relators", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "risk_practicals", "practicals"
  add_foreign_key "risk_practicals", "risks"
  add_foreign_key "risks", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "spaces", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "spatials", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "stage_completions", "ekns"
  add_foreign_key "stage_completions", "ingest_batches"
  add_foreign_key "symbolics", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "time_entities", "provenance_and_rights", column: "provenance_and_rights_id"
  add_foreign_key "training_question_sets", "ekns"
  add_foreign_key "training_questions", "ekns"
  add_foreign_key "training_questions", "ekns", name: "fk_training_questions_ekn"
  add_foreign_key "training_questions", "training_question_sets"
  add_foreign_key "training_responses", "ekns"
  add_foreign_key "training_responses", "ekns", name: "fk_training_responses_ekn"
  add_foreign_key "training_responses", "training_questions"
  add_foreign_key "training_responses", "training_runs"
  add_foreign_key "training_runs", "ekns"
  add_foreign_key "training_runs", "ekns", name: "fk_training_runs_ekn"
  add_foreign_key "training_runs", "training_question_sets"
  add_foreign_key "user_ekns", "ekns"
  add_foreign_key "user_ekns", "users"
end
