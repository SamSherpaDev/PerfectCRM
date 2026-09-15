# Pin npm packages by running ./bin/importmap

pin "application"
# Thinking-orbs vanilla port (docs/DESIGN.md 4.13, MIT); mounted by the orb controller.
pin "thinking_orbs"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
