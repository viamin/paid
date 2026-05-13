# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Business context questionnaire", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let!(:account) { create(:account) }
  let!(:user) do
    create(:user, :owner, account: account, email: "owner@example.com", password: "password123")
  end
  let!(:project) { create(:project, account: account, created_by: user) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "completes the questionnaire, persists business context, and reuses it for later prompts" do
    answers = questionnaire_answers

    sign_in_and_start_questionnaire
    complete_questionnaire(answers)
    expect_persisted_business_context(answers)
    expect_later_prompt_to_include_business_context(answers)
  end

  def sign_in_and_start_questionnaire
    visit project_context_intake_path(project)
    click_button "Start Business Context Questionnaire"

    expect(page).to have_content("Business context questionnaire started.")
  end

  def complete_questionnaire(answers)
    sections = Knowledge::ContextIntake::QuestionnaireSchema.sections

    sections.each_with_index do |section, section_index|
      expect_active_section(section[:key], section[:title])

      section[:questions].each_with_index do |question, question_index|
        answer_question(question[:key], answers.fetch(question[:key]))

        next_section_key = if question_index < section[:questions].length - 1
          section[:key]
        else
          sections[section_index + 1]&.fetch(:key, section[:key]) || section[:key]
        end

        next_section_title = sections.find { |entry| entry[:key] == next_section_key }[:title]
        expect_active_section(next_section_key, next_section_title)
      end
    end

    click_button "Complete & Save Business Context"

    expect(page).to have_content("Business context saved and synthesized into project knowledge.")
    expect(page).to have_content("Business context captured")
  end

  def expect_persisted_business_context(answers)
    artifacts, chunk_contents = TenantContext.with_system_access do
      fresh_project = Project.find(project.id)
      loaded_artifacts = KnowledgeArtifact.for_project(fresh_project).active.by_type("business_context").includes(:knowledge_chunks).to_a
      loaded_chunk_contents = loaded_artifacts.flat_map do |artifact|
        artifact.knowledge_chunks.select { |chunk| chunk.status == "active" }.map(&:content)
      end

      [ loaded_artifacts, loaded_chunk_contents ]
    end

    expect(artifacts.count).to eq(Knowledge::ContextIntake::QuestionnaireSchema.sections.count)
    expect(artifacts.map(&:identifier)).to include("business_context:product_purpose", "business_context:terminology")
    expect(artifacts.find { |artifact| artifact.identifier == "business_context:product_purpose" }&.content)
      .to include(answers.fetch("product_description"))
    expect(chunk_contents).to include(a_string_including(answers.fetch("domain_terms")))
  end

  def expect_later_prompt_to_include_business_context(answers)
    prompt = TenantContext.with(account) do
      fresh_project = Project.find(project.id)
      created_issue = create(:issue,
        project: fresh_project,
        title: "Clarify enterprise billing workflows",
        body: "Need to update billing behavior for enterprise customers.",
        github_creator_login: fresh_project.allowed_github_usernames.first)

      Prompts::BuildForIssue.call(issue: created_issue, project: fresh_project)
    end

    expect(prompt).to include("Business Context (maintainer-provided)")
    expect(prompt).to include(answers.fetch("product_description"))
    expect(prompt).to include(answers.fetch("domain_terms"))
  end

  def within_section_panel(section_key, &)
    within(find(%([data-section="#{section_key}"]), visible: true)) do
      yield
    end
  end

  def expect_active_section(section_key, section_title)
    expect(page).to have_css("[data-section]", visible: true, count: 1)

    within_section_panel(section_key) do
      expect(page).to have_css("h3", text: section_title)
    end
  end

  def answer_question(question_key, answer_text)
    within(:xpath, %(.//form[input[@name='question_key' and @value='#{question_key}']])) do
      fill_in "answer_text", with: answer_text
      click_button "Save"
    end
  end

  def questionnaire_answers
    {
      "product_description" => "Paid coordinates AI agents to turn trusted GitHub issues into reviewed pull requests.",
      "business_model" => "Teams pay for orchestrated agent runs that automate software delivery work.",
      "primary_users" => "Engineering leaders and platform teams are the primary users.",
      "non_users" => "We do not optimize this product for consumer end users.",
      "critical_journeys" => "A maintainer labels an issue, the agent opens a PR, and reviewers merge it safely.",
      "failure_modes" => "Agents must avoid opening duplicate PRs or missing dependency blockers.",
      "key_features" => "Issue orchestration, guarded execution, and automated reviews are the core features.",
      "good_bad_examples" => "Good behavior respects project rules and dependencies; bad behavior bypasses safeguards.",
      "external_resources" => "Customer onboarding docs and internal runbooks live outside the repository.",
      "api_contracts" => "GitHub webhook handling and provider quota limits constrain execution behavior.",
      "deployment_model" => "The product is delivered as a hosted SaaS control plane.",
      "environments" => "Changes move from staging to production after validation and operator approval.",
      "compliance" => "SOC 2 controls and audit trails are important for enterprise customers.",
      "slas_commitments" => "Customers expect reliable automation and careful backwards compatibility.",
      "migration_constraints" => "Ongoing multi-tenant rollout work limits risky schema changes.",
      "domain_terms" => "A Paid run is an orchestrated agent execution with project-specific guardrails.",
      "naming_conventions" => "Use project language that distinguishes issues, runs, reviews, and knowledge artifacts."
    }
  end
end
