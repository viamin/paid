# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Prompts" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "GET /prompts" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get prompts_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get prompts_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Prompts")
      end

      it "shows global prompts" do
        create(:prompt, :global, :with_version, name: "Global Prompt")
        get prompts_path
        expect(response.body).to include("Global Prompt")
      end

      it "shows account prompts" do
        create(:prompt, :for_account, name: "Account Prompt", account: account)
        get prompts_path
        expect(response.body).to include("Account Prompt")
      end

      it "shows project prompts for the user's account" do
        create(:prompt, :for_project, name: "Project Prompt", project: project)
        get prompts_path
        expect(response.body).to include("Project Prompt")
      end

      it "does not show prompts from other accounts" do
        other_account = create(:account)
        create(:prompt, :for_account, name: "Other Account Prompt", account: other_account)
        get prompts_path
        expect(response.body).not_to include("Other Account Prompt")
      end

      it "filters by category" do
        create(:prompt, :for_account, :planning, name: "Planning Prompt", account: account)
        create(:prompt, :for_account, name: "Coding Prompt", account: account)
        get prompts_path, params: { q: { category_eq: "planning" } }
        expect(response.body).to include("Planning Prompt")
        expect(response.body).not_to include("Coding Prompt")
      end

      it "filters by active status" do
        create(:prompt, :for_account, name: "Active Prompt", account: account)
        create(:prompt, :for_account, :inactive, name: "Inactive Prompt", account: account)
        get prompts_path, params: { q: { active_eq: "true" } }
        expect(response.body).to include("Active Prompt")
        expect(response.body).not_to include("Inactive Prompt")
      end

      it "shows scope badges" do
        create(:prompt, :global, name: "Global One")
        create(:prompt, :for_account, name: "Account One", account: account)
        get prompts_path
        expect(response.body).to include("Global")
        expect(response.body).to include("Account")
      end
    end
  end

  describe "GET /prompts/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        prompt = create(:prompt, :global, :with_version)
        get prompt_path(prompt)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the prompt details" do
        prompt = create(:prompt, :for_account, :with_version, name: "My Prompt", account: account)
        get prompt_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Prompt")
      end

      it "shows global prompts" do
        prompt = create(:prompt, :global, :with_version, name: "Global Prompt")
        get prompt_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Global Prompt")
      end

      it "shows the current template" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Hello {{name}}")
        get prompt_path(prompt)
        expect(response.body).to include("Hello {{name}}")
      end

      it "shows version history" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Version 1", change_notes: "Initial")
        prompt.create_version!(template: "Version 2", change_notes: "Updated template")
        get prompt_path(prompt)
        expect(response.body).to include("Version History")
        expect(response.body).to include("Initial")
        expect(response.body).to include("Updated template")
      end

      it "indicates the current version" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Version 1")
        prompt.create_version!(template: "Version 2")
        get prompt_path(prompt)
        expect(response.body).to include("current")
      end

      it "shows project-level prompts for same account" do
        prompt = create(:prompt, :for_project, :with_version, name: "Project Prompt", project: project)
        get prompt_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Project Prompt")
      end
    end
  end

  describe "GET /prompts/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_prompt_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new prompt form" do
        get new_prompt_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New Prompt")
      end
    end
  end

  describe "POST /prompts" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post prompts_path, params: { prompt: { name: "Test", slug: "test", category: "coding" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      let(:valid_params) do
        {
          prompt: {
            name: "Code Review Prompt",
            slug: "review.code",
            category: "review",
            description: "A code review prompt",
            template: "Review this code: {{code}}",
            variables_text: "code",
            active: true
          }
        }
      end

      it "creates a new prompt" do
        expect {
          post prompts_path, params: valid_params
        }.to change(Prompt, :count).by(1)
      end

      it "creates the initial version" do
        post prompts_path, params: valid_params
        prompt = Prompt.last
        expect(prompt.current_version).to be_present
        expect(prompt.current_version.template).to eq("Review this code: {{code}}")
      end

      it "redirects to the prompt with success message" do
        post prompts_path, params: valid_params
        expect(response).to redirect_to(prompt_path(Prompt.last))
        expect(flash[:notice]).to include("successfully created")
      end

      it "associates the prompt with the current account" do
        post prompts_path, params: valid_params
        expect(Prompt.last.account).to eq(account)
      end

      it "allows creating a project-level prompt" do
        post prompts_path, params: {
          prompt: valid_params[:prompt].merge(project_id: project.id)
        }
        expect(Prompt.last.project).to eq(project)
      end

      context "with invalid parameters" do
        it "re-renders the form with errors" do
          post prompts_path, params: { prompt: { name: "", slug: "", category: "" } }
          expect(response).to have_http_status(:unprocessable_content)
        end

        it "preserves user-entered version fields on validation error" do
          post prompts_path, params: {
            prompt: {
              name: "", slug: "", category: "",
              template: "Preserve this template {{var}}",
              system_prompt: "Preserve this system prompt",
              variables_text: "var, other"
            }
          }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Preserve this template {{var}}")
          expect(response.body).to include("Preserve this system prompt")
          expect(response.body).to include("var, other")
        end
      end
    end
  end

  describe "GET /prompts/:id/edit" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        prompt = create(:prompt, :for_account, account: account)
        get edit_prompt_path(prompt)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the edit form" do
        prompt = create(:prompt, :for_account, :with_version, name: "My Prompt", account: account)
        get edit_prompt_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Edit Prompt")
        expect(response.body).to include("My Prompt")
      end

      it "mentions immutable versions" do
        prompt = create(:prompt, :for_account, :with_version, account: account)
        get edit_prompt_path(prompt)
        expect(response.body).to include("immutable")
      end
    end
  end

  describe "PATCH /prompts/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        prompt = create(:prompt, :for_account, account: account)
        patch prompt_path(prompt), params: { prompt: { name: "Updated" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "updates the prompt name" do
        prompt = create(:prompt, :for_account, name: "Old Name", account: account)
        patch prompt_path(prompt), params: { prompt: { name: "New Name" } }
        expect(prompt.reload.name).to eq("New Name")
      end

      it "creates a new version when template changes" do
        prompt = create(:prompt, :for_account, :with_version, account: account)
        expect {
          patch prompt_path(prompt), params: {
            prompt: { template: "New template content", change_notes: "Updated" }
          }
        }.to change(PromptVersion, :count).by(1)
      end

      it "does not create a new version when only metadata changes" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Existing template")
        expect {
          patch prompt_path(prompt), params: {
            prompt: { name: "Updated Name", template: "Existing template" }
          }
        }.not_to change(PromptVersion, :count)
      end

      it "preserves previous versions (immutable)" do
        prompt = create(:prompt, :for_account, account: account)
        v1 = prompt.create_version!(template: "Version 1")
        patch prompt_path(prompt), params: {
          prompt: { template: "Version 2", change_notes: "Updated" }
        }
        expect(v1.reload.template).to eq("Version 1")
        expect(prompt.reload.current_version.template).to eq("Version 2")
      end

      it "redirects to the prompt with success message" do
        prompt = create(:prompt, :for_account, account: account)
        patch prompt_path(prompt), params: { prompt: { name: "Updated" } }
        expect(response).to redirect_to(prompt_path(prompt))
        expect(flash[:notice]).to include("successfully updated")
      end

      it "preserves user-entered version fields on validation error" do
        prompt = create(:prompt, :for_account, :with_version, account: account)
        patch prompt_path(prompt), params: {
          prompt: {
            name: "",
            template: "Updated template content",
            system_prompt: "Updated system prompt",
            variables_text: "foo, bar"
          }
        }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Updated template content")
        expect(response.body).to include("Updated system prompt")
        expect(response.body).to include("foo, bar")
      end
    end
  end

  describe "DELETE /prompts/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        prompt = create(:prompt, :for_account, account: account)
        delete prompt_path(prompt)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "deletes account-level prompts for owners" do
        prompt = create(:prompt, :for_account, account: account)
        expect {
          delete prompt_path(prompt)
        }.to change(Prompt, :count).by(-1)
      end

      it "redirects with success message" do
        prompt = create(:prompt, :for_account, account: account)
        delete prompt_path(prompt)
        expect(response).to redirect_to(prompts_path)
        expect(flash[:notice]).to include("deleted")
      end

      it "does not allow deleting global prompts" do
        prompt = create(:prompt, :global)
        delete prompt_path(prompt)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /prompts/:id/diff" do
    context "when authenticated" do
      before { sign_in user }

      it "shows the diff between two versions" do
        prompt = create(:prompt, :for_account, account: account)
        v1 = prompt.create_version!(template: "Old template")
        v2 = prompt.create_version!(template: "New template", parent_version: v1)
        get diff_prompt_path(prompt, a: v1.id, b: v2.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Old template")
        expect(response.body).to include("New template")
        expect(response.body).to include("Version Diff")
      end

      it "redirects when version params are missing" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Template")
        get diff_prompt_path(prompt)
        expect(response).to redirect_to(prompt_path(prompt))
        expect(flash[:alert]).to include("two different versions")
      end

      it "redirects when both version params are the same" do
        prompt = create(:prompt, :for_account, account: account)
        v1 = prompt.create_version!(template: "Template")
        get diff_prompt_path(prompt, a: v1.id, b: v1.id)
        expect(response).to redirect_to(prompt_path(prompt))
      end

      it "returns not found when version IDs are invalid" do
        prompt = create(:prompt, :for_account, account: account)
        prompt.create_version!(template: "Template")
        get diff_prompt_path(prompt, a: 0, b: 999_999)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
