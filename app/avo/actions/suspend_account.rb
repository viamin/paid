# frozen_string_literal: true

class Avo::Actions::SuspendAccount < Avo::Actions::AccountLifecycleAction
  self.name = "Suspend Account"

  private

  def execute_transition!(account, current_user:)
    account.suspend!
    log_transition("suspend", account, current_user)
  end

  def success_message(account)
    "Suspended account #{account.name}."
  end
end
