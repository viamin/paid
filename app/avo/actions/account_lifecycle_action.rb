# frozen_string_literal: true

class Avo::Actions::AccountLifecycleAction < Avo::BaseAction
  self.visible = -> { resource.record.present? }

  def handle(query:, fields:, current_user:, resource:, **)
    return error("Select exactly one account.") unless query.one?

    account = query.first

    execute_transition!(account, current_user:)
    succeed(success_message(account))
  rescue Account::InvalidTransitionError => error_message
    error(error_message.message)
  rescue ActiveRecord::RecordInvalid => error_message
    error(error_message.record.errors.full_messages.to_sentence)
  end

  private

  def execute_transition!(_account, current_user:)
    raise NotImplementedError
  end

  def success_message(_account)
    raise NotImplementedError
  end

  def log_transition(action_name, account, current_user)
    Rails.logger.info(
      message: "operator_console.account_lifecycle",
      action: action_name,
      actor_user_id: current_user.id,
      actor_user_email: current_user.email,
      account_id: account.id,
      outcome: "success"
    )
  end
end
