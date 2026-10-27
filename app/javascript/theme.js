(() => {
  const modes = ["light", "dark", "auto"]
  let appearance = document.querySelector('meta[name="zealot-appearance"]')?.content || "auto"
  try {
    const key = document.querySelector('meta[name="zealot-theme-key"]')?.content
    const stored = key && localStorage.getItem(key)
    if (modes.includes(stored)) appearance = stored
  } catch (_) { /* Storage can be unavailable in private contexts. */ }
  const dark = appearance === "dark" || (appearance === "auto" && matchMedia("(prefers-color-scheme: dark)").matches)
  document.documentElement.dataset.bsTheme = dark ? "dark" : "light"
})()
