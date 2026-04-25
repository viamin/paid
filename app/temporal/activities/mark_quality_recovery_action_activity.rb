# frozen_string_literal: true

module Activities
  class MarkQualityRecoveryActionActivity < BaseActivity
    activity_name "MarkQualityRecoveryAction"

    def execute(input)
      action = QualityRecoveryAction.find_by(id: input[:recovery_action_id])
      return { status: :not_found } unless action

      action.fail!(input.fetch(:result, {}))

      {
        status: :failed,
        recovery_action_id: action.id
      }
    end
  end
end
