# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::BuildRecommendations do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    context "when commit_style detection has high confidence" do
      let(:project_version) { create(:project_version, project: project) }

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits", "required" => true },
               evidence: { "paths" => [ ".commitlintrc.json" ], "signals" => [ "commitlint" ] },
               confidence: 0.95)
      end

      it "creates a recommendation" do
        described_class.call(project: project)
        rec = project.project_convention_recommendations.pending.first
        expect(rec).to be_present
        expect(rec.convention_key).to eq("commit_style")
        expect(rec.action_type).to eq("apply_in_paid")
        expect(rec.title).to include("conventional commit")
      end

      it "includes evidence in the recommendation description" do
        described_class.call(project: project)
        rec = project.project_convention_recommendations.pending.first
        expect(rec.description).to include(".commitlintrc.json")
      end
    end

    context "when hook_manager detection has high confidence" do
      let(:project_version) { create(:project_version, project: project) }

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "hook_manager",
               value: { "type" => "husky", "path" => ".husky" },
               evidence: { "paths" => [ ".husky/pre-commit" ], "signals" => [ "husky" ] },
               confidence: 0.90)
      end

      it "creates a hook manager recommendation" do
        described_class.call(project: project)
        rec = project.project_convention_recommendations.pending.first
        expect(rec).to be_present
        expect(rec.convention_key).to eq("hook_manager")
        expect(rec.action_type).to eq("open_pr")
      end
    end

    context "when no conventions are detected" do
      it "does not create any recommendations" do
        described_class.call(project: project)
        expect(project.project_convention_recommendations).to be_empty
      end
    end

    context "when detection confidence is low" do
      let(:project_version) { create(:project_version, project: project) }

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               confidence: 0.3)
      end

      it "does not create recommendations below the threshold" do
        described_class.call(project: project)
        expect(project.project_convention_recommendations).to be_empty
      end
    end

    context "when recommendation already exists" do
      let(:project_version) { create(:project_version, project: project) }

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits", "required" => true },
               evidence: { "paths" => [ "commitlint.config.js" ], "signals" => [ "commitlint" ] },
               confidence: 0.95)
        described_class.call(project: project)
      end

      it "updates existing recommendation instead of duplicating" do
        expect {
          described_class.call(project: project)
        }.not_to change { project.project_convention_recommendations.pending.count }

        rec = project.project_convention_recommendations.pending.first
        expect(rec.title).to include("conventional commit")
      end
    end

    context "when recommendation was previously dismissed" do
      let(:project_version) { create(:project_version, project: project) }
      let!(:recommendation) do
        create(:project_convention_recommendation,
               project: project,
               convention_key: "commit_style",
               action_type: "apply_in_paid",
               status: "dismissed",
               dismissal_reason: "Not needed")
      end

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits", "required" => true },
               evidence: { "paths" => [ ".commitlintrc.json" ], "signals" => [ "commitlint" ] },
               confidence: 0.95)
      end

      it "preserves the resolved row instead of recreating a pending recommendation" do
        expect {
          described_class.call(project: project)
        }.not_to change { project.project_convention_recommendations.count }

        expect(recommendation.reload).to be_dismissed
        expect(project.project_convention_recommendations.pending).to be_empty
        expect(recommendation.description).to include(".commitlintrc.json")
      end
    end

    context "when recommendation was previously applied" do
      let(:project_version) { create(:project_version, project: project) }
      let!(:recommendation) do
        create(:project_convention_recommendation,
               project: project,
               convention_key: "commit_style",
               action_type: "apply_in_paid",
               status: "applied")
      end

      before do
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits", "required" => true },
               evidence: { "paths" => [ "commitlint.config.js" ], "signals" => [ "commitlint" ] },
               confidence: 0.95)
      end

      it "updates the existing applied row instead of generating a new pending recommendation" do
        expect {
          described_class.call(project: project)
        }.not_to change { project.project_convention_recommendations.count }

        expect(recommendation.reload).to be_applied
        expect(project.project_convention_recommendations.pending).to be_empty
        expect(recommendation.description).to include("commitlint.config.js")
      end
    end

    context "when convention is no longer detected" do
      let(:project_version) { create(:project_version, project: project) }

      before do
        create(:project_convention_recommendation,
               project: project,
               convention_key: "commit_style",
               action_type: "apply_in_paid",
               title: "Enable conventional commits",
               description: "Old desc")
      end

      it "dismisses stale recommendations" do
        described_class.call(project: project)
        rec = project.project_convention_recommendations.first
        expect(rec.status).to eq("dismissed")
        expect(rec.dismissal_reason).to include("no longer detected")
      end
    end
  end
end
