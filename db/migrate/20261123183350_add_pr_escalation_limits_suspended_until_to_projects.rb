class AddPrEscalationLimitsSuspendedUntilToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :pr_escalation_limits_suspended_until, :datetime,
      comment: "Exclusive deadline for suspending automatic PR follow-up and cumulative token limits."
  end
end
