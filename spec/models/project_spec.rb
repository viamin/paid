# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:github_token) }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
    it { is_expected.to have_many(:project_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:members).through(:project_memberships).source(:user) }
    it { is_expected.to have_many(:issues).dependent(:destroy) }
    it { is_expected.to have_many(:agent_runs).dependent(:destroy) }
    it { is_expected.to have_many(:workflow_states).dependent(:destroy) }
    it { is_expected.to have_many(:code_chunks).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:project) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:owner) }
    it { is_expected.to validate_presence_of(:repo) }
    it { is_expected.to validate_presence_of(:github_id) }
    it { is_expected.to validate_uniqueness_of(:github_id).scoped_to(:account_id) }
    it { is_expected.to validate_numericality_of(:poll_interval_seconds).is_greater_than_or_equal_to(60) }

    describe "github_token account validation" do
      it "allows github_token from the same account" do
        account = create(:account)
        github_token = create(:github_token, account: account)
        project = build(:project, account: account, github_token: github_token)

        expect(project).to be_valid
      end

      it "rejects github_token from a different account" do
        account = create(:account)
        other_account = create(:account)
        github_token = create(:github_token, account: other_account)
        project = build(:project, account: account, github_token: github_token)

        expect(project).not_to be_valid
        expect(project.errors[:github_token]).to include("must belong to the same account")
      end
    end

    describe "created_by account validation" do
      it "allows created_by from the same account" do
        account = create(:account)
        user = create(:user, account: account)
        project = build(:project, account: account, created_by: user)

        expect(project).to be_valid
      end

      it "rejects created_by from a different account" do
        account = create(:account)
        other_account = create(:account)
        user = create(:user, account: other_account)
        project = build(:project, account: account, created_by: user)

        expect(project).not_to be_valid
        expect(project.errors[:created_by]).to include("must belong to the same account")
      end

      it "allows nil created_by" do
        project = build(:project, :without_creator)

        expect(project).to be_valid
      end
    end
  end

  describe "scopes" do
    describe ".active" do
      it "includes active projects" do
        active_project = create(:project, active: true)
        expect(described_class.active).to include(active_project)
      end

      it "excludes inactive projects" do
        inactive_project = create(:project, :inactive)
        expect(described_class.active).not_to include(inactive_project)
      end
    end

    describe ".inactive" do
      it "includes inactive projects" do
        inactive_project = create(:project, :inactive)
        expect(described_class.inactive).to include(inactive_project)
      end

      it "excludes active projects" do
        active_project = create(:project, active: true)
        expect(described_class.inactive).not_to include(active_project)
      end
    end
  end

  describe "instance methods" do
    describe "#full_name" do
      it "returns owner/repo format" do
        project = build(:project, owner: "viamin", repo: "paid")
        expect(project.full_name).to eq("viamin/paid")
      end
    end

    describe "#github_url" do
      it "returns the GitHub URL" do
        project = build(:project, owner: "viamin", repo: "paid")
        expect(project.github_url).to eq("https://github.com/viamin/paid")
      end
    end

    describe "#activate!" do
      it "sets active to true" do
        project = create(:project, :inactive)
        project.activate!

        expect(project.active).to be true
      end
    end

    describe "#deactivate!" do
      it "sets active to false" do
        project = create(:project)
        project.deactivate!

        expect(project.active).to be false
      end
    end

    describe "#label_for_stage" do
      it "returns the label for the given stage" do
        project = build(:project, :with_label_mappings)

        expect(project.label_for_stage(:planning)).to eq("paid:planning")
        expect(project.label_for_stage("in_progress")).to eq("paid:in-progress")
      end

      it "returns nil for unknown stage" do
        project = build(:project)

        expect(project.label_for_stage(:unknown)).to be_nil
      end
    end

    describe "#set_label_for_stage" do
      it "sets the label for the given stage" do
        project = build(:project)
        project.set_label_for_stage(:planning, "custom:planning")

        expect(project.label_mappings["planning"]).to eq("custom:planning")
      end

      it "preserves existing label mappings" do
        project = build(:project, :with_label_mappings)
        project.set_label_for_stage(:new_stage, "custom:new")

        expect(project.label_mappings["planning"]).to eq("paid:planning")
        expect(project.label_mappings["new_stage"]).to eq("custom:new")
      end
    end

    describe "#increment_metrics!" do
      it "increments cost and tokens used" do
        project = create(:project, total_cost_cents: 100, total_tokens_used: 1000)

        project.increment_metrics!(cost_cents: 50, tokens_used: 500)

        expect(project.total_cost_cents).to eq(150)
        expect(project.total_tokens_used).to eq(1500)
      end
    end
  end

  describe "polling lifecycle hooks" do
    let(:temporal_client) { instance_double(Temporalio::Client) }
    let(:workflow_handle) { double("workflow_handle") } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
      allow(temporal_client).to receive(:start_workflow)
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:cancel)
    end

    describe "after_create_commit" do
      it "starts polling for active projects" do
        project = create(:project, active: true)

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::GitHubPollWorkflow,
          { project_id: project.id },
          id: "github-poll-#{project.id}",
          task_queue: "paid-tasks"
        )
      end

      it "does not start polling for inactive projects" do
        create(:project, :inactive)

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    describe "after_destroy_commit" do
      it "stops polling when project is destroyed" do
        project = create(:project, active: true)

        project.destroy!

        expect(temporal_client).to have_received(:workflow_handle).with("github-poll-#{project.id}")
        expect(workflow_handle).to have_received(:cancel)
      end

      it "does not stop polling when destroy is rolled back" do
        project = create(:project, active: true)

        expect {
          ActiveRecord::Base.transaction do
            project.destroy!
            raise ActiveRecord::Rollback
          end
        }.not_to change(described_class, :count)

        expect(workflow_handle).not_to have_received(:cancel)
      end
    end

    describe "after_update_commit on active change" do
      it "starts polling when activated" do
        project = create(:project, :inactive)

        project.activate!

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::GitHubPollWorkflow,
          { project_id: project.id },
          id: "github-poll-#{project.id}",
          task_queue: "paid-tasks"
        )
      end

      it "stops polling when deactivated" do
        project = create(:project, active: true)

        project.deactivate!

        expect(temporal_client).to have_received(:workflow_handle).with("github-poll-#{project.id}")
        expect(workflow_handle).to have_received(:cancel)
      end

      it "does not toggle polling when other attributes change" do
        project = create(:project, active: true)

        project.update!(name: "new-name")

        expect(workflow_handle).not_to have_received(:cancel)
        # start_workflow only called once (on create), not again on name update
        expect(temporal_client).to have_received(:start_workflow).once
      end
    end
  end

  describe "allowed_github_usernames validation" do
    it "requires at least one trusted username" do
      project = build(:project, allowed_github_usernames: [])

      expect(project).not_to be_valid
      expect(project.errors[:allowed_github_usernames]).to include("must include at least one trusted GitHub username")
    end

    it "rejects array with only blank strings" do
      project = build(:project, allowed_github_usernames: [ "", " " ])

      expect(project).not_to be_valid
    end

    it "accepts array with at least one present username" do
      project = build(:project, allowed_github_usernames: [ "viamin" ])

      expect(project).to be_valid
    end
  end

  describe "#trusted_github_user?" do
    let(:project) { build(:project, allowed_github_usernames: [ "viamin", "OtherUser" ]) }

    it "returns true for an allowlisted user" do
      expect(project.trusted_github_user?("viamin")).to be true
    end

    it "is case-insensitive" do
      expect(project.trusted_github_user?("VIAMIN")).to be true
      expect(project.trusted_github_user?("otheruser")).to be true
      expect(project.trusted_github_user?("OtherUser")).to be true
    end

    it "returns false for a non-allowlisted user" do
      expect(project.trusted_github_user?("attacker")).to be false
    end

    it "returns false for nil login" do
      expect(project.trusted_github_user?(nil)).to be false
    end

    it "returns false for blank login" do
      expect(project.trusted_github_user?("")).to be false
    end
  end

  describe "label_mappings JSONB storage" do
    it "stores label mappings as JSONB" do
      mappings = {
        "planning" => "paid:planning",
        "in_progress" => "paid:in-progress"
      }
      project = create(:project, label_mappings: mappings)
      reloaded = described_class.find(project.id)

      expect(reloaded.label_mappings).to eq(mappings)
    end

    it "defaults to empty hash" do
      project = create(:project, label_mappings: {})
      expect(project.label_mappings).to eq({})
    end
  end

  describe "account association" do
    it "is destroyed when account is destroyed" do
      account = create(:account)
      create(:user, account: account)
      project = create(:project, account: account)

      expect { account.destroy }.to change(described_class, :count).by(-1)
      expect { project.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "github_token association" do
    it "prevents deletion of github_token with projects" do
      project = create(:project)
      github_token = project.github_token

      expect { github_token.destroy }.not_to change(GithubToken, :count)
      expect(github_token.errors[:base]).to include("Cannot delete record because dependent projects exist")
    end
  end

  describe "user association" do
    it "allows project to exist without creator" do
      project = create(:project, :without_creator)
      expect(project.created_by).to be_nil
      expect(project).to be_valid
    end

    it "sets created_by to nil when user is destroyed" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)

      user.destroy
      project.reload

      expect(project.created_by).to be_nil
    end
  end
end
