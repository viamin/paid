# frozen_string_literal: true

class AddFreeModelFieldsToLlmModels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :llm_models, :pricing_tier, :string, default: "paid", null: false,
      comment: "Pricing availability for this model: paid, free, or freemium."
    add_column :llm_models, :data_training_risk, :string,
      comment: "Whether provider terms indicate prompts may be used for training."
    add_column :llm_models, :catalog_source, :string, default: "seeded", null: false,
      comment: "How this model entered the catalog: seeded, openrouter_sync, or manual."
    add_column :llm_models, :expires_at, :datetime,
      comment: "Optional expiration time for temporary catalog entries."
    add_reference :llm_models, :free_variant_of, null: true, index: { algorithm: :concurrently },
      comment: "Paid model that this free model variant corresponds to."
    safety_assured do
      add_foreign_key :llm_models, :llm_models, column: :free_variant_of_id, validate: false
    end
  end
end
