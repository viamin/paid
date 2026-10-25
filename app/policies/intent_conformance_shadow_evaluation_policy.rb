# frozen_string_literal: true

# Authorization for the solo-maintainer shadow-evaluation workflow (#4594).
# Every action stays inside the project's existing tenant boundary; only the
# declared solo maintainer may record labels, freeze, or revise, while any
# project operator may start an evaluation or trigger execution. An agent
# assisting navigation has no identity of its own — it can only act through
# the authenticated maintainer's session.
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-009
class IntentConformanceShadowEvaluationPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def evidence?
    show?
  end

  def create?
    operator?
  end

  def label?
    solo_maintainer? && operator?
  end

  # Skipping is a labeling action with the same boundary as labeling.
  def skip?
    label?
  end

  def freeze?
    solo_maintainer? && operator?
  end

  def revise?
    solo_maintainer? && operator?
  end

  def execute?
    operator?
  end

  # Cancellation shares the execute boundary (#4642): any project operator
  # may stop costly execution; the evidence already collected is preserved.
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  def cancel?
    execute?
  end

  private

  def project
    record.is_a?(IntentConformanceShadowEvaluation) ? record.project : record
  end

  # The evaluation has no direct account column; tenancy is keyed through
  # its project.
  def account_for_record
    project.account
  end

  def operator?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member)
  end

  def solo_maintainer?
    record.is_a?(IntentConformanceShadowEvaluation) && record.solo_maintainer_id == user&.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:project).where(projects: { account_id: user.account_id })
    end
  end
end
