# frozen_string_literal: true

module Models
  # Single point of access to the RubyLLM model registry. Loads the registry
  # once and exposes both the by-id index that Models::SeedKnownModels needs and
  # the per-provider views that Models::DetectCatalogDrift needs.
  #
  # Centralizing the fetch keeps provider-list access in one place (no direct
  # provider HTTP in Paid) and lets the drift detector reason about whether the
  # registry load actually succeeded before reporting deprecations.
  class RegistryModels
    REGISTRY_PROVIDER_ALIASES = {
      "gemini" => "google"
    }.freeze

    # Below this many models for a provider we treat the registry as degraded
    # (e.g. the upstream models.dev fetch failed and the cache is thin) and
    # suppress deprecation signals to avoid false alarms.
    HEALTHY_PROVIDER_THRESHOLD = 3

    def self.fetch
      new.tap(&:load)
    end

    def initialize
      @models = nil
      @fetched = false
    end

    def load
      fetched = fetch_registry_models
      @fetched = !fetched.nil?
      @models = Array(fetched)
      self
    end

    # True when the registry returned a non-empty model list.
    def fetched?
      @fetched
    end

    def all
      @models
    end

    def for_provider(provider)
      target = normalized_provider(provider)
      @models.select { |model| normalized_provider(model.provider) == target }
    end

    # True when the registry loaded and surfaced a plausible number of models
    # for the provider — the precondition for trusting "missing => deprecated".
    def healthy?(provider)
      fetched? && for_provider(provider).size >= HEALTHY_PROVIDER_THRESHOLD
    end

    # { model_id => { normalized_provider => registry_model } }
    def grouped_by_id
      @models.each_with_object({}) do |model, index|
        next if model.id.blank?

        index[model.id] ||= {}
        index[model.id][normalized_provider(model.provider)] ||= model
      end
    end

    def self.normalized_provider(provider)
      REGISTRY_PROVIDER_ALIASES.fetch(provider.to_s, provider.to_s)
    end

    def normalized_provider(provider)
      self.class.normalized_provider(provider)
    end

    private

    def fetch_registry_models
      require "ruby_llm"

      RubyLLM.models.refresh!
      models = Array(RubyLLM.models.all)
      return models if models.any?

      log_registry_fallback(reason: "empty_registry")
      nil
    rescue LoadError, StandardError => e
      log_registry_fallback(
        reason: "registry_unavailable",
        error_class: e.class.name,
        error_message: e.message
      )
      nil
    end

    def log_registry_fallback(reason:, error_class: nil, error_message: nil)
      Rails.logger.warn(
        message: "model_registry.registry_fallback",
        registry: "ruby_llm",
        reason: reason,
        fallback: "known_models",
        error_class: error_class,
        error_message: error_message
      )
    end
  end
end
