# frozen_string_literal: true

module FreeModelsHelper
  TRAINING_RISK_STYLES = {
    "none" => "bg-green-100 text-green-700 ring-green-200",
    "possible" => "bg-amber-100 text-amber-800 ring-amber-200"
  }.freeze

  def free_model_context_label(tokens)
    return "Unknown" if tokens.blank?

    number_to_human(tokens, precision: 3, strip_insignificant_zeros: true, units: { thousand: "K", million: "M", billion: "B" })
  end

  def free_model_capability_width(model)
    score = model.capability_score.to_f
    [ [ (score * 10).round, 0 ].max, 100 ].min
  end

  def free_model_excluded?(project, model)
    return false unless project

    Array(project.model_preferences&.dig("excluded_free_model_ids")).include?(model.model_id)
  end

  def free_model_training_risk_classes(model)
    TRAINING_RISK_STYLES.fetch(model.data_training_risk.to_s, "bg-gray-100 text-gray-700 ring-gray-200")
  end

  def free_model_status_label(model)
    return "Expired" if model.expired?

    model.active? ? "Active" : "Inactive"
  end

  def free_model_status_classes(model)
    return "bg-orange-100 text-orange-700" if model.expired?
    return "bg-green-100 text-green-700" if model.active?

    "bg-gray-100 text-gray-600"
  end
end
