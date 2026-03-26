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
    it { is_expected.to validate_uniqueness_of(:commit_sha).scoped_to(:project_id) }
    it { is_expected.to validate_length_of(:parent_sha).is_at_most(40) }
    it { is_expected.to validate_presence_of(:branch) }
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
