# frozen_string_literal: true

require "digest"

module Models
  # Proactive drift detector: compares the RubyLLM registry (the same source
  # Models::SeedKnownModels trusts) against the first-party LlmModel catalog and
  # reports models the catalog is missing (provider shipped something new) or
  # models the catalog still lists that the registry no longer knows (provider
  # retired them).
  #
  # This is structural detection only (ZFC): it surfaces the diff and leaves the
  # semantic judgment — which models to adopt, at what tier/capability — to the
  # agent that picks up the filed issue.
  class DetectCatalogDrift
    # Providers Paid actually resolves first-party models for. Mirrors
    # Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER values.
    DEFAULT_PROVIDERS = %w[anthropic openai google].freeze

    # Registry capabilities that mark a model as usable for agent/chat work.
    CHAT_CAPABILITIES = %w[function_calling structured_output].freeze

    # Name fragments for non-chat model families we never catalog.
    NON_CHAT_NAME_PATTERNS = /
      audio | realtime | transcribe | tts | search | embedding |
      moderation | image | dall-e | whisper | rerank | guard
    /xi

    # Unstable/alias ids that aren't durable catalog candidates (rolling
    # "-latest" aliases and "-preview"/experimental snapshots).
    UNSTABLE_NAME_PATTERNS = /preview|latest/i

    # Trailing snapshot/alias suffixes collapsed to a canonical base so a dated
    # catalog id (claude-haiku-4-5-20251001) and its undated registry alias
    # (claude-haiku-4-5) are treated as the same model.
    SNAPSHOT_SUFFIXES = [
      /-\d{4}-\d{2}-\d{2}\z/,
      /-\d{8}\z/,
      /-latest\z/
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(providers: DEFAULT_PROVIDERS, registry: nil)
      @providers = providers
      @registry = registry || RegistryModels.fetch
    end

    def call
      providers = @providers.index_with { |provider| drift_for(provider) }
        .reject { |_provider, drift| drift[:new_models].empty? && drift[:deprecated_models].empty? }

      Result.new(providers: providers, registry_fetched: @registry.fetched?)
    end

    # A catalog model is "deprecated" only when the registry loaded healthily
    # for that provider and no longer knows the model; otherwise a degraded
    # registry fetch would raise false alarms.
    def deprecated_models_for(provider)
      return [] unless @registry.healthy?(provider)

      registry_bases = @registry.for_provider(provider).to_set { |model| base_id(model.id) }
      LlmModel.active.by_provider(provider).pluck(:model_id)
        .reject { |id| registry_bases.include?(base_id(id)) }
        .sort
    end

    private

    def drift_for(provider)
      chat_by_base = chat_models_for(provider).group_by { |model| base_id(model.id) }
      catalog_bases = catalog_model_ids(provider).to_set { |id| base_id(id) }
      baseline = newest_catalog_date(catalog_bases, chat_by_base)

      {
        new_models: new_models_for(chat_by_base, catalog_bases, baseline),
        deprecated_models: deprecated_models_for(provider)
      }
    end

    def new_models_for(chat_by_base, catalog_bases, baseline)
      chat_by_base
        .reject { |base, _models| catalog_bases.include?(base) }
        .filter_map { |base, models| build_new_model(base, models, baseline) }
        .sort_by { |entry| entry[:representative] }
    end

    # Only surface a model the catalog lacks when it is genuinely newer than our
    # newest catalogued model for the provider — otherwise the diff would report
    # every legacy model (gpt-4, claude-3, o1) we never intend to add. When no
    # catalogued model can be dated, fall back to reporting (don't silently drop).
    def build_new_model(base, models, baseline)
      newest = models.filter_map(&:created_at).max
      return if baseline && (newest.nil? || newest <= baseline)

      representative = models.map(&:id).min_by { |id| [ snapshot_id?(id) ? 1 : 0, id.length, id ] }
      { base: base, representative: representative, variants: models.size }
    end

    def newest_catalog_date(catalog_bases, chat_by_base)
      catalog_bases
        .flat_map { |base| Array(chat_by_base[base]) }
        .filter_map(&:created_at)
        .max
    end

    def chat_models_for(provider)
      @registry.for_provider(provider).select { |model| chat_model?(model) }
    end

    def chat_model?(model)
      return false if model.id.to_s.match?(NON_CHAT_NAME_PATTERNS)
      return false if model.id.to_s.match?(UNSTABLE_NAME_PATTERNS)
      return false if model.metadata.to_h[:open_weights] == true

      capabilities = Array(model.capabilities).map(&:to_s)
      return false if (capabilities & CHAT_CAPABILITIES).empty?

      modalities = model.modalities.to_h
      Array(modalities[:input]).include?("text") && Array(modalities[:output]).include?("text")
    rescue StandardError
      false
    end

    def catalog_model_ids(provider)
      LlmModel.by_provider(provider).pluck(:model_id)
    end

    def base_id(model_id)
      SNAPSHOT_SUFFIXES.reduce(model_id.to_s) { |id, suffix| id.sub(suffix, "") }
    end

    def snapshot_id?(model_id)
      SNAPSHOT_SUFFIXES.any? { |suffix| model_id.to_s.match?(suffix) }
    end

    # Immutable view of the drift the detector found.
    class Result
      attr_reader :providers

      def initialize(providers:, registry_fetched:)
        @providers = providers
        @registry_fetched = registry_fetched
      end

      def registry_fetched?
        @registry_fetched
      end

      def drift?
        @providers.any?
      end

      def new_model_count
        @providers.sum { |_provider, drift| drift[:new_models].size }
      end

      def deprecated_model_count
        @providers.sum { |_provider, drift| drift[:deprecated_models].size }
      end

      # Stable digest of the finding set, used to dedup the filed issue.
      def fingerprint
        tokens = @providers.flat_map do |provider, drift|
          drift[:new_models].map { |entry| "new:#{provider}:#{entry[:representative]}" } +
            drift[:deprecated_models].map { |id| "dep:#{provider}:#{id}" }
        end
        Digest::SHA256.hexdigest(tokens.sort.join("|"))
      end

      def to_h
        { providers: @providers, registry_fetched: @registry_fetched }
      end
    end
  end
end
