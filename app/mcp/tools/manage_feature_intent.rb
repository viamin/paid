# frozen_string_literal: true

module Tools
  # @spec FEATURE-APPROVAL-020
  class ManageFeatureIntent < BaseTool
    authorize :cancel?, ->(args) { feature_intent_for(args.fetch(:feature_intent_id)) }, policy_class: FeatureIntentPolicy

    def self.tool_name = "manage_feature_intent"
    def self.write_operation? = true
    def self.description = "Decline an unwanted feature proposal or reopen a declined proposal. Requires explicit confirmation."

    def self.input_schema
      {
        type: "object",
        properties: {
          feature_intent_id: { type: "integer", description: "The feature intent ID" },
          action: { type: "string", enum: %w[cancel reopen], description: "Whether to decline or reopen the proposal" },
          cancellation_reason: { type: "string", enum: FeatureIntent::CANCELLATION_REASONS, description: "Required when declining" },
          replacement_reference: { type: "string", description: "Optional replacement issue, PR, or feature URL" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[feature_intent_id action confirmed]
      }
    end

    def perform(feature_intent_id:, action:, cancellation_reason: nil, replacement_reference: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to manage a feature proposal" unless confirmed

      feature_intent = feature_intent_for(feature_intent_id)
      manage(feature_intent, action:, cancellation_reason:, replacement_reference:)
      feature_intent.reload.slice("id", "status", "cancelled_at", "cancellation_reason", "replacement_reference")
    rescue FeatureIntents::Cancel::InvalidCancellationError, FeatureIntent::InvalidTransitionError => error
      raise ArgumentError, error.message
    end

    private

    def manage(feature_intent, action:, cancellation_reason:, replacement_reference:)
      case action
      when "cancel"
        FeatureIntents::Cancel.call(feature_intent:, actor: current_user, cancellation_reason:, replacement_reference:)
      when "reopen"
        FeatureIntents::Reopen.call(feature_intent:, actor: current_user)
      else
        raise ArgumentError, "action must be cancel or reopen"
      end
    end

    def feature_intent_for(id)
      @feature_intents_by_id ||= {}
      @feature_intents_by_id[id] ||= FeatureIntentPolicy::Scope.new(current_user, FeatureIntent).resolve.find(id)
    end
  end
end
