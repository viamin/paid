# frozen_string_literal: true

# Escalation used to set `auto_continue_paused`, the operator's own per-PR
# pause. Because the PR scan excludes paused pull requests at the source, that
# hid escalated PRs from the scan that detects their recovery — removing the
# `paid-escalated` label became a no-op. The escalated phase is the hold now, so
# release the pause the system set.
#
# The phase disambiguates the two writers: the operator toggle never touches
# `pr_review_phase`, so an open pull request sitting at `escalated` was stopped
# by the system, not by its owner.
#
# @spec PR-ESCALATION-018
class ReleaseEscalationSetAutoContinuePause < ActiveRecord::Migration[8.1]
  def up
    Issue.reset_column_information

    # issues carries forced tenant RLS, so a migration running without a tenant
    # context matches zero rows and silently no-ops.
    TenantContext.with_system_access do
      Issue.where(
        is_pull_request: true,
        github_state: "open",
        pr_review_phase: "escalated",
        auto_continue_paused: true
      # Deliberately not touching updated_at: Dashboard::BlockedPullRequests
      # reads it as "blocked since" and orders by it, so bumping it here would
      # reset every already-blocked PR to "just now" on the deploy that ships
      # the panel.
      ).update_all(auto_continue_paused: false)
    end
  end

  def down
    # Not reversible: the released pause is indistinguishable from a pull
    # request the operator never paused, so re-pausing would invent operator
    # intent that was never recorded.
    raise ActiveRecord::IrreversibleMigration
  end
end
