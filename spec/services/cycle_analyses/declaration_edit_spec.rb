# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-023
RSpec.describe CycleAnalyses::DeclarationEdit do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user, owner: "acme", repo: "widgets") }
  let(:other_project) { create(:project, account: user.account, created_by: user, owner: "acme", repo: "gadgets") }
  let(:declaring_issue) { create(:issue, project:, github_number: 10) }
  let(:target_issue) { create(:issue, project:, github_number: 20) }

  describe ".remove" do
    it "deletes a bare reference's own isolated line and preserves the rest of the body" do
      body = "Intro line.\n\n## Dependencies\n- #20\n- #30\n\nTrailer."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:)

      expect(outcome.status).to eq(:applied)
      expect(outcome.body).to eq("Intro line.\n\n## Dependencies\n- #30\n\nTrailer.")
    end

    it "deletes a qualified cross-project reference's isolated line" do
      cross_target = create(:issue, project: other_project, github_number: 5)
      body = "Depends on acme/gadgets#5\nUnrelated line."

      outcome = described_class.remove(body:, declaring_issue:, target_issue: cross_target)

      expect(outcome.status).to eq(:applied)
      expect(outcome.body).to eq("Unrelated line.")
    end

    it "is idempotent when the reference is already absent" do
      body = "Nothing to see here."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:)

      expect(outcome.status).to eq(:already_satisfied)
      expect(outcome.body).to eq(body)
    end

    it "refuses to remove a reference sharing its line with another declaration" do
      body = "Depends on #20 and #30 for setup."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:)

      expect(outcome.status).to eq(:ambiguous)
      expect(outcome.body).to eq(body)
    end

    it "refuses to remove a reference that appears on more than one line" do
      body = "Depends on #20.\n\nAlso see #20 for context."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:)

      expect(outcome.status).to eq(:ambiguous)
    end

    it "does not treat a bare number belonging to another project as a match" do
      other_target = create(:issue, project: other_project, github_number: 20)
      body = "Depends on #20."

      outcome = described_class.remove(body:, declaring_issue:, target_issue: other_target)

      expect(outcome.status).to eq(:already_satisfied)
    end

    it "does not confuse a bare number with the suffix of a different qualified reference" do
      body = "Depends on acme/gadgets#20."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:)

      expect(outcome.status).to eq(:already_satisfied)
    end

    # An unprovenanced edge has no record the declaration was ever live, so
    # an absent reference cannot be assumed to mean "already edited" the way
    # it can for a known-provenance retry (AUTO-PICK-QUEUE-022).
    it "reports unresolved rather than already satisfied when require_match is set and the reference is absent" do
      body = "Nothing to see here."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:, require_match: true)

      expect(outcome.status).to eq(:unresolved)
      expect(outcome).not_to be_resolved
      expect(outcome.body).to eq(body)
    end

    it "still applies a require_match removal when the reference resolves uniquely" do
      body = "Depends on #20."

      outcome = described_class.remove(body:, declaring_issue:, target_issue:, require_match: true)

      expect(outcome).to be_applied
      expect(outcome).to be_resolved
    end
  end

  describe ".correct" do
    it "replaces only the reference token, preserving surrounding line text" do
      replacement_issue = create(:issue, project:, github_number: 99)
      body = "- Depends on #20 for setup\n- #30"

      outcome = described_class.correct(body:, declaring_issue:, target_issue:, replacement_issue:)

      expect(outcome.status).to eq(:applied)
      expect(outcome.body).to eq("- Depends on #99 for setup\n- #30")
    end

    it "qualifies the replacement reference when it points at a different project" do
      replacement_issue = create(:issue, project: other_project, github_number: 7)
      body = "Depends on #20."

      outcome = described_class.correct(body:, declaring_issue:, target_issue:, replacement_issue:)

      expect(outcome.body).to eq("Depends on acme/gadgets#7.")
    end
  end
end
