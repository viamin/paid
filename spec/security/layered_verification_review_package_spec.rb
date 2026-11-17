# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationReviewPackage, :tenant_isolation do
  # Reference consistency must hold even for deliberate system access.
  around { |example| TenantContext.with_system_access { example.run } }

  let(:project) { create(:project) }
  let(:audit) { create(:agent_run, project:, goal: "layered_verification_audit") }
  let(:package) { create(:layered_verification_review_package, project:, agent_run: audit) }

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects bound check results from another project" do
    other = create(:project, account: project.account)
    result = create(:layered_verification_check_result,
      obligation: create(:layered_verification_obligation, project: other),
      agent_run: create(:agent_run, project: other))

    expect do
      described_class.transaction(requires_new: true) do
        package.update_columns(bound_inputs: package.bound_inputs.merge("check_result_ids" => [ result.id ]))
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects bound approvals from another project" do
    other = create(:project, account: project.account)
    other_package = create(:layered_verification_review_package, project: other)
    approval = create(:layered_verification_review_approval, package: other_package)

    expect do
      described_class.transaction(requires_new: true) do
        package.update_columns(bound_inputs: package.bound_inputs.merge("approval_ids" => [ approval.id ]))
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects a bound Inbox decision for another project's finding" do
    other = create(:project, account: project.account)
    finding = create(:layered_verification_finding, project: other,
      obligation: create(:layered_verification_obligation, project: other),
      agent_run: create(:agent_run, project: other))

    expect do
      described_class.transaction(requires_new: true) do
        package.update_columns(bound_inputs: package.bound_inputs.merge("inbox_decisions" => [ { "finding_id" => finding.id } ]))
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects a direct bound obligation reference from another project in the same account" do
    foreign = create(:layered_verification_obligation, project: create(:project, account: project.account))
    expect do
      described_class.transaction(requires_new: true) do
        package.update_columns(bound_inputs: package.bound_inputs.merge("obligations" => [ { "id" => foreign.id } ]))
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects a direct cross-project run reference after schema-based bootstrap" do
    foreign_run = create(:agent_run, project: create(:project, account: project.account))
    expect do
      described_class.transaction(requires_new: true) { package.update_columns(agent_run_id: foreign_run.id) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "rejects a foreign approval actor after schema-based bootstrap" do
    actor = create(:user, :owner)
    expect do
      LayeredVerificationReviewApproval.transaction(requires_new: true) do
        create(:layered_verification_review_approval, package:, approved_by: actor)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
