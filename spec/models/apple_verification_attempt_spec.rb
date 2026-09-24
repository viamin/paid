# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempt, type: :model do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:profile) { create(:apple_worker_profile, account: account) }
  let(:workflow) { create(:apple_verification_workflow_revision, project: project, account: account, apple_worker_profile: profile) }
  let(:administrator) do
    user = create(:user, account: account)
    user.add_role(:project_admin, project)
    user
  end

  describe ".active" do
    it "returns VM-owning provisioning and running attempts but not queued or terminal ones" do
      queued = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "queued")
      provisioning = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "provisioning")
      running = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "running")
      succeeded = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "succeeded")

      expect(described_class.active).to contain_exactly(provisioning, running)
      expect(described_class.active).not_to include(queued, succeeded)
    end
  end

  describe ".queued" do
    it "returns only queued attempts" do
      queued = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "queued")
      create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "running")

      expect(described_class.queued).to contain_exactly(queued)
    end
  end

  describe ".for_account and .for_project" do
    it "scopes to the supplied account or project" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      other_profile = create(:apple_worker_profile, account: other_account)
      other_workflow = create(:apple_verification_workflow_revision, project: other_project, account: other_account, apple_worker_profile: other_profile)

      local = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile)
      remote = create(:apple_verification_attempt, project: other_project, account: other_account, apple_verification_workflow_revision: other_workflow, apple_worker_profile: other_profile)

      expect(described_class.for_account(account)).to contain_exactly(local)
      expect(described_class.for_project(other_project)).to contain_exactly(remote)
    end
  end

  describe ".timed_out_candidates" do
    it "returns provisioning and running attempts whose started_at is at or before the threshold" do
      stale = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "running", started_at: 1.hour.ago)
      fresh = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "running", started_at: 1.minute.ago)
      terminal = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "succeeded", started_at: 1.hour.ago, finished_at: 1.hour.ago)
      unstarted = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "queued", started_at: nil)

      expect(described_class.timed_out_candidates(30.minutes.ago)).to contain_exactly(stale)
      expect(described_class.timed_out_candidates(30.minutes.ago)).not_to include(fresh, terminal, unstarted)
    end
  end

  describe "status predicates" do
    let(:attempt) do
      create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow, apple_worker_profile: profile, status: "running")
    end

    it "exposes running, cancellable, and not terminal while provisioning" do
      expect(attempt).to be_running
      expect(attempt).not_to be_terminal
      expect(attempt).to be_cancellable
    end

    it "exposes queued while waiting in line" do
      attempt.update!(status: "queued")
      expect(attempt).to be_queued
      expect(attempt).to be_cancellable
    end

    it "exposes provisioning while cloning the VM" do
      attempt.update!(status: "provisioning")
      expect(attempt).to be_provisioning
    end

    it "exposes succeeded and terminal after success" do
      attempt.update!(status: "succeeded")
      expect(attempt).to be_succeeded
      expect(attempt).to be_terminal
      expect(attempt).not_to be_cancellable
    end

    it "exposes failed and terminal after failure" do
      attempt.update!(status: "failed")
      expect(attempt).to be_failed
      expect(attempt).to be_terminal
    end
  end
end
