"use strict";

const root = document.documentElement;
const themeButton = document.querySelector(".theme-toggle");
try {
  const theme = localStorage.getItem("sanjbox-theme");
  if (theme === "light" || theme === "dark") root.dataset.theme = theme;
} catch { /* Storage may be unavailable in file previews or private browsing. */ }
themeButton.hidden = false;
themeButton.addEventListener("click", () => {
  const isLight = root.dataset.theme === "light" ||
    (!root.dataset.theme && matchMedia("(prefers-color-scheme: light)").matches);
  root.dataset.theme = isLight ? "dark" : "light";
  try { localStorage.setItem("sanjbox-theme", root.dataset.theme); } catch { /* Optional preference. */ }
});

const normalize = value => value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase("cs");

document.querySelectorAll(".filter-section").forEach(section => {
  const controls = section.querySelector(".filters");
  const search = controls.querySelector("input");
  const selects = [...controls.querySelectorAll("select")];
  const rows = [...section.querySelectorAll("tbody tr")];
  const update = () => {
    const query = normalize(search.value.trim());
    let count = 0;
    rows.forEach(row => {
      row.hidden = !normalize(row.textContent).includes(query) ||
        selects.some(select => select.value && row.dataset[select.dataset.filter] !== select.value);
      if (!row.hidden) count++;
    });
    section.querySelector(".filter-count").textContent = `${count} / ${rows.length}`;
    section.querySelector(".empty").hidden = count !== 0;
  };
  controls.hidden = false;
  controls.addEventListener("input", update);
  controls.addEventListener("change", update);
  // Map links must reveal their target even when the table was filtered earlier.
  window.addEventListener("hashchange", () => {
    const target = document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (!target || !section.contains(target)) return;
    search.value = "";
    selects.forEach(select => { select.value = ""; });
    update();
    target.scrollIntoView({ block: "center" });
  });
});
