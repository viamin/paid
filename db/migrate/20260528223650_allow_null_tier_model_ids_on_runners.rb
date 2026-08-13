# frozen_string_literal: true

class AllowNullTierModelIdsOnRunners < ActiveRecord::Migration[8.1]
  def up
    change_column_default :runners, :tier_model_ids, from: {}, to: nil
    change_column_null :runners, :tier_model_ids, true
    change_column_comment :runners, :tier_model_ids,
      "Per-tier model mapping for configurable runners. Nil means no explicit mapping is stored."
  end

  def down
    change_column_comment :runners, :tier_model_ids,
      "Per-tier model routing for configurable runners."
    change_column_null :runners, :tier_model_ids, false, {}
    change_column_default :runners, :tier_model_ids, from: nil, to: {}
  end
end
