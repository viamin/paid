# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ScalingDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/scaling_dashboard" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get project_scaling_dashboard_path(project)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders an empty state when no scaling data exists" do
        get project_scaling_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Scaling Experiments")
        expect(response.body).to include("No scaling observations or experiments have been recorded yet")
      end

      it "renders recommendations and simplifications when summaries exist" do
        experiment = create(:scaling_experiment, project: project, name: "Parallelism Scaling", status: "completed")
        experiment.update!(cached_summary: cached_summary_payload)
        create(:scaling_observation, project: project)

        get project_scaling_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Allocator Recommendations")
        expect(response.body).to include("Parallelism Scaling")
        expect(response.body).to include("Below 30-sample RDR target")
        expect(response.body).to include("Intentional Simplifications")
      end
    end
  end

  def cached_summary_payload
    {
      "dimension" => "parallelism",
      "primary_metric" => "success_rate",
      "sample_count" => 6,
      "leading_value" => 2,
      "sample_threshold_review" => {
        "configured_min_samples_per_value" => 2,
        "analysis_min_samples_per_value" => 2,
        "rdr_target_min_samples_per_value" => 30,
        "meets_rdr_target" => false
      },
      "simplifications" => [ "Uses descriptive confidence intervals." ],
      "allocator_decision" => {
        "recommended_value" => 2,
        "sample_count" => 6,
        "confidence" => "medium",
        "actionable" => false,
        "reason" => "lowest_risk_viable_parallelism",
        "efficiency_gain_vs_control" => 0.12,
        "scaling_exponent" => 0.4,
        "scaling_exponent_confidence_interval" => {
          "estimate" => 0.4,
          "lower_bound" => 0.2,
          "upper_bound" => 0.6,
          "margin_of_error" => 0.2,
          "sample_count" => 6,
          "confidence_level" => 0.95
        }
      },
      "values" => [
        {
          "assigned_value" => 2,
          "sample_count" => 6,
          "success_rate_confidence_interval" => {
            "mean" => 0.9,
            "lower_bound" => 0.75,
            "upper_bound" => 0.98,
            "margin_of_error" => 0.08,
            "sample_count" => 6,
            "confidence_level" => 0.95
          },
          "primary_metric_confidence_interval" => {
            "mean" => 0.9,
            "lower_bound" => 0.75,
            "upper_bound" => 0.98,
            "margin_of_error" => 0.08,
            "sample_count" => 6,
            "confidence_level" => 0.95
          },
          "avg_duration_seconds_confidence_interval" => {
            "mean" => 180.0,
            "lower_bound" => 170.0,
            "upper_bound" => 190.0,
            "margin_of_error" => 10.0,
            "sample_count" => 6,
            "confidence_level" => 0.95
          },
          "signals" => [ "diminishing_returns" ]
        }
      ]
    }
  end
end
