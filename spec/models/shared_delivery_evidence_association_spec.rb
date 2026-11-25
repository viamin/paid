# frozen_string_literal: true

require "rails_helper"

RSpec.describe SharedDeliveryEvidenceAssociation do # @spec PARTIAL-CLOSEOUT-063
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner, owner: "acme", repo: "alpha") }
  let(:other_project) { create(:project, account:, created_by: owner, owner: "acme", repo: "beta") }
  let(:target) { create(:issue, project:, github_state: "open") }

  def merged_pr(project)
    create(:issue, :pull_request, project:, github_number: 5305, github_state: "closed",
      pr_review_phase: "merged", github_html_url: "https://github.com/#{project.full_name}/pull/5305",
      merged_commit_sha: "a" * 40)
  end

  def insert_link(pull_request, association_project)
    described_class.insert!({ account_id: account.id, project_id: association_project.id,
      issue_id: target.id, pull_request_id: pull_request.id, authorized_by_id: owner.id,
      pull_request_url: pull_request.github_html_url, revision: pull_request.merged_commit_sha,
      created_at: Time.current, updated_at: Time.current })
  end

  it "permits same-project raw SQL evidence under the restricted tenant role" do
    pull_request = merged_pr(project)

    TenantContext.with(account) do
      expect(ActiveRecord::Base.connection.select_one(
        "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
      )).to include("rolsuper" => false, "rolbypassrls" => false)
      insert_link(pull_request, project)
      expect(Issues::CloseoutEvidence.call(target)).to be_present
    end
  end

  it "rejects a same-account different-project issue at raw SQL admission" do
    pull_request = merged_pr(other_project)

    TenantContext.with(account) do
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { insert_link(pull_request, other_project) }
      }.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
      expect(Issues::CloseoutEvidence.call(target)).not_to be_present
    end
  end

  it "rejects a same-account different-project PR at raw SQL admission" do
    pull_request = merged_pr(other_project)

    TenantContext.with(account) do
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { insert_link(pull_request, project) }
      }.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
      expect(Issues::CloseoutEvidence.call(target)).not_to be_present
    end
  end

  it "refuses legacy mismatched rows at model and closeout consumption" do
    pull_request = merged_pr(other_project)
    insert_link(pull_request, other_project)
    association = described_class.find_by!(issue_id: target.id)

    TenantContext.with(account) do
      aggregate_failures do
        expect(association.current?).to be(false)
        expect(Issues::CloseoutEvidence.call(target)).not_to be_present
      end
    end
  end

  # @spec TENANT-ACCESS-003 PARTIAL-CLOSEOUT-064
  it "fails closed when preserved historical evidence has no authorizer" do
    pull_request = merged_pr(project)
    association = described_class.create!(account:, project:, issue: target,
      pull_request:, authorized_by: owner, pull_request_url: pull_request.github_html_url,
      revision: pull_request.merged_commit_sha)

    association.update_column(:authorized_by_id, nil)

    expect(association.reload).not_to be_current
  end

  # @spec PARTIAL-CLOSEOUT-063 PARTIAL-CLOSEOUT-064
  it "refuses new evidence without a same-account authorizer" do
    pull_request = merged_pr(project)
    attributes = {
      account:, project:, issue: target, pull_request:,
      pull_request_url: pull_request.github_html_url,
      revision: pull_request.merged_commit_sha
    }

    missing_authorizer = described_class.new(**attributes, authorized_by: nil)
    foreign_authorizer = described_class.new(**attributes, authorized_by: create(:user))

    expect(missing_authorizer).to be_invalid
    expect(foreign_authorizer).to be_invalid
    expect(missing_authorizer.errors[:authorized_by]).to include("must belong to the account")
    expect(foreign_authorizer.errors[:authorized_by]).to include("must belong to the account")
  end
end
