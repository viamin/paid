# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeIntent do
  include ActiveSupport::Testing::TimeHelpers

  subject(:change_intent) { build(:change_intent) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:chat_session).optional }
    it { is_expected.to belong_to(:issue).optional }
    it { is_expected.to belong_to(:superseded_by).class_name("ChangeIntent").optional }
    it { is_expected.to have_many(:supersedes).class_name("ChangeIntent") }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(500) }
    it { is_expected.to validate_presence_of(:intent) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "rejects chat sessions from a different project" do
      other_project = create(:project)
      record = build(:change_intent, chat_session: create(:chat_session, project: other_project, account: other_project.account))

      expect(record).not_to be_valid
      expect(record.errors[:chat_session]).to include("must belong to the same project")
    end

    it "accepts a referenced chat session for the same project" do
      project = create(:project)
      session = create(:chat_session, account: project.account, project: nil)
      create(:chat_session_project, chat_session: session, project: project)
      record = build(:change_intent, project: project, chat_session: session, issue: create(:issue, project: project))

      expect(record).to be_valid
    end

    it "rejects an issue from a different project" do
      other_issue = create(:issue)
      record = build(:change_intent, issue: other_issue)

      expect(record).not_to be_valid
      expect(record.errors[:issue]).to include("must belong to the same project")
    end

    it "rejects superseded_by from a different project" do
      other_record = create(:change_intent)
      record = build(:change_intent, superseded_by: other_record)

      expect(record).not_to be_valid
      expect(record.errors[:superseded_by]).to include("must belong to the same project")
    end

    it "rejects superseded_by referencing itself" do
      record = create(:change_intent)
      record.superseded_by = record

      expect(record).not_to be_valid
      expect(record.errors[:superseded_by]).to include("cannot reference itself")
    end
  end

  describe "immutability" do
    it "prevents updating content fields after creation" do
      record = create(:change_intent)
      record.title = "New title"

      expect(record.save).to be false
      expect(record.errors[:title]).to include("is immutable after creation")
    end

    it "allows updating status" do
      record = create(:change_intent, :draft)
      record.status = "active"

      expect(record.save).to be true
    end

    it "allows updating superseded_by" do
      record = create(:change_intent)
      replacement = create(:change_intent, project: record.project)
      record.superseded_by = replacement

      expect(record.save).to be true
    end

    it "allows revising content while the record is pending review" do
      record = create(:change_intent, :draft)

      record.revise!({ title: "Revised title", intent: "Revised intent" })

      expect(record.reload).to have_attributes(title: "Revised title", intent: "Revised intent")
    end

    it "clears requested-changes feedback when a revision returns the draft for review" do
      record = create(:change_intent, status: "requested_changes",
                       requested_changes_at: 1.hour.ago,
                       requested_changes_reason: "Clarify the constraint.")

      record.revise!({ title: "Clarified title", intent: "Clarified intent" })

      expect(record.reload).to have_attributes(
        status: "draft",
        requested_changes_at: nil,
        requested_changes_reason: nil
      )
    end
  end

  describe "scopes" do
    it "returns only active records from .active" do
      active = create(:change_intent, status: "active")
      create(:change_intent, :draft)

      expect(described_class.active).to eq([ active ])
    end

    it "returns only draft records from .draft" do
      create(:change_intent, status: "active")
      draft = create(:change_intent, :draft)

      expect(described_class.draft).to eq([ draft ])
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "returns every pending-review record from .pending_review" do
      draft = create(:change_intent, :draft)
      changes = create(:change_intent, status: "requested_changes")
      create(:change_intent, status: "active")
      create(:change_intent, status: "superseded")

      expect(described_class.pending_review).to contain_exactly(draft, changes)
    end
  end

  describe "#activate!" do
    it "transitions from draft to active" do
      record = create(:change_intent, :draft)

      record.activate!

      expect(record.reload.status).to eq("active")
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "transitions from requested_changes back to active" do
      record = create(:change_intent, status: "requested_changes",
                                       requested_changes_at: 1.hour.ago,
                                       requested_changes_reason: "Reword the title.")

      record.activate!

      expect(record.reload.status).to eq("active")
      expect(record.requested_changes_at).to be_nil
      expect(record.requested_changes_reason).to be_nil
    end

    it "raises when not in draft" do
      record = create(:change_intent, status: "active")

      expect { record.activate! }.to raise_error(ChangeIntent::InvalidTransitionError, /cannot activate from active/)
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  describe "#request_changes!" do
    it "transitions from draft to requested_changes with a stamped reason and timestamp" do
      freeze_time = nil
      record = create(:change_intent, :draft)

      travel_to(Time.current) do
        freeze_time = Time.current
        record.request_changes!(reason: "Reword the title.")
      end

      expect(record.reload).to have_attributes(
        status: "requested_changes",
        requested_changes_reason: "Reword the title.",
        requested_changes_at: freeze_time
      )
    end

    it "overwrites prior review metadata when re-entered from requested_changes" do
      record = create(:change_intent, status: "requested_changes",
                                       requested_changes_at: 1.hour.ago,
                                       requested_changes_reason: "Old reason.")

      travel_to(Time.current) do
        record.request_changes!(reason: "Fresh reason.")
      end

      expect(record.reload).to have_attributes(
        status: "requested_changes",
        requested_changes_reason: "Fresh reason."
      )
      expect(record.requested_changes_at).to be_within(2.seconds).of(Time.current)
    end

    it "raises when activating from an already terminal status" do
      record = create(:change_intent, status: "active")

      expect { record.request_changes!(reason: "Too late.") }
        .to raise_error(ChangeIntent::InvalidTransitionError, /cannot request changes from active/)
    end
  end

  describe "#requested_changes?" do
    it "is true when the status is requested_changes" do
      expect(build(:change_intent, status: "requested_changes")).to be_requested_changes
    end

    it "is false for any other status" do
      %w[draft active superseded reverted].each do |status|
        expect(build(:change_intent, status: status)).not_to be_requested_changes
      end
    end
  end

  describe "#pending_review?" do
    it "is true for draft and requested_changes" do
      expect(build(:change_intent, :draft)).to be_pending_review
      expect(build(:change_intent, status: "requested_changes")).to be_pending_review
    end

    it "is false for terminal statuses" do
      %w[active superseded reverted].each do |status|
        expect(build(:change_intent, status: status)).not_to be_pending_review
      end
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  describe "inbox cache invalidation" do
    let(:project) { create(:project) }
    let(:account) { project.account }

    it "bumps the inbox cache version when a draft is recorded" do
      expect(Dashboard::CacheVersion).to receive(:bump)
        .with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      create(:change_intent, :draft, project: project)
    end

    it "bumps the inbox cache version when a draft transitions into requested_changes" do
      record = create(:change_intent, :draft, project: project)

      expect(Dashboard::CacheVersion).to receive(:bump)
        .with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      record.request_changes!(reason: "Reword the title.")
    end

    it "bumps the inbox cache version when a record is activated" do
      record = create(:change_intent, :draft, project: project)

      expect(Dashboard::CacheVersion).to receive(:bump)
        .with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      record.activate!
    end

    it "bumps the inbox cache version when a pending-review record is destroyed" do
      record = create(:change_intent, :draft, project: project)

      expect(Dashboard::CacheVersion).to receive(:bump)
        .with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

      record.destroy!
    end

    it "does not bump the cache when an unrelated status changes" do
      record = create(:change_intent, status: "active", project: project)

      expect(Dashboard::CacheVersion).not_to receive(:bump)

      record.revert!
    end
  end

  describe "#supersede!" do
    it "marks the record as superseded by the given record" do
      original = create(:change_intent)
      replacement = create(:change_intent, project: original.project)

      original.supersede!(replacement)

      expect(original.reload.status).to eq("superseded")
      expect(original.superseded_by).to eq(replacement)
    end

    it "raises when superseding with itself" do
      record = create(:change_intent)

      expect { record.supersede!(record) }.to raise_error(ArgumentError, "cannot supersede with itself")
    end

    it "raises when already superseded" do
      record = create(:change_intent, status: "superseded")
      replacement = create(:change_intent, project: record.project)

      expect { record.supersede!(replacement) }.to raise_error(ChangeIntent::InvalidTransitionError, /cannot supersede from superseded/)
    end
  end

  describe "#revert!" do
    it "transitions from draft to reverted" do
      record = create(:change_intent, :draft)

      record.revert!

      expect(record.reload.status).to eq("reverted")
    end

    it "transitions from active to reverted" do
      record = create(:change_intent, status: "active")

      record.revert!

      expect(record.reload.status).to eq("reverted")
    end

    it "raises when already superseded" do
      record = create(:change_intent, status: "superseded")

      expect { record.revert! }.to raise_error(ChangeIntent::InvalidTransitionError, /cannot revert from superseded/)
    end
  end
end
