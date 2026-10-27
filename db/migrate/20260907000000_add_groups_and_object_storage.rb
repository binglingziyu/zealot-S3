# frozen_string_literal: true

class AddGroupsAndObjectStorage < ActiveRecord::Migration[8.1]
  def change
    create_table :storage_profiles do |t|
      t.string :name, null: false
      t.string :provider, null: false, default: 's3'
      t.string :region, null: false
      t.string :endpoint
      t.string :download_endpoint
      t.string :bucket, null: false
      t.string :prefix, null: false, default: ''
      t.boolean :force_path_style, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.boolean :system_default, null: false, default: false
      t.text :credentials_ciphertext
      t.integer :credentials_version, null: false, default: 1
      t.integer :url_expires_in, null: false, default: 900
      t.timestamps
    end
    add_index :storage_profiles, :name, unique: true
    add_index :storage_profiles, :system_default, unique: true, where: 'system_default = TRUE'

    create_table :groups do |t|
      t.string :name, null: false
      t.text :description
      t.references :storage_profile, foreign_key: true
      t.integer :access_version, null: false, default: 1
      t.timestamps
    end
    add_index :groups, :name, unique: true
    create_table :group_memberships do |t|
      t.references :group, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: 'viewer'
      t.timestamps
    end
    add_index :group_memberships, [:group_id, :user_id], unique: true
    add_check_constraint :group_memberships, "role IN ('viewer', 'developer', 'admin')", name: 'group_membership_role'

    add_reference :apps, :group, foreign_key: true
    add_reference :apps, :storage_profile, foreign_key: true
    add_column :apps, :inherit_group_permissions, :boolean, null: false, default: true
    add_column :apps, :access_version, :integer, null: false, default: 1

    create_table :storage_grants do |t|
      t.references :storage_profile, null: false, foreign_key: true
      t.references :group, foreign_key: true
      t.references :app, foreign_key: true
      t.timestamps
    end
    add_check_constraint :storage_grants, '(group_id IS NULL) <> (app_id IS NULL)', name: 'storage_grant_one_subject'
    add_index :storage_grants, [:storage_profile_id, :group_id], unique: true, where: 'group_id IS NOT NULL'
    add_index :storage_grants, [:storage_profile_id, :app_id], unique: true, where: 'app_id IS NOT NULL'

    create_table :stored_objects do |t|
      t.references :storage_profile, null: false, foreign_key: true
      t.references :app, foreign_key: true
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false, default: 'application/octet-stream'
      t.string :kind, null: false
      t.bigint :byte_size
      t.string :sha256
      t.string :etag
      t.string :state, null: false, default: 'pending'
      t.datetime :deleted_at
      t.datetime :purge_after
      t.timestamps
    end
    add_index :stored_objects, [:storage_profile_id, :key], unique: true
    add_index :stored_objects, [:state, :purge_after]
    add_check_constraint :stored_objects, 'byte_size IS NULL OR byte_size >= 0', name: 'stored_object_size'

    create_table :upload_sessions, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :user, null: false, foreign_key: true
      t.references :app, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :stored_object, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :multipart_upload_id
      t.string :state, null: false, default: 'initiated'
      t.bigint :expected_size, null: false
      t.string :expected_sha256
      t.bigint :part_size, null: false
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :parts, null: false, default: []
      t.text :error_message
      t.integer :attempts, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :heartbeat_at
      t.references :release, foreign_key: true
      t.references :debug_file, foreign_key: true
      t.timestamps
    end
    add_index :upload_sessions, [:user_id, :idempotency_key], unique: true
    add_index :upload_sessions, [:state, :expires_at]
    add_check_constraint :upload_sessions, 'expected_size > 0 AND part_size > 0', name: 'upload_session_sizes'
    add_reference :releases, :package_object, foreign_key: { to_table: :stored_objects }
    add_reference :releases, :icon_object, foreign_key: { to_table: :stored_objects }
    add_reference :debug_files, :stored_object, foreign_key: true

    create_table :audit_events do |t|
      t.references :user, foreign_key: true
      t.string :action, null: false
      t.string :subject_type, null: false
      t.string :subject_id, null: false
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :audit_events, [:subject_type, :subject_id, :created_at]
  end
end
