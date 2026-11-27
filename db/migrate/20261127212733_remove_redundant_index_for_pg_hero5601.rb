# frozen_string_literal: true

# index_llm_models_on_provider_and_active covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5601 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :llm_models, name: "index_llm_models_on_provider", algorithm: :concurrently
  end

  def down
    add_index :llm_models, [ :provider ],
      name: "index_llm_models_on_provider", algorithm: :concurrently
  end
end
