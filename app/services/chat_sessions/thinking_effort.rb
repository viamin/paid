# frozen_string_literal: true

module ChatSessions
  # Derives which reasoning/thinking-effort values are valid for a chat
  # session's effective model, and resolves/normalizes a user's persisted
  # preference against them. Mirrors CuratedModelOptions' role for the model
  # tier: the catalog, not a hardcoded Paid provider table, is the source of
  # truth for which values exist.
  # @spec CHAT-THINKING-EFFORT-001
  class ThinkingEffort
    METADATA_KEY = "thinking_effort"
    LABELS = { "low" => "Low", "medium" => "Medium", "high" => "High" }.freeze
    DEFAULT_LABEL = "Default (model picks)"

    Option = Data.define(:value, :label)

    def self.allowed_values(model_id, catalog_models_by_id: nil)
      return [] if model_id.blank?
      return [] unless transport_supported?

      model = catalog_models_by_id ? catalog_models_by_id[model_id] : LlmModel.find_by_model_id(model_id)
      model&.reasoning_effort_values || []
    end

    # Catalog rows for the given model ids, keyed by model id. Empty while the
    # transport cannot carry reasoning effort, so no caller can offer effort
    # values the transport would drop.
    # @spec CHAT-THINKING-EFFORT-001
    def self.catalog_models_by_id(model_ids)
      return {} unless transport_supported?

      LlmModel.where(model_id: model_ids.compact.uniq).index_by(&:model_id)
    end

    # A catalog declaration alone is not enough to offer this control. The
    # active chat transport must also accept the normalized value; otherwise a
    # valid-looking selection could never reach the provider. The current
    # agent-harness release deliberately returns false here until its public
    # ChatTransport capability/request contract is available.
    # @spec CHAT-THINKING-EFFORT-001
    def self.transport_supported?
      BuildLlmClient::HttpClient.reasoning_effort_transport_supported?
    end

    # @spec CHAT-THINKING-EFFORT-002
    def self.options_for(model_id, catalog_models_by_id: nil)
      allowed_values(model_id, catalog_models_by_id:).map { |value| Option.new(value: value, label: LABELS.fetch(value, value.to_s.capitalize)) }
    end

    # Silently realigns a stored preference against (possibly new) model_id:
    # the value unchanged when still valid, nil (the explicit default)
    # otherwise. For system-driven model changes (tier/runner switch,
    # runner-fallback) rather than a direct, validated user submission.
    # @spec CHAT-THINKING-EFFORT-005 CHAT-THINKING-EFFORT-007
    def self.normalize(model_id:, value:, catalog_models_by_id: nil)
      return nil if value.blank?

      allowed_values(model_id, catalog_models_by_id:).include?(value.to_s) ? value.to_s : nil
    end

    # Retains only a preference that the effective model and transport still
    # support. Default is represented by an absent key, rather than a null
    # value that would create a spurious metadata update. An explicit `value:`
    # overrides the stored one, so a validated user submission and a
    # system-driven realignment share this single write path.
    # @spec CHAT-THINKING-EFFORT-005 CHAT-THINKING-EFFORT-006
    def self.normalize_metadata(metadata:, model_id:, catalog_models_by_id: nil, value: metadata[METADATA_KEY])
      normalized = normalize(model_id:, value:, catalog_models_by_id:)
      metadata = metadata.dup
      normalized ? metadata[METADATA_KEY] = normalized : metadata.delete(METADATA_KEY)
      metadata
    end

    # Validates a direct, user-submitted value against model_id's allowed
    # values, raising when it names an effort the effective model cannot
    # accept — a stale or crafted submission must be rejected, not silently
    # downgraded.
    # @spec CHAT-THINKING-EFFORT-006
    def self.resolve!(model_id:, value:)
      return nil if value.blank?

      return value.to_s if allowed_values(model_id).include?(value.to_s)

      raise ArgumentError, "#{value} is not a supported thinking effort for this model."
    end
  end
end
