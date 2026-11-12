# frozen_string_literal: true

# Bidirectional provider-native/Paid lifecycle state mapping. A project-scoped
# row overrides the account default for that project; a null `project_id` row
# is the account default.
#
# @spec UNIFIED-WORK-ITEMS-006
class WorkItemLifecycleMapping < ApplicationRecord
  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :provider, :native_state, :paid_state, presence: true
  validate :project_belongs_to_same_account

  class << self
    # Resolves the most specific mapping (project override, then account
    # default) from a provider-native state to a Paid lifecycle state.
    def paid_state_for(account:, provider:, native_state:, project: nil)
      resolve(account:, provider:, project:) { |scope| scope.find_by(native_state:) }&.paid_state
    end

    # The reverse direction: Paid lifecycle state to provider-native state.
    def native_state_for(account:, provider:, paid_state:, project: nil)
      resolve(account:, provider:, project:) { |scope| scope.find_by(paid_state:) }&.native_state
    end

    private

    def resolve(account:, provider:, project:)
      base = account.work_item_lifecycle_mappings.where(provider:)
      if project
        yield(base.where(project_id: project.id)) || yield(base.where(project_id: nil))
      else
        yield(base.where(project_id: nil))
      end
    end
  end

  private

  def project_belongs_to_same_account
    return if project.nil? || project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
