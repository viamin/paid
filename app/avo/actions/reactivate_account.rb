# frozen_string_literal: true

class Avo::Actions::ReactivateAccount < Avo::Actions::AccountLifecycleAction
  self.name = "Reactivate Account"

  private

  def execute_transition!(account, current_user:)
    account.reactivate!
    log_transition("reactivate", account, current_user)
  end

  def success_message(account)
    "Reactivated account #{account.name}."
  end
end
