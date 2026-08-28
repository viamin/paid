# frozen_string_literal: true

module RunnersHelper
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
  # dropdown's catalog options when it falls outside the active catalog (e.g.
  # a deactivated or manually-entered model id). Without this, saving any
  # unrelated field on the runner form re-submits the select's placeholder
  # value instead of the stored model, silently clearing it or failing
  # validation.
  # @spec DIRECT-OUTBOUND-CATALOG-009
  def model_options_preserving_current(catalog_options, current_model_id)
    return catalog_options if current_model_id.blank?
    return catalog_options if catalog_options.any? { |_label, value| value == current_model_id }

    preserved_label = LlmModel.find_by_model_id(current_model_id)&.display_name || current_model_id
    [ [ preserved_label, current_model_id ] ] + catalog_options
  end

  # Returns a copy of a provider->options-by-service-type hash with the given
  # service type's entry replaced by +effective_options+, so the JS-driven
  # dropdown refresh (triggered when switching API keys) sees the same
  # preserved current-model entry as the initial server-rendered markup.
  def model_options_by_service_type_json(base_options_by_service_type, service_type, effective_options)
    return base_options_by_service_type if service_type.blank?

    base_options_by_service_type.merge(service_type => effective_options)
  end
end
