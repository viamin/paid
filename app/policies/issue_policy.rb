# frozen_string_literal: true

class IssuePolicy < ApplicationPolicy
  # Pausing mirrors state onto GitHub and changes automation behavior, so it
  # requires the same account-level permission as editing the project.
  def toggle_pause?
    ProjectPolicy.new(user, record.project).update?
  end

  private

  def account_for_record
    record.project.account
  end
end
