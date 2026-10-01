# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project::UpstreamAutomation do
  # @spec UPSTREAM-GATE-001 UPSTREAM-GATE-002 UPSTREAM-GATE-003 UPSTREAM-GATE-004 UPSTREAM-GATE-006
  describe "#upstream_pr_target?" do
    it "is false for the default own_repo target" do
      expect(create(:project).upstream_pr_target?).to be false
    end

    it "is false when pr_target is upstream but no upstream repository is configured" do
      project = build(:project, pr_target: "upstream", upstream_full_name: nil)
      expect(project.upstream_pr_target?).to be false
    end

    it "is true when pr_target is upstream and the upstream repository is configured" do
      expect(create(:project, :upstream_pr_target).upstream_pr_target?).to be true
    end
  end

  # @spec UPSTREAM-GATE-001
  describe "#upstream_automation_allowed? / #upstream_mode_skips?" do
    it "allows every feature on own_repo projects" do
      project = create(:project)
      described_class::DISABLED_FEATURES.each do |feature|
        expect(project.upstream_automation_allowed?(feature)).to be true
        expect(project.upstream_mode_skips?(feature)).to be false
      end
    end

    it "disables exactly the canonical disable set in upstream mode" do
      project = create(:project, :upstream_pr_target)
      described_class::DISABLED_FEATURES.each do |feature|
        expect(project.upstream_automation_allowed?(feature)).to be false
        expect(project.upstream_mode_skips?(feature)).to be true
      end
    end

    it "leaves unknown features alone" do
      project = create(:project, :upstream_pr_target)
      expect(project.upstream_automation_allowed?(:auto_pick)).to be true
      expect(project.upstream_automation_allowed?("auto_scan_security")).to be true
    end
  end

  # @spec UPSTREAM-GATE-003
  describe "#upstream_feature_enabled? / #log_upstream_mode_skipped" do
    it "logs upstream_mode_skipped once per feature regardless of how often consulted" do
      project = create(:project, :upstream_pr_target)
      allow(Rails.logger).to receive(:info)

      expect(project.upstream_feature_enabled?(:auto_merge)).to be false
      expect(project.upstream_feature_enabled?(:auto_merge)).to be false
      expect(project.upstream_mode_skips?(:auto_merge)).to be true

      expect(Rails.logger).to have_received(:info).once
      expect(Rails.logger).to have_received(:info).with(
        message: "upstream_mode_skipped",
        project_id: project.id,
        feature: "auto_merge"
      )
    end

    it "does not log for own_repo projects" do
      project = create(:project)
      allow(Rails.logger).to receive(:info)

      expect(project.upstream_feature_enabled?(:auto_merge)).to be true

      expect(Rails.logger).not_to have_received(:info)
    end
  end

  # @spec UPSTREAM-GATE-004
  describe "save-time hard gating" do
    it "rejects pr_target values outside the vocabulary" do
      project = build(:project, pr_target: "elsewhere")
      expect(project).not_to be_valid
      expect(project.errors[:pr_target]).to be_present
    end

    it "requires the upstream repository when pr_target is upstream" do
      project = build(:project, pr_target: "upstream")
      expect(project).not_to be_valid
      expect(project.errors[:upstream_full_name]).to be_present
    end

    it "atomically clears default-true gated features when transitioning to upstream mode" do
      project = create(:project)
      project.pr_target = "upstream"
      project.upstream_full_name = "upstream-owner/upstream-repo"

      expect(project).to be_valid
      expect(project.auto_add_labels_enabled).to be false
      expect(project.inherit_priority_labels).to be false

      project.save!
      project.reload
      expect(project.pr_target).to eq("upstream")
      expect(project.auto_add_labels_enabled).to be false
      expect(project.inherit_priority_labels).to be false
    end

    it "leaves already-disabled settings alone during the upstream-mode transition" do
      project = create(:project, auto_merge_mode: "off", allow_bot_authored_pr_auto_merge: false)
      project.pr_target = "upstream"
      project.upstream_full_name = "upstream-owner/upstream-repo"

      expect(project).to be_valid
      expect(project.auto_merge_mode).to eq("off")
      expect(project.allow_bot_authored_pr_auto_merge).to be false
    end

    it "does not touch gated settings when updating an already-upstream project" do
      project = create(:project, :upstream_pr_target)
      project.update!(name: "Renamed")

      project.name = "Renamed again"
      expect(project).to be_valid
      expect(project.auto_add_labels_enabled).to be false
      expect(project.inherit_priority_labels).to be false
    end

    it "rejects each gated feature individually while upstream mode is active" do
      [
        [ :auto_merge_mode, "all", :auto_merge_mode ],
        [ :allow_bot_authored_pr_auto_merge, true, :allow_bot_authored_pr_auto_merge ],
        [ :auto_release_granularity, "patch_only", :auto_release_granularity ],
        [ :auto_add_labels_enabled, true, :auto_add_labels_enabled ],
        [ :inherit_priority_labels, true, :inherit_priority_labels ],
        [ :owner_reviewer_login, "viamin", :owner_reviewer_login ]
      ].each do |(attribute, value, error_attribute)|
        project = create(:project, :upstream_pr_target)
        project.public_send("#{attribute}=", value)
        expect(project).not_to be_valid,
          "expected #{attribute} = #{value.inspect} to be rejected in upstream mode"
        expect(project.errors[error_attribute]).to be_present
      end
    end

    it "rejects a real change of a default-true gated attribute to true in upstream mode" do
      # The factory pre-disables auto_add_labels_enabled/inherit_priority_labels
      # for upstream projects. The earlier "rejects each gated feature
      # individually" case already exercises the false→true transition. This
      # case documents the true→false→true round-trip so an explicit setter
      # cycle cannot smuggle an enabled value past the validation.
      project = create(:project, :upstream_pr_target)
      project.auto_add_labels_enabled = true
      project.auto_add_labels_enabled = false
      project.auto_add_labels_enabled = true

      expect(project).not_to be_valid
      expect(project.errors[:auto_add_labels_enabled]).to be_present
    end

    it "rejects enabling review settings while upstream mode is active" do
      project = create(:project, :upstream_pr_target)
      project.review_settings = { "enabled" => true, "methods" => { "copilot" => { "enabled" => true } } }

      expect(project).not_to be_valid
      expect(project.errors[:review_settings]).to be_present
    end

    it "rejects review method sub-flags even when the top-level review toggle is off" do
      project = create(:project, :upstream_pr_target)
      project.review_settings = { "enabled" => false, "methods" => { "codex" => { "enabled" => true } } }

      expect(project).not_to be_valid
      expect(project.errors[:review_settings]).to be_present
    end

    it "rejects enabling screenshot capture while upstream mode is active" do
      project = create(:project, :upstream_pr_target)
      project.screenshot_settings = { "enabled" => true }

      expect(project).not_to be_valid
      expect(project.errors[:screenshot_settings]).to be_present
    end

    it "still saves gated features in their disabled values while upstream mode is active" do
      project = create(:project, :upstream_pr_target)
      project.auto_merge_mode = "off"
      project.owner_reviewer_login = nil
      expect(project).to be_valid
    end

    it "restores normal behavior when switching back to own_repo" do
      project = create(:project, :upstream_pr_target)
      project.update!(pr_target: "own_repo", auto_merge_mode: "all", auto_add_labels_enabled: true)

      expect(project.reload.auto_merge_mode).to eq("all")
      expect(project.auto_merge_enabled?).to be true
      expect(project.auto_add_labels_enabled?).to be true
    end
  end

  # @spec UPSTREAM-GATE-002
  describe "gated feature predicates" do
    let!(:upstream_project) { create(:project, :upstream_pr_target) }

    it "disables every review predicate" do
      expect(upstream_project.review_enabled?).to be false
      expect(upstream_project.review_bot_request_login).to be_nil
      expect(upstream_project.review_bot_request_chain).to eq([])
    end

    it "does not expose configured review bots from legacy upstream settings" do
      upstream_project.update_columns(review_settings: {
        "enabled" => true,
        "methods" => { "copilot" => { "enabled" => true } }
      })
      upstream_project.reload

      expect(upstream_project.review_enabled?).to be false
      expect(upstream_project.review_bot_request_login).to be_nil
      expect(upstream_project.review_bot_request_chain).to eq([])
    end

    it "disables auto-merge predicates even with a stored mode" do
      upstream_project.update_columns(auto_merge_mode: "all", allow_bot_authored_pr_auto_merge: true)
      upstream_project.reload

      expect(upstream_project.auto_merge_enabled?).to be false
      expect(upstream_project.auto_merge_dependabot?).to be false
      expect(upstream_project.auto_merge_bot_authored?).to be false
    end

    it "disables auto-release" do
      upstream_project.update_columns(auto_release_granularity: "all")
      upstream_project.reload

      expect(upstream_project.auto_release_enabled?).to be false
    end

    it "disables PR labeling while the raw issue-labeling column stays authoritative" do
      expect(upstream_project.pr_auto_labels_enabled?).to be false
      expect(upstream_project.inherit_priority_labels?).to be false

      # auto_add_labels_enabled? is deliberately NOT overridden — it keeps
      # reporting the raw column because issue labeling (in the fork) stays
      # supported; only the PR-side combination is gated.
      upstream_project.update_columns(auto_add_labels_enabled: true)
      upstream_project.reload
      expect(upstream_project.auto_add_labels_enabled?).to be true
      expect(upstream_project.pr_auto_labels_enabled?).to be false
    end

    it "keeps merge-conflict fixing enabled" do
      upstream_project.update!(auto_fix_merge_conflicts: true)

      expect(upstream_project.auto_fix_merge_conflicts?).to be true
    end

    it "disables screenshots" do
      expect(upstream_project.screenshots_enabled?).to be false
    end
  end

  # @spec UPSTREAM-GATE-005
  describe "#upstream_gated_setting_violations" do
    it "returns the gated settings an attrs hash would enable" do
      project = create(:project, :upstream_pr_target)

      violations = project.upstream_gated_setting_violations({
        auto_merge_mode: "all",
        auto_release_granularity: "off",
        owner_reviewer_login: "viamin",
        auto_add_labels_enabled: false
      })

      expect(violations).to contain_exactly("auto_merge_mode", "owner_reviewer_login")
    end

    it "flags review and screenshot setting hashes that enable automation" do
      project = create(:project, :upstream_pr_target)

      expect(project.upstream_gated_setting_violations(review_settings: { "enabled" => true }))
        .to eq([ "review_settings" ])
      expect(project.upstream_gated_setting_violations(screenshot_settings: { "enabled" => true }))
        .to eq([ "screenshot_settings" ])
    end

    it "returns nothing for own_repo projects" do
      project = create(:project)

      expect(project.upstream_gated_setting_violations(auto_merge_mode: "all")).to eq([])
    end
  end
end
