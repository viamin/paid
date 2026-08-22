# frozen_string_literal: true

class SyncCreateFeaturePromptRolloutGuard < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Require rollout guard guidance in create-feature RDR prompts"
  PROMPT_SLUG = Prompts::BuildForCreateFeature::PROMPT_SLUG
  VARIABLES = [
    {
      "name" => "project_name",
      "required" => true,
      "description" => "Human-readable project name"
    },
    {
      "name" => "full_name",
      "required" => true,
      "description" => "Repository full_name (owner/repo)"
    },
    {
      "name" => "feature_brief",
      "required" => true,
      "description" => "Structured feature brief (title, problem, desired behavior, constraints, rejected alternatives, scope, done criteria, lid_requested, target_rdr_number)"
    },
    {
      "name" => "lid_mode",
      "required" => false,
      "description" => "Project LID mode when enabled"
    },
    {
      "name" => "lid_section",
      "required" => false,
      "description" => "Rendered LID instructions when the project has or requested LID"
    }
  ].freeze

  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: Prompts::BuildForCreateFeature::FALLBACK_PROMPT,
        variables: VARIABLES,
        created_by: "migration",
        change_notes: CHANGE_NOTES
      )
    end
  end

  def down
  end

  private

  def synced?(version)
    return false unless version

    version.template.to_s.strip == Prompts::BuildForCreateFeature::FALLBACK_PROMPT.strip &&
      version.variables == VARIABLES
  end
end
