# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::DesignArtifactReconciliationSweepJob do
  it "schedules repository RDR discovery even without an existing design pull request" do
    project = create(:project)
    allow(FeatureIntents::ReconcileDesignArtifactsJob).to receive(:perform_later)

    described_class.perform_now

    expect(FeatureIntents::ReconcileDesignArtifactsJob).to have_received(:perform_later).with(project.id)
  end

  it "schedules a project scan that includes its tracked open design pull requests" do
    project = create(:project)
    create(:feature_intent_design_pr, feature_intent: create(:feature_intent, project:))
    allow(FeatureIntents::ReconcileDesignArtifactsJob).to receive(:perform_later)

    described_class.perform_now

    expect(FeatureIntents::ReconcileDesignArtifactsJob).to have_received(:perform_later).with(project.id)
  end
end
