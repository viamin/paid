# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::TriggerDevEnvironmentUpdateActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:project) { create(:project, owner: "paid-ai", repo: "paid", account: account) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(Process).to receive(:spawn).and_return(12345)
    allow(Process).to receive(:detach)
  end

  def stub_repo_full_name(value)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PAID_REPO_FULL_NAME").and_return(value)
  end

  describe "#execute" do
    context "when project is not the self-repo" do
      before do
        stub_repo_full_name("other-org/other-repo")
      end

      it "returns not_self_repo without fetching files" do
        expect(github_client).not_to receive(:pull_request_files)

        result = activity.execute(project_id: project.id, pr_number: 42)

        expect(result).to eq(triggered: false, reason: "not_self_repo")
      end
    end

    context "when PAID_REPO_FULL_NAME is not set" do
      before do
        stub_repo_full_name(nil)
      end

      it "returns not_self_repo" do
        result = activity.execute(project_id: project.id, pr_number: 42)

        expect(result).to eq(triggered: false, reason: "not_self_repo")
      end
    end

    context "when project is the self-repo" do
      before do
        stub_repo_full_name("paid-ai/paid")
      end

      context "when only app code changed (lightweight)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[app/models/user.rb app/controllers/projects_controller.rb])
        end

        it "triggers a lightweight update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "lightweight")
        end

        it "spawns the dev-update script with --lightweight" do
          activity.execute(project_id: project.id, pr_number: 42)

          expect(Process).to have_received(:spawn).with(
            expected_spawn_env(
              mode: "lightweight",
              changed_files: "app/models/user.rb\napp/controllers/projects_controller.rb",
              restart_trigger_files: "",
              project_id: project.id
            ),
            "setsid", /bin\/dev-update/, "--lightweight",
            hash_including(out: [ dev_update_log_path, "a" ], err: [ dev_update_log_path, "a" ])
          )
          expect(Process).to have_received(:detach).with(12345)
        end
      end

      context "when Temporal code changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[app/temporal/activities/new_activity.rb app/models/user.rb])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end

        it "spawns the dev-update script with --full" do
          activity.execute(project_id: project.id, pr_number: 42)

          expect(Process).to have_received(:spawn).with(
            expected_spawn_env(
              mode: "full",
              changed_files: "app/temporal/activities/new_activity.rb\napp/models/user.rb",
              restart_trigger_files: "app/temporal/activities/new_activity.rb",
              project_id: project.id
            ),
            "setsid", /bin\/dev-update/, "--full",
            hash_including(out: [ dev_update_log_path, "a" ], err: [ dev_update_log_path, "a" ])
          )
        end
      end

      context "when config changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[config/initializers/temporal.rb])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when migrations changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[db/migrate/20260101000000_add_column.rb])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when Gemfile changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[Gemfile Gemfile.lock])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when bin/ scripts changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[bin/setup])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when Procfile changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[Procfile.dev])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when package-lock.json changed (full restart)" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[package-lock.json])
        end

        it "triggers a full update" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true, mode: "full")
        end
      end

      context "when spawn fails" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[app/models/user.rb])
          allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, "setsid")
        end

        it "returns spawn_failed without raising" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to eq(triggered: false, reason: "spawn_failed")
        end
      end

      context "when fetching files fails" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .and_raise(GithubClient::ApiError.new("Not found", status: 404))
        end

        it "returns no_changed_files without raising" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to eq(triggered: false, reason: "no_changed_files")
        end
      end

      context "when no files changed" do
        before do
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return([])
        end

        it "returns no_changed_files" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to eq(triggered: false, reason: "no_changed_files")
        end
      end

      context "with case-insensitive repo matching" do
        let(:project) { create(:project, owner: "Paid-AI", repo: "PAID", account: account) }

        before do
          allow(github_client).to receive(:pull_request_files)
            .with("Paid-AI/PAID", 42)
            .and_return(%w[app/models/user.rb])
        end

        it "matches regardless of case" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true)
        end
      end

      context "when self_repo_full_name is set in TenantSetting" do
        let(:setting) { account.tenant_setting! }

        before do
          setting.update!(self_repo_full_name: "paid-ai/paid")
          stub_repo_full_name(nil)
          allow(github_client).to receive(:pull_request_files)
            .with("paid-ai/paid", 42)
            .and_return(%w[app/models/user.rb])
        end

        it "uses TenantSetting value instead of ENV" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to include(triggered: true)
        end
      end

      context "when TenantSetting self_repo_full_name does not match" do
        let(:setting) { account.tenant_setting! }

        before do
          setting.update!(self_repo_full_name: "other-org/other-repo")
          stub_repo_full_name(nil)
        end

        it "returns not_self_repo" do
          result = activity.execute(project_id: project.id, pr_number: 42)

          expect(result).to eq(triggered: false, reason: "not_self_repo")
        end
      end
    end
  end

  def dev_update_log_path
    Rails.root.join("log", "dev-update", "dev-update.log").to_s
  end

  def expected_spawn_env(mode:, changed_files:, restart_trigger_files:, project_id:)
    hash_including(
      "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLER_SETUP" => nil,
      "BUNDLER_VERSION" => nil,
      "DEV_UPDATE_TRIGGER_SOURCE" => "Activities::TriggerDevEnvironmentUpdateActivity",
      "DEV_UPDATE_TRIGGER_MODE" => mode,
      "DEV_UPDATE_PROJECT_ID" => project_id.to_s,
      "DEV_UPDATE_PR_NUMBER" => "42",
      "DEV_UPDATE_CHANGED_FILES" => changed_files,
      "DEV_UPDATE_RESTART_TRIGGER_FILES" => restart_trigger_files,
      "RUBYGEMS_GEMDEPS" => nil,
      "RUBYLIB" => nil,
      "RUBYOPT" => nil
    )
  end
end
