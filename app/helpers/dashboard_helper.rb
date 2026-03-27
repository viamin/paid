# frozen_string_literal: true

module DashboardHelper
  PHASE_GROUP_LABELS = {
    "queue" => "Queue",
    "setup" => "Setup",
    "prompt" => "Prompt Prep",
    "agent" => "Agent",
    "post" => "Post-Processing",
    "cleanup" => "Cleanup"
  }.freeze

  PHASE_GROUP_BAR_STYLES = {
    "queue" => "bg-slate-400",
    "setup" => "bg-sky-500",
    "prompt" => "bg-violet-500",
    "agent" => "bg-emerald-500",
    "post" => "bg-amber-500",
    "cleanup" => "bg-rose-400"
  }.freeze

  def format_duration(seconds)
    return "--" unless seconds
    return "0s" if seconds.zero?

    if seconds >= 86400
      "#{seconds / 86400}d #{(seconds % 86400) / 3600}h"
    elsif seconds >= 3600
      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    elsif seconds >= 60
      "#{seconds / 60}m #{seconds % 60}s"
    else
      "#{seconds}s"
    end
  end

  def phase_group_label(phase_group)
    PHASE_GROUP_LABELS.fetch(phase_group, phase_group.to_s.titleize)
  end

  def phase_group_bar_style(phase_group)
    PHASE_GROUP_BAR_STYLES.fetch(phase_group, "bg-gray-400")
  end
end
