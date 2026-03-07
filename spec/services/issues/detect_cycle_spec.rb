# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::DetectCycle do
  let(:project) { create(:project) }

  describe ".call" do
    it "returns false when there is no cycle" do
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      result = described_class.call(from_issue: issue_b, target_issue_id: issue_a.id)

      expect(result).to be false
    end

    it "returns true when adding the edge would create a direct cycle" do
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      result = described_class.call(from_issue: issue_a, target_issue_id: issue_b.id)

      expect(result).to be true
    end

    it "returns true when adding the edge would create an indirect cycle" do
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      issue_c = create(:issue, project: project)

      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_c)

      result = described_class.call(from_issue: issue_a, target_issue_id: issue_c.id)

      expect(result).to be true
    end

    it "returns false for unrelated issues" do
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      issue_c = create(:issue, project: project)

      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      result = described_class.call(from_issue: issue_c, target_issue_id: issue_a.id)

      expect(result).to be false
    end

    it "handles diamond-shaped graphs without false positives" do
      #   A
      #  / \
      # B   C
      #  \ /
      #   D
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      issue_c = create(:issue, project: project)
      issue_d = create(:issue, project: project)

      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_c)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_d)
      create(:issue_dependency, issue: issue_c, depends_on_issue: issue_d)

      result = described_class.call(from_issue: issue_d, target_issue_id: issue_a.id)

      expect(result).to be false
    end
  end
end
