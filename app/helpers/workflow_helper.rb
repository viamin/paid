# frozen_string_literal: true

module WorkflowHelper
  WORKFLOW_STATUS_STYLES = {
    "running" => { bg: "bg-blue-100", text: "text-blue-800" },
    "completed" => { bg: "bg-green-100", text: "text-green-800" },
    "failed" => { bg: "bg-red-100", text: "text-red-800" },
    "cancelled" => { bg: "bg-gray-100", text: "text-gray-600" },
    "timed_out" => { bg: "bg-orange-100", text: "text-orange-800" }
  }.freeze

  def workflow_status_class(status)
    styles = WORKFLOW_STATUS_STYLES[status] || { bg: "bg-yellow-100", text: "text-yellow-800" }
    "#{styles[:bg]} #{styles[:text]}"
  end

  def workflow_duration(workflow)
    return "-" unless workflow.started_at

    end_time = workflow.completed_at || Time.current
    seconds = (end_time - workflow.started_at).to_i

    if seconds < 60
      "#{seconds}s"
    elsif seconds < 3600
      "#{seconds / 60}m #{seconds % 60}s"
    else
      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    end
  end
end
