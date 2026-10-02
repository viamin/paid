# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-014
RSpec.describe FeatureIntentApprovalRevision do
  describe "validations" do
    it "requires an approved_at" do
      revision = build(:feature_intent_approval_revision, approved_at: nil)

      expect(revision).not_to be_valid
      expect(revision.errors[:approved_at]).to be_present
    end

    it "requires a source" do
      revision = build(:feature_intent_approval_revision, source: nil)

      expect(revision).not_to be_valid
      expect(revision.errors[:source]).to be_present
    end

    it "requires a unique revision_number per feature intent" do
      feature_intent = create(:feature_intent, :ready_for_approval)
      create(:feature_intent_approval_revision, feature_intent: feature_intent, revision_number: 1)
      duplicate = build(:feature_intent_approval_revision, feature_intent: feature_intent, revision_number: 1)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:revision_number]).to be_present
    end
  end

  describe "immutability" do
    it "rejects instance-level updates with ReadOnlyRecord" do
      revision = create(:feature_intent_approval_revision)

      expect { revision.update!(source: "changed") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "rejects instance-level destroys with ReadOnlyRecord" do
      revision = create(:feature_intent_approval_revision)

      expect { revision.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "rejects bulk updates with update_all" do
      revision = create(:feature_intent_approval_revision)
      original_source = revision.source

      expect_db_rejection(/append-only/i) do
        described_class.where(id: revision.id).update_all(source: "bulk_changed")
      end

      expect(revision.reload.source).to eq(original_source)
    end

    it "rejects bulk deletes with delete_all" do
      revision = create(:feature_intent_approval_revision)

      expect_db_rejection(/append-only/i) do
        described_class.where(id: revision.id).delete_all
      end

      expect(described_class.exists?(revision.id)).to be(true)
    end

    it "rejects direct SQL UPDATE attempts" do
      revision = create(:feature_intent_approval_revision)
      connection = described_class.connection

      expect_db_rejection(/append-only/i) do
        connection.execute(
          "UPDATE feature_intent_approval_revisions SET source = 'sql_changed' WHERE id = #{revision.id}"
        )
      end

      expect(revision.reload.source).to eq("inbox")
    end

    it "rejects direct SQL DELETE attempts" do
      revision = create(:feature_intent_approval_revision)
      connection = described_class.connection

      expect_db_rejection(/append-only/i) do
        connection.execute("DELETE FROM feature_intent_approval_revisions WHERE id = #{revision.id}")
      end

      expect(described_class.exists?(revision.id)).to be(true)
    end
  end

  private

  # Wraps `yield` in a SAVEPOINT so a database error (which would otherwise
  # poison the spec's transaction) only rolls back to the savepoint and
  # leaves the surrounding test transaction usable.
  def expect_db_rejection(pattern)
    connection = ActiveRecord::Base.connection
    connection.execute("SAVEPOINT approval_revision_rejection")
    expect { yield }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  ensure
    connection.execute("ROLLBACK TO SAVEPOINT approval_revision_rejection")
    connection.execute("RELEASE SAVEPOINT approval_revision_rejection")
  end
end
