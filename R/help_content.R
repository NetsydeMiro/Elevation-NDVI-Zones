# Small "?" icon placed beside a control's label. Hovering/focusing shows a
# Bootstrap popover with a short explanation and, if `anchor` is given, a
# "Learn more" link that jumps to that section of the in-app Manual tab.
help_icon <- function(text, anchor = NULL) {
  content <- tagList(
    tags$p(text, class = "mb-1"),
    if (!is.null(anchor)) {
      tags$a(
        "Learn more →", href = "#",
        class = "help-learn-more",
        `data-manual-anchor` = anchor
      )
    }
  )

  tags$span(
    class = "help-icon",
    `data-bs-toggle` = "popover",
    `data-bs-trigger` = "manual",
    `data-bs-html` = "true",
    `data-bs-placement` = "right",
    `data-bs-content` = as.character(content),
    tabindex = "0",
    role = "button",
    "?"
  )
}

# Combines a label with its help icon, for use as the `label` argument of any
# standard Shiny input (fileInput, sliderInput, numericInput, etc. all accept
# HTML/tagList there).
label_with_help <- function(label, text, anchor = NULL) {
  tagList(label, help_icon(text, anchor))
}
