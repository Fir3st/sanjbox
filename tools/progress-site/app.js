"use strict";

// Optional light/dark override; without JavaScript the page follows the system setting.
const root = document.documentElement;
const button = document.querySelector(".theme");
try {
  const theme = localStorage.getItem("sanjbox-theme");
  if (theme === "light" || theme === "dark") root.dataset.theme = theme;
} catch { /* Storage may be unavailable in file previews or private browsing. */ }
button.hidden = false;
button.addEventListener("click", () => {
  const isLight = root.dataset.theme === "light" ||
    (!root.dataset.theme && matchMedia("(prefers-color-scheme: light)").matches);
  root.dataset.theme = isLight ? "dark" : "light";
  try { localStorage.setItem("sanjbox-theme", root.dataset.theme); } catch { /* Optional preference. */ }
});
