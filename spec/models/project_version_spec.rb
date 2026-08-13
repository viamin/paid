# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectVersion do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:collector_runs).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:project_version) }

    it { is_expected.to validate_presence_of(:commit_sha) }
    it { is_expected.to validate_length_of(:commit_sha).is_at_most(40) }
    it { is_expected.to validate_length_of(:parent_sha).is_at_most(40) }
    it { is_expected.to validate_presence_of(:branch) }

    it "enforces uniqueness of commit_sha per project at the database level" do
      existing = create(:project_version)
      duplicate = build(:project_version, project: existing.project, commit_sha: existing.commit_sha)
      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "scopes" do
    describe ".for_project" do
      it "returns versions for the given project" do
        project = create(:project)
        version = create(:project_version, project: project)
        create(:project_version) # different project

        expect(described_class.for_project(project)).to eq([ version ])
      end
    end
  end
end
