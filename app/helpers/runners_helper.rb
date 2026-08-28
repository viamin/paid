# frozen_string_literal: true

module RunnersHelper
  FREE_POLICY_OPTION_VALUE = Runners::ModelOptions::FREE_POLICY_VALUE
  CUSTOM_MODEL_OPTION_VALUE = LlmModel::CUSTOM_MODEL_OPTION

  def runner_usage_stats_for(runner)
    return unless @usage_stats

    stats = @usage_stats[runner.runner_key]
    stats ||= @usage_stats[runner.routing_key]
    stats
  end

  def format_token_count(count)
    if count >= 1_000_000
      "#{(count / 1_000_000.0).round(1)}M"
    elsif count >= 1_000
      "#{(count / 1_000.0).round(1)}k"
    else
      count.to_s
    end
  end

  # Prepends the runner's currently saved model to a direct-outbound model
  # dropdown's option list when it falls outside the active catalog (e.g. a
  # deactivated or manually-entered model id). Without this, saving any
  # unrelated field on the runner form re-submits the select's placeholder
  # value instead of the stored model, silently clearing it or failing
  # validation.
  # @spec DIRECT-OUTBOUND-CATALOG-009
  def model_options_preserving_current(option_rows, current_model_id)
    return option_rows if current_model_id.blank?
    return option_rows if option_rows.any? { |_label, value, _kind| value == current_model_id }

    preserved_label = LlmModel.find_by_model_id(current_model_id)&.display_name || current_model_id
    custom_index = option_rows.index { |_label, _value, kind| kind == "custom" } || option_rows.length
    option_rows.dup.insert(custom_index, [ preserved_label, current_model_id, "model" ])
  end

  # Returns a copy of a provider->options-by-service-type hash with the given
  # service type's entry replaced by +effective_options+, so the JS-driven
  # dropdown refresh (triggered when switching API keys) sees the same
  # preserved current-model entry as the initial server-rendered markup.
  def model_options_by_service_type_json(base_options_by_service_type, service_type, effective_options)
    return base_options_by_service_type if service_type.blank?

    base_options_by_service_type.merge(service_type => effective_options)
  end

  def runner_model_options_by_service_type(runner_key:, service_types:, auth_type:, current_model_id:, free_model_policy:)
    service_types.index_with do |service_type|
      option_rows = Runners::ModelOptions.call(
        runner_key: runner_key,
        api_provider: service_type,
        auth_type: auth_type
      ).map { |entry| [ entry.label, entry.value, entry.kind.to_s ] }

      next option_rows if free_model_policy

      model_options_preserving_current(option_rows, current_model_id)
    end
  end

  def runner_model_select_value(current_model_id:, free_model_policy:)
    return FREE_POLICY_OPTION_VALUE if free_model_policy

    current_model_id.to_s
  end

  def manual_model_entry?(option_rows, current_model_id:, free_model_policy:)
    return false if free_model_policy
    return false if current_model_id.present?

    option_rows.one? { |_label, value, _kind| value == CUSTOM_MODEL_OPTION_VALUE }
  end
end
