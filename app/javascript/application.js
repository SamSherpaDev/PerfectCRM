// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

document.addEventListener("turbo:before-render", (event) => {
  document.documentElement.dataset.scheme = event.detail.newBody.dataset.scheme || "paper"
})
