# frozen_string_literal: true

module Runners
  # Single source of truth for the model choices offered when configuring a
  # runner, keyed by (runner_key, api_provider, auth_type). The runner form
  # dropdown, controller validation, and Runners::DefaultTierModelIds all
  # consume this list so presented options and tier defaults cannot diverge.
  class ModelOptions
    # One selectable dropdown entry. kind: :model (catalog row), :free_policy
    # (OpenRouter Free model policy), or :custom (freeform model id reveal).
    # family is the optgroup label (falls back to the catalog provider);
    # model is the catalog record behind a :model entry.
    Entry = Struct.new(:value, :label, :kind, :family, :model, keyword_init: true) do
      def model? = kind == :model
      def free_policy? = kind == :free_policy
      def custom? = kind == :custom
    end

    # Persisted by the form as config model_policy: "free" (#3668); the label
    # is the dropdown copy from RDR-065 D2.
    FREE_POLICY_VALUE = "free"
    FREE_POLICY_LABEL = "OpenRouter Free (curated, tiered)"
    CUSTOM_MODEL_LABEL = "Custom model ID…"

    # Phase-1 gate (RDR-065 D2/D6): the Free policy is offered for OpenCode
    # on OpenRouter only; Pi/Oh My Pi/KiloCode unlock in a follow-up issue.
    FREE_POLICY_RUNNER_KEY = "opencode"
    FREE_POLICY_API_PROVIDER = "openrouter"

    def self.call(runner_key:, api_provider:, auth_type: DefaultTierModelIds::DEFAULT_AUTH_TYPE)
      new(runner_key: runner_key, api_provider: api_provider, auth_type: auth_type).call
    end

    # Batched sibling of .call for rendering every service type's dropdown for
    # a single runner_key (e.g. the runner form): fetches the LlmModel catalog
    # once for all +api_providers+ instead of once per provider, then reuses
    # the preloaded rows for each provider's ModelCompatibility pass.
    # @spec RUNNER-MODEL-OPTIONS-006
    def self.call_by_provider(runner_key:, api_providers:, auth_type: DefaultTierModelIds::DEFAULT_AUTH_TYPE)
      providers = api_providers.map(&:to_s)
      rows_by_provider = catalog_rows_by_provider(providers)
      providers.index_with do |api_provider|
        new(runner_key: runner_key, api_provider: api_provider, auth_type: auth_type,
          catalog_rows: rows_by_provider.fetch(api_provider, [])).call
      end
    end

    def self.catalog_rows_by_provider(api_providers) # @spec RUNNER-MODEL-OPTIONS-006
      relation = LlmModel.active.where(provider: api_providers)
      relation = relation.or(LlmModel.active.openrouter_synced) if api_providers.include?(FREE_POLICY_API_PROVIDER)
      rows = relation.order(Arel.sql("family ASC NULLS LAST")).by_capability.to_a

      api_providers.index_with { |api_provider| rows_for_provider(rows, api_provider) }
    end
    private_class_method :catalog_rows_by_provider

    def self.rows_for_provider(rows, api_provider)
      return rows.select { |model| model.provider == api_provider } unless api_provider == FREE_POLICY_API_PROVIDER

      rows.select { |model| model.provider == FREE_POLICY_API_PROVIDER || model.catalog_source == "openrouter_sync" }
    end
    private_class_method :rows_for_provider

    def initialize(runner_key:, api_provider:, auth_type: DefaultTierModelIds::DEFAULT_AUTH_TYPE, catalog_rows: nil)
      @runner_key = runner_key.to_s
      @api_provider = api_provider.to_s
      @auth_type = auth_type.to_s.presence || DefaultTierModelIds::DEFAULT_AUTH_TYPE
      @preloaded_catalog_rows = catalog_rows
    end

    def call
      [ free_policy_entry, *model_entries, custom_entry ].compact
    end

    private

    attr_reader :runner_key, :api_provider, :auth_type

    def free_policy_entry # @spec RUNNER-MODEL-OPTIONS-004
      return unless runner_key == FREE_POLICY_RUNNER_KEY && api_provider == FREE_POLICY_API_PROVIDER

      Entry.new(value: FREE_POLICY_VALUE, label: FREE_POLICY_LABEL, kind: :free_policy)
    end

    def model_entries # @spec RUNNER-MODEL-OPTIONS-001
      catalog_rows.select { |model| runner_model_compatible?(model) }.map { |model| model_entry_for(model) }
    end

    def model_entry_for(model)
      Entry.new(
        value: model.model_id,
        label: model.display_name,
        kind: :model,
        family: model.family.presence || model.provider,
        model: model
      )
    end

    def custom_entry # @spec RUNNER-MODEL-OPTIONS-005
      Entry.new(value: LlmModel::CUSTOM_MODEL_OPTION, label: CUSTOM_MODEL_LABEL, kind: :custom)
    end

    def catalog_rows # @spec RUNNER-MODEL-OPTIONS-003
      return @preloaded_catalog_rows if @preloaded_catalog_rows

      # Synced free models carry the upstream vendor slug in `provider` but
      # are OpenRouter-reachable model ids, so they belong in the OpenRouter
      # dropdown alongside provider-scoped rows (e.g. the Pareto row).
      relation = LlmModel.active.by_provider(api_provider)
      relation = relation.or(LlmModel.active.openrouter_synced) if api_provider == FREE_POLICY_API_PROVIDER
      relation.order(Arel.sql("family ASC NULLS LAST")).by_capability
    end

    def runner_model_compatible?(model) # @spec RUNNER-MODEL-OPTIONS-002 @spec MODEL-SELECTION-005
      result = ModelCompatibility.call(
        runner_key: runner_key,
        model_id: model.model_id,
        auth_type: auth_type,
        llm_model: model
      )
      if result.unsupported?
        Rails.logger.info(
          message: "model_selection.model_option_filtered_incompatible",
          runner_key: runner_key,
          model_id: model.model_id,
          auth_type: auth_type,
          incompatibility_type: result.incompatibility_type,
          reason: result.reason
        )
      end
      !result.unsupported?
    end
  end
end
