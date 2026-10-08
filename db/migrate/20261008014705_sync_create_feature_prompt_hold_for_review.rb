# @spec AUTO-MERGE-009
class SyncCreateFeaturePromptHoldForReview < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Tell create-feature runs to apply the structured paid-hold-review label (#4181)"
  PROMPT_SLUG = Prompts::BuildForCreateFeature::PROMPT_SLUG
  VARIABLES = [
    { "name" => "project_name", "required" => true, "description" => "Human-readable project name" },
    { "name" => "full_name", "required" => true, "description" => "Repository full_name (owner/repo)" },
    {
      "name" => "feature_brief",
      "required" => true,
      "description" => "Structured feature brief (title, problem, desired behavior, constraints, rejected alternatives, scope, done criteria, optional problem_framing, lid_requested, target_rdr_number)"
    },
    { "name" => "lid_mode", "required" => false, "description" => "Project LID mode when enabled" },
    { "name" => "lid_section", "required" => false, "description" => "Rendered LID instructions when the project has or requested LID" },
    {
      "name" => "flag_guard_rule",
      "required" => false,
      "description" => "Rendered rollout-guard rule: paid FeatureFlags wiring when repository scan confirms the API, repository-native gating elsewhere"
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
