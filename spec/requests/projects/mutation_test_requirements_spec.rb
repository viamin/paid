# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::MutationTestRequirements" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "PATCH /projects/:project_id/mutation_test_requirement" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        patch project_mutation_test_requirement_path(project),
          params: { mutation_test: { enabled: "1", command: "bundle exec mutant run", failure_behavior: "warn" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      context "when enabling with no existing requirement" do
        it "creates a new enabled mutation_test requirement" do
          expect {
            patch project_mutation_test_requirement_path(project),
              params: { mutation_test: { enabled: "1", command: "bundle exec mutant run", failure_behavior: "warn" } }
          }.to change(PreCommitRequirement, :count).by(1)

          req = project.pre_commit_requirements.find_by(check_type: "mutation_test")
          expect(req).to be_present
          expect(req).to be_enabled
          expect(req.command).to eq("bundle exec mutant run")
          expect(req.failure_behavior).to eq("warn")
          expect(response).to redirect_to(edit_project_path(project, anchor: "mutation-testing"))
        end

        it "uses the default command when command is blank" do
          patch project_mutation_test_requirement_path(project),
            params: { mutation_test: { enabled: "1", command: "", failure_behavior: "warn" } }

          req = project.pre_commit_requirements.find_by(check_type: "mutation_test")
          expect(req.command).to eq(PreCommitRequirement::MUTATION_TEST_DEFAULT_COMMAND)
        end
      end

      context "when disabling with no existing requirement" do
        it "does not create a requirement" do
          expect {
            patch project_mutation_test_requirement_path(project),
              params: { mutation_test: { enabled: "0", command: "bundle exec mutant run", failure_behavior: "warn" } }
          }.not_to change(PreCommitRequirement, :count)
        end
      end

      context "when an existing mutation_test requirement exists" do
        let!(:requirement) do
          create(:pre_commit_requirement, :mutation_test, :project_level,
            project: project, enabled: true, failure_behavior: "block")
        end

        it "updates the requirement when enabling" do
          patch project_mutation_test_requirement_path(project),
            params: { mutation_test: { enabled: "1", command: "bin/mutant", failure_behavior: "warn" } }

          requirement.reload
          expect(requirement).to be_enabled
          expect(requirement.command).to eq("bin/mutant")
          expect(requirement.failure_behavior).to eq("warn")
        end

        it "disables the requirement when toggled off" do
          patch project_mutation_test_requirement_path(project),
            params: { mutation_test: { enabled: "0", command: "bin/mutant", failure_behavior: "warn" } }

          requirement.reload
          expect(requirement).not_to be_enabled
        end

        it "defaults to warn when failure_behavior is invalid" do
          patch project_mutation_test_requirement_path(project),
            params: { mutation_test: { enabled: "1", command: "bin/mutant", failure_behavior: "invalid" } }

          requirement.reload
          expect(requirement.failure_behavior).to eq("warn")
        end
      end
    end

    context "when authenticated as member" do
      before do
        create(:user, account: account) # absorb owner role
        user.add_role(:member, account)
        sign_in user
      end

      it "is forbidden" do
        patch project_mutation_test_requirement_path(project),
          params: { mutation_test: { enabled: "1", command: "bundle exec mutant run", failure_behavior: "warn" } }
        expect(response).to have_http_status(:forbidden).or redirect_to(root_path)
      end
    end
  end
end
