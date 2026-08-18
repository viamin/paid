# frozen_string_literal: true

# Marketplace prompt attachments attached to the agent run. Wraps
# {MarketplaceEntries::InjectIntoPrompt} so the assembly carries marketplace
# content as a tracked, provenance-bearing section.
#
# When this section is included, the assembly result is marked as having
# handled marketplace so {AgentRun#effective_prompt} does not re-inject.
class PromptAssembly::Sections::MarketplaceAttachments
  include PromptAssembly::Sections::Base

  private

  def build_section
    return "" unless agent_run&.agent_run_marketplace_entries&.exists?

    runner_key = agent_run.runner&.runner_key ||
      RunnerSupport.runner_key_for_agent_type(agent_run.agent_type)

    injected = MarketplaceEntries::InjectIntoPrompt.call(
      agent_run: agent_run,
      prompt: "",
      provider_key: runner_key
    )
    injected.strip
  end

  def inclusion_reason
    "marketplace prompt attachments"
  end

  def skip_reason
    return "no_agent_run" unless agent_run
    return "no_marketplace_entries" unless agent_run.agent_run_marketplace_entries.exists?

    nil
  end
end
