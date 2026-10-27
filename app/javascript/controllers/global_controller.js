import { Controller } from "@hotwired/stimulus"
import * as ActionCable from "@rails/actioncable"
import { Zealot } from "./zealot"
import { application } from "./application"

export default class extends Controller {
  static values = {
    env: String,
    rootUrl: String,
    appearance: String
  }

  connect() {
    try {
      // AdminLTE inserts English skip links with targets that differ from our layout.
      // Keep the localized, server-rendered link pointing to #main-content.
      this.element.querySelectorAll(".skip-links").forEach(container => container.remove())
      this.initZealot()
      this.setupRailsDebugMode()
      this.switchDarkMode()
      this.isInitialized = true
    } catch (error) {
      console.error('GlobalController initialization error:', error)
    }
  }

  initZealot() {
    Zealot.rootUrl = this.rootUrlValue
    Zealot.siteApperance = this.appearanceValue
    Zealot.env = this.envValue
  }

  disconnect() {
    this.colorScheme?.removeEventListener("change", this.systemAppearanceChanged)
  }

  switchDarkMode() {
    this.appearance = ["light", "dark", "auto"].includes(this.appearanceValue) ? this.appearanceValue : "auto"
    this.themeKey = document.querySelector('meta[name="zealot-theme-key"]')?.content
    try {
      const stored = this.themeKey && localStorage.getItem(this.themeKey)
      if (["light", "dark", "auto"].includes(stored)) this.appearance = stored
    } catch (_) { /* Theme selection still works without storage. */ }
    this.colorScheme = matchMedia("(prefers-color-scheme: dark)")
    this.systemAppearanceChanged = () => this.applyAppearance()
    this.colorScheme.addEventListener("change", this.systemAppearanceChanged)
    this.applyAppearance()
  }

  changeAppearance(event) {
    this.appearance = event.currentTarget.dataset.appearance
    try { if (this.themeKey) localStorage.setItem(this.themeKey, this.appearance) } catch (_) {}
    this.applyAppearance()
  }

  applyAppearance() {
    const dark = this.appearance === "dark" || (this.appearance === "auto" && this.colorScheme.matches)
    document.documentElement.dataset.bsTheme = dark ? "dark" : "light"
    this.element.querySelectorAll("[data-appearance]").forEach(button => {
      button.setAttribute("aria-checked", String(button.dataset.appearance === this.appearance))
    })
    try { localStorage.setItem("good_job-theme", this.appearance) } catch (_) {}
  }

  setupRailsDebugMode() {
    application.debug = Zealot.isDevelopment()
    ActionCable.logger.enabled = Zealot.isDevelopment()
  }
}
