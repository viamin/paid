# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::TriggerDevEnvironmentUpdateActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, owner: "paid-ai", repo: "paid") }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(Process).to receive(:spawn).and_return(12345)
    allow(Process).to receive(:detach)
  end

  describe "#execute" do
    context "when project is not the self-repo" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("PAID_REPO_FULL_NAME").and_return("other-org/other-repo")
      end

      it "returns not_self_repo without fetching files" do
        result = activity.execute(project_id: project.id, pr_number: 42)

        expect(result).to eq(triggered: false, reason: "not_self_repo")
        expect(github_client).not_to have_received(:pull_request_files) if github_client.respond_to?(:pull_request_files)
      end
    end

    context "when PAID_REPO_FULL_NAME is not set" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("PAID_REPO_FULL_NAME").and_return(nil)
      end

      it "returns not_self_repo" do
        result = activity.execute(project_id: project.id, pr_number: 42)

        expect(result).to eq(triggered: false, reason: "not_self_repo")
      end
    end

    context "when project is the self-repo" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("PAID_REPO_FULL_NAME").and_return("paid-ai/paid")
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
            /bin\/dev-update --lightweight/,
            hash_including(out: "/dev/null", err: "/dev/null", pgroup: true)
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
            /bin\/dev-update --full/,
            hash_including(out: "/dev/null", err: "/dev/null", pgroup: true)
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
        let(:project) { create(:project, owner: "Paid-AI", repo: "PAID") }

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
    end
  end
end
