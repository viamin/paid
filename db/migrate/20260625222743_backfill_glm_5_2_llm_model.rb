# frozen_string_literal: true

class BackfillGlm52LlmModel < ActiveRecord::Migration[8.1]
  class MigrationLlmModel < ActiveRecord::Base
    self.table_name = "llm_models"
  end

  GLM_5_2_ATTRIBUTES = {
    display_name: "GLM-5.2",
    provider: "zai_coding",
    family: "glm-5",
    category: "coding",
    context_window: 1_000_000,
    max_output_tokens: 128_000,
    input_cost_per_million: 1.4,
    output_cost_per_million: 4.4,
    supports_vision: false,
    supports_tools: true,
    supports_json_output: true,
    capability_score: 8.9,
    tier: "mid",
    active: true,
    catalog_source: "seeded",
    pricing_tier: "paid"
  }.freeze

  def up
    model = MigrationLlmModel.find_or_initialize_by(model_id: "glm-5.2")
    model.assign_attributes(GLM_5_2_ATTRIBUTES)
    model.save!
  rescue ActiveRecord::RecordNotUnique
    MigrationLlmModel.find_by!(model_id: "glm-5.2")
  end

  def down
    # No-op: once the model exists, deleting it on rollback could break active
    # runner configs that already reference glm-5.2.
  end
end
