# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolvePrReviewPlanActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "returns the legacy copilot review plan when review settings are unset" do
      project = create(:project, review_settings: {})

      result = activity.execute(project_id: project.id)

      expect(result).to eq(
        review_enabled: false,
        wait_for_reviews: true,
        requested_review_methods: [ "copilot" ],
        blocking_review_methods: [ "copilot" ],
        ci_review_action_names: []
      )
    end

    it "returns no review methods when reviews are explicitly disabled" do
      project = create(:project, review_settings: {
        "enabled" => false,
        "methods" => {
          "copilot" => { "enabled" => true },
          "paid_agent" => { "enabled" => true }
        }
      })

      result = activity.execute(project_id: project.id)

      expect(result).to eq(
        review_enabled: false,
        wait_for_reviews: true,
        requested_review_methods: [],
        blocking_review_methods: [],
        ci_review_action_names: []
      )
    end

    it "returns configured requested, blocking, and ci review plan details" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "wait_for_reviews" => true,
        "methods" => {
          "paid_agent" => { "enabled" => true },
          "manual" => { "enabled" => true },
          "ci_action" => { "enabled" => true, "action_name" => "codex-review" }
        }
      })

      result = activity.execute(project_id: project.id)

      expect(result).to eq(
        review_enabled: true,
        wait_for_reviews: true,
        requested_review_methods: [ "paid_agent" ],
        blocking_review_methods: [ "paid_agent", "ci_action", "manual" ],
        ci_review_action_names: [ "codex-review" ]
      )
    end

    it "drops blocking review methods when wait_for_reviews is disabled" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "wait_for_reviews" => false,
        "methods" => {
          "paid_agent" => { "enabled" => true },
          "manual" => { "enabled" => true }
        }
      })

      result = activity.execute(project_id: project.id)

      expect(result).to eq(
        review_enabled: true,
        wait_for_reviews: false,
        requested_review_methods: [ "paid_agent" ],
        blocking_review_methods: [],
        ci_review_action_names: []
      )
    end
  end
end
