# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueDependency do
  describe "associations" do
    it { is_expected.to belong_to(:issue) }
    it { is_expected.to belong_to(:depends_on_issue).class_name("Issue") }
  end

  describe "validations" do
    subject { build(:issue_dependency) }

    it { is_expected.to validate_uniqueness_of(:depends_on_issue_id).scoped_to(:issue_id) }

    it "rejects self-referential dependencies" do
      issue = create(:issue)
      dep = build(:issue_dependency, issue: issue, depends_on_issue: issue)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include("cannot be the same as the issue")
    end

    it "rejects dependencies across projects" do
      issue = create(:issue)
      other_issue = create(:issue)

      dep = build(:issue_dependency, issue: issue, depends_on_issue: other_issue)

      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_issue]).to include("must belong to the same project")
    end

    it "allows dependencies within the same project" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)

      dep = build(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect(dep).to be_valid
    end
  end

  describe "cascade deletion" do
    it "is destroyed when the dependent issue is destroyed" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect { issue_a.destroy }.to change(described_class, :count).by(-1)
    end

    it "is destroyed when the dependency issue is destroyed" do
      project = create(:project)
      issue_a = create(:issue, project: project)
      issue_b = create(:issue, project: project)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)

      expect { issue_b.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
