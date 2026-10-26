# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAG-003 @spec QUEUE-DIAG-007 @spec QUEUE-DIAG-009
RSpec.describe Issues::QueueBlockers do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
  end
  let(:github_client) do
    instance_double(GithubClient, add_labels_to_issue: nil, remove_label_from_issue: nil)
  end

  before do
    allow(project).to receive(:client).and_return(github_client)
  end

  describe ".call" do
    it "reports no blockers for an issue with nothing in its way" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(issue)

      expect(result.blockers).to be_empty
      expect(result.blocked?).to be(false)
    end

    it "names the owning prerequisite work for an unmet dependency" do
      blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
      dependent = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      result = described_class.call(dependent)

      prerequisite = result.blockers.detect { |candidate| candidate.code == :unmet_prerequisites }
      expect(prerequisite).to be_present
      expect(prerequisite.owner).to include("##{blocker.github_number}")
      expect(prerequisite.recovery).to be_present
    end

    it "reports every simultaneous blocker rather than only the first one" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "manual_review",
        labels: [ "tracking" ], manual_review_reason: "Round limit reached.")

      result = described_class.call(issue)

      expect(result.blockers.map(&:code)).to include(:human_decision, :skip_label)
    end

    it "reports a human decision as owned by the operator" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "needs_input")

      result = described_class.call(issue)

      human = result.blockers.detect { |candidate| candidate.code == :human_decision }
      expect(human.owner).to eq("operator")
      expect(result.human_decision?).to be(true)
    end

    it "reports a deliberate pause as a pause rather than a dependency hold" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      issue.update!(paused: true)

      result = described_class.call(issue)

      expect(result.paused?).to be(true)
      expect(result.blockers.map(&:code)).to include(:issue_paused)
    end

    it "reports an untrusted author with the administrator as the owner" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new",
        github_creator_login: "untrusted-user")

      result = described_class.call(issue)

      trust = result.blockers.detect { |candidate| candidate.code == :untrusted_author }
      expect(trust.owner).to eq("project administrator")
    end

    it "reports a merged delivery as terminal evidence owned by the pull request" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, :pull_request, project: project, parent_issue: issue,
        pr_review_phase: "merged", github_number: issue.github_number + 1)

      result = described_class.call(issue)

      delivery = result.blockers.detect { |candidate| candidate.code == :merged_delivery }
      expect(delivery).to be_present
      expect(delivery.owner).to include("##{issue.github_number + 1}")
    end

    it "does not reconcile a planning hold while producing blockers" do
      expect(FeatureIntents::ReleaseIssue).not_to receive(:call)

      described_class.call(create(:issue, project: project, github_state: "open", paid_state: "new"))
    end

    it "reports a retry-abandoned issue as an operator hold" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new",
        runner_retry_abandoned_at: Time.current, runner_retry_abandon_reason: "cap reached")

      result = described_class.call(issue)

      expect(result.blockers.map(&:code)).to include(:retry_abandoned)
    end
  end
end
