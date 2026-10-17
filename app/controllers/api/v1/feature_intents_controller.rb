# frozen_string_literal: true

module Api
  module V1
    # @spec FEATURE-APPROVAL-020
    class FeatureIntentsController < BaseController
      before_action -> { require_scope!(:inbox) }

      def cancel
        feature_intent = scoped_feature_intent
        authorize feature_intent, :cancel?, policy_class: FeatureIntentPolicy
        FeatureIntents::Cancel.call(feature_intent:, actor: current_user, **cancellation_attributes)
        render json: feature_payload(feature_intent.reload)
      rescue FeatureIntents::Cancel::InvalidCancellationError => error
        render_error(:unprocessable_entity, :validation_failed, error.message)
      rescue FeatureIntent::InvalidTransitionError => error
        render_error(:unprocessable_entity, :conflict, error.message)
      end

      def reopen
        feature_intent = scoped_feature_intent
        authorize feature_intent, :reopen?, policy_class: FeatureIntentPolicy
        FeatureIntents::Reopen.call(feature_intent:, actor: current_user)
        render json: feature_payload(feature_intent.reload)
      rescue FeatureIntent::InvalidTransitionError => error
        render_error(:unprocessable_entity, :invalid_transition, error.message)
      end

      private

      def scoped_feature_intent
        FeatureIntentPolicy::Scope.new(current_user, FeatureIntent).resolve.find(params[:id])
      end

      def cancellation_attributes
        params.permit(:cancellation_reason, :replacement_reference).to_h.symbolize_keys
      end

      def feature_payload(feature_intent)
        feature_intent.slice("id", "status", "cancelled_at", "cancellation_reason", "replacement_reference")
      end
    end
  end
end
