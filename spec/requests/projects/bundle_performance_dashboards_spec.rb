# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::BundlePerformanceDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/bundle_performance_dashboard" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get project_bundle_performance_dashboard_path(project)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the dashboard empty state when no bundle data exists" do
        get project_bundle_performance_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Bundle Performance Analysis")
        expect(response.body).to include("No bundle outcomes or active optimizer experiments are available yet")
      end

      it "renders bundle, confidence, and tradeoff sections when data exists" do
        bundle = create_bundle_analysis_data(project: project, account: account)

        get project_bundle_performance_dashboard_path(project)

        expect(response.body).to include("Bundle Performance")
        expect(response.body).to include("Experiment Confidence")
        expect(response.body).to include("Outcome-Cost Tradeoffs")
        expect(response.body).to include("Optimizer Candidate Signals")
        expect(response.body).to include(bundle.name)
        expect(response.body).to include("knowledge.token_budget=8000")
      end
    end
  end

  def create_outcome(project:, bundle:, quality_score:, cost_cents:)
    run = create(:agent_run,
      :completed,
      project: project,
      issue: create(:issue, project: project),
      goal: "create_pr",
      configuration_bundle: bundle,
      cost_cents: cost_cents)

    create(:bundle_outcome,
      configuration_bundle: bundle,
      agent_run: run,
      quality_score: quality_score,
      cost_cents: cost_cents,
      success: true)
  end

  def create_bundle_analysis_data(project:, account:)
    experiment = create(:configuration_experiment,
      account: account,
      status: "running",
      min_samples_per_variant: 2)
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: experiment.control_value,
      is_control: true,
      sample_count: 2,
      avg_quality_score: 0.6)
    challenger = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000),
      sample_count: 2,
      avg_quality_score: 0.8)

    bundle = create(:configuration_bundle,
      account: account,
      definition: bundle_definition(experiment: experiment, variant: challenger))
    create_outcome(project:, bundle:, quality_score: 0.9, cost_cents: 40)
    create_outcome(project:, bundle:, quality_score: 0.8, cost_cents: 50)
    create_outcome(project:, bundle:, quality_score: 0.85, cost_cents: 45)
    bundle
  end

  def bundle_definition(experiment:, variant:)
    {
      "schema_version" => 1,
      "goal" => "create_pr",
      "agent_type" => "claude_code",
      "experiments" => {
        experiment.config_key => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => 8000
        }
      }
    }
  end
end
