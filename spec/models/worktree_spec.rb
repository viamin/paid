# frozen_string_literal: true

require "rails_helper"

RSpec.describe Worktree do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
  end

  describe "validations" do
    subject { build(:worktree, project: project, agent_run: agent_run) }

    it { is_expected.to validate_presence_of(:path) }
    it { is_expected.to validate_presence_of(:branch_name) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_length_of(:base_commit).is_at_most(40) }

    it "validates uniqueness of branch_name scoped to project" do
      create(:worktree, project: project, agent_run: agent_run, branch_name: "paid/unique-branch")
      other_run = create(:agent_run, project: project)
      worktree = build(:worktree, project: project, agent_run: other_run, branch_name: "paid/unique-branch")

      expect(worktree).not_to be_valid
      expect(worktree.errors[:branch_name]).to include("has already been taken")
    end

    it "allows same branch_name on different projects" do
      other_project = create(:project)
      create(:worktree, project: project, agent_run: agent_run, branch_name: "paid/shared-branch")
      other_run = create(:agent_run, project: other_project)
      worktree = build(:worktree, project: other_project, agent_run: other_run, branch_name: "paid/shared-branch")

      expect(worktree).to be_valid
    end
  end

  describe "scopes" do
    let!(:active_worktree) { create(:worktree, project: project, agent_run: agent_run) }
    let!(:cleaned_worktree) do
      other_run = create(:agent_run, project: project)
      create(:worktree, :cleaned, project: project, agent_run: other_run)
    end

    describe ".active" do
      it "returns only active worktrees" do
        expect(described_class.active).to contain_exactly(active_worktree)
      end
    end

    describe ".cleaned" do
      it "returns only cleaned worktrees" do
        expect(described_class.cleaned).to contain_exactly(cleaned_worktree)
      end
    end

    describe ".stale" do
      it "returns active worktrees older than threshold" do
        stale_run = create(:agent_run, project: project)
        stale = create(:worktree, project: project, agent_run: stale_run, created_at: 25.hours.ago)

        expect(described_class.stale(24.hours)).to contain_exactly(stale)
      end
    end

    describe ".orphaned" do
      it "includes worktrees for completed agent runs" do
        completed_run = create(:agent_run, :completed, project: project)
        orphan = create(:worktree, project: project, agent_run: completed_run)

        expect(described_class.orphaned).to include(orphan)
      end

      it "includes worktrees without agent runs" do
        orphan = create(:worktree, :without_agent_run, project: project)

        expect(described_class.orphaned).to include(orphan)
      end

      it "includes worktrees older than 24 hours" do
        old_run = create(:agent_run, :running, project: project)
        stale = create(:worktree, project: project, agent_run: old_run, created_at: 25.hours.ago)

        expect(described_class.orphaned).to include(stale)
      end

      it "excludes active worktrees for running agent runs within 24 hours" do
        running_run = create(:agent_run, :running, project: project)
        fresh = create(:worktree, project: project, agent_run: running_run)

        expect(described_class.orphaned).not_to include(fresh)
      end
    end
  end

  describe "status methods" do
    let(:worktree) { create(:worktree, project: project, agent_run: agent_run) }

    describe "#active?" do
      it "returns true when status is active" do
        expect(worktree.active?).to be true
      end

      it "returns false when status is cleaned" do
        worktree.update!(status: "cleaned", cleaned_at: Time.current)
        expect(worktree.active?).to be false
      end
    end

    describe "#cleaned?" do
      it "returns true when status is cleaned" do
        worktree.update!(status: "cleaned", cleaned_at: Time.current)
        expect(worktree.cleaned?).to be true
      end
    end

    describe "#pushed?" do
      it "returns false by default" do
        expect(worktree.pushed?).to be false
      end

      it "returns true when pushed" do
        worktree.update!(pushed: true)
        expect(worktree.pushed?).to be true
      end
    end

    describe "#mark_pushed!" do
      it "sets pushed to true" do
        worktree.mark_pushed!
        expect(worktree.reload.pushed).to be true
      end
    end

    describe "#mark_cleaned!" do
      it "sets status to cleaned and cleaned_at" do
        freeze_time do
          worktree.mark_cleaned!
          worktree.reload
          expect(worktree.status).to eq("cleaned")
          expect(worktree.cleaned_at).to eq(Time.current)
        end
      end
    end

    describe "#mark_cleanup_failed!" do
      it "sets status to cleanup_failed" do
        worktree.mark_cleanup_failed!
        expect(worktree.reload.status).to eq("cleanup_failed")
      end
    end
  end
end
