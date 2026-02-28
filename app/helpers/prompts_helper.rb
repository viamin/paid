# frozen_string_literal: true

module PromptsHelper
  PROMPT_CATEGORY_STYLES = {
    "planning" => { bg: "bg-purple-100", text: "text-purple-700" },
    "coding" => { bg: "bg-blue-100", text: "text-blue-700" },
    "review" => { bg: "bg-yellow-100", text: "text-yellow-800" },
    "testing" => { bg: "bg-green-100", text: "text-green-700" }
  }.freeze

  def prompt_category_badge(category)
    styles = PROMPT_CATEGORY_STYLES[category] || { bg: "bg-gray-100", text: "text-gray-700" }
    tag.span(
      category.titleize,
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  def prompt_scope_badge(prompt)
    if prompt.project_level?
      tag.span("Project", class: "inline-flex items-center rounded-md bg-orange-100 px-2 py-1 text-xs font-medium text-orange-700")
    elsif prompt.account_level?
      tag.span("Account", class: "inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700")
    else
      tag.span("Global", class: "inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-700")
    end
  end

  def variable_display_name(var)
    case var
    when Hash then (var["name"] || var[:name]).to_s
    else var.to_s
    end
  end
end
