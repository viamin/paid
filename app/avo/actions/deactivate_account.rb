# frozen_string_literal: true

class Avo::Actions::DeactivateAccount < Avo::Actions::AccountLifecycleAction
  self.name = "Deactivate Account"

  private

  def execute_transition!(account, current_user:)
    account.deactivate!
    log_transition("deactivate", account, current_user)
  end

  def success_message(account)
    "Deactivated account #{account.name}."
  end
end
