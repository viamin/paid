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

  # RDR-065 (#3669): Runners::ModelOptions entries for a direct-outbound
  # runner key, grouped by the api_service_type of the key that would select
  # them. Single source of truth for the runner_model_policy_form dropdown so
  # the form, the JS re-render on key change, and Runners::DefaultTierModelIds
  # cannot drift. Delegates to the batched Runners::ModelOptions.call_by_provider
  # so a form render issues one LlmModel query per runner_key instead of one
  # per service type.
  # @spec MODEL-POLICY-FORM-001
  def catalog_model_entries_by_service_type(runner_key:, service_types:, auth_type:)
    Runners::ModelOptions.call_by_provider(runner_key: runner_key, api_providers: service_types, auth_type: auth_type)
  end

  # @spec MODEL-POLICY-FORM-006
  def catalog_model_entries_json(entries_by_service_type)
    entries_by_service_type.transform_values do |entries|
      entries.map { |entry| { value: entry.value, label: entry.label, kind: entry.kind.to_s, family: entry.family } }
    end
  end

  # Determines which <option> should be preselected for a persisted or
  # previously-submitted direct-outbound model value: the Free policy
  # sentinel, a catalog model id, or the Custom sentinel (with the manual
  # input prefilled) when the stored id falls outside the current catalog.
  # @spec MODEL-POLICY-FORM-002
  def catalog_model_initial_selection(entries, current_model_id:, model_policy:)
    return { selected: Runners::ModelOptions::FREE_POLICY_VALUE, manual: nil } if model_policy == "free"
    return { selected: "", manual: nil } if current_model_id.blank?
    return { selected: current_model_id, manual: nil } if entries.any? { |entry| entry.model? && entry.value == current_model_id }

    { selected: LlmModel::CUSTOM_MODEL_OPTION, manual: current_model_id }
  end

  def runner_model_options_by_service_type(runner_key:, service_types:, auth_type:, current_model_id:, free_model_policy:)
    option_rows_by_service_type = Runners::ModelOptions.call_by_provider(
      runner_key: runner_key,
      api_providers: service_types,
      auth_type: auth_type
    ).transform_values { |entries| entries.map { |entry| [ entry.label, entry.value, entry.kind.to_s ] } }

    service_types.index_with do |service_type|
      option_rows = option_rows_by_service_type.fetch(service_type, [])
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
