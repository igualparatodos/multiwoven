# frozen_string_literal: true

class AddUpsertFieldsToSyncs < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_column :syncs, :destination_sync_mode, :integer, default: 0
    add_column :syncs, :unique_identifier_config, :jsonb, default: {}
    add_index :syncs, :destination_sync_mode, algorithm: :concurrently
  end
end
