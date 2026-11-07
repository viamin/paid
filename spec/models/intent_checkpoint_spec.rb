# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntentCheckpoint do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  def group(overrides = {})
    {
      "key" => "retention-policy",
      "affected_scope" => "Data retention policy",
      "questions" => [ "How long must imported metrics be retained?" ],
      "recommendation" => "Retain 30 days of imported metrics.",
      "alternatives" => [ "Retain 7 days", "Retain 90 days" ],
      "consequences" => [ "Longer retention increases storage cost." ],
      "evidence" => [ "docs/intent/data-pipeline/design.md" ]
    }.merge(overrides)
  end

  it "builds a valid pending checkpoint from grouped material questions" do  # @spec PROJECT-DELEGATION-002
    checkpoint = build(:intent_checkpoint, account:, project:, issue:, groups: [ group ])

    expect(checkpoint).to be_valid
    expect(checkpoint.status).to eq("pending")
  end

  it "rejects groups without keys, questions, scope, or recommendation" do  # @spec PROJECT-DELEGATION-002
    aggregate_failures do
      expect(build(:intent_checkpoint, account:, project:, issue:,
        groups: [ group("key" => nil) ])).not_to be_valid
      expect(build(:intent_checkpoint, account:, project:, issue:,
        groups: [ group("questions" => []) ])).not_to be_valid
      expect(build(:intent_checkpoint, account:, project:, issue:,
        groups: [ group("affected_scope" => "") ])).not_to be_valid
      expect(build(:intent_checkpoint, account:, project:, issue:,
        groups: [ group("recommendation" => nil) ])).not_to be_valid
    end
  end

  it "rejects duplicate group keys inside one checkpoint" do  # @spec PROJECT-DELEGATION-002
    checkpoint = build(:intent_checkpoint, account:, project:, issue:,
      groups: [ group, group("affected_scope" => "Another scope") ])

    expect(checkpoint).not_to be_valid
  end

  it "requires the revision binding on settled checkpoints" do  # @spec PROJECT-DELEGATION-002
    settled = build(:intent_checkpoint, account:, project:, issue:, groups: [ group ],
      status: "settled", disposition: "settled", answers: { "retention-policy" => "30 days" })

    expect(settled).not_to be_valid
    expect(settled.errors[:design_revision]).to be_present
    expect(settled.errors[:acceptance_revision]).to be_present
    expect(settled.errors[:settled_by]).to be_present
    expect(settled.errors[:settled_at]).to be_present

    settled.assign_attributes(
      design_revision: "design:abc", acceptance_revision: "criteria:def",
      settled_by: create(:user, account:), settled_at: Time.current
    )
    expect(settled).to be_valid
  end

  it "makes settled and rejected checkpoints immutable" do  # @spec PROJECT-DELEGATION-002
    settled = create(:intent_checkpoint, :settled, account:, project:, issue:, groups: [ group ],
      answers: { "retention-policy" => "30 days" })
    rejected = create(:intent_checkpoint, :rejected, account:, project:, issue:, groups: [ group ])

    expect { settled.update!(answers: { "retention-policy" => "90 days" }) }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { settled.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { rejected.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "blocks database-level mutation of terminal checkpoints" do  # @spec PROJECT-DELEGATION-002
    settled = create(:intent_checkpoint, :settled, account:, project:, issue:, groups: [ group ],
      answers: { "retention-policy" => "30 days" })

    expect {
      issue.class.connection.execute(
        "UPDATE intent_checkpoints SET answers = '{\"x\":\"y\"}' WHERE id = #{settled.id}"
      )
    }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "still allows superseding a pending checkpoint" do  # @spec PROJECT-DELEGATION-002
    checkpoint = create(:intent_checkpoint, account:, project:, issue:, groups: [ group ])

    checkpoint.update!(status: "superseded")

    expect(checkpoint.reload.status).to eq("superseded")
  end

  describe "coverage and answers" do
    it "finds the group covering a question and returns its settled answer" do  # @spec PROJECT-DELEGATION-002
      checkpoint = create(:intent_checkpoint, :settled, account:, project:, issue:, groups: [ group ],
        answers: { "retention-policy" => "30 days" })

      expect(checkpoint).to be_covers_question("How long must imported metrics be retained?")
      expect(checkpoint.answer_for("retention-policy")).to eq("30 days")
      expect(checkpoint).not_to be_covers_question("An unrelated question?")
    end
  end
end
