# frozen_string_literal: true

module StyleGuidesHelper
  def style_guide_scope_badge(style_guide)
    if style_guide.project_level?
      tag.span("Project", class: "inline-flex items-center rounded-md bg-orange-100 px-2 py-1 text-xs font-medium text-orange-700")
    elsif style_guide.account_level?
      tag.span("Account", class: "inline-flex items-center rounded-md bg-blue-100 px-2 py-1 text-xs font-medium text-blue-700")
    else
      tag.span("Global", class: "inline-flex items-center rounded-md bg-gray-100 px-2 py-1 text-xs font-medium text-gray-700")
    end
  end

  def style_guide_language_badge(language)
    return tag.span("-", class: "text-gray-400") if language.blank?

    tag.span(
      language.capitalize,
      class: "inline-flex items-center rounded-md bg-indigo-100 px-2 py-1 text-xs font-medium text-indigo-700"
    )
  end
end
