import { applyLanguage, clearLocalizedText, initializePreferences, resolveLanguage, setLocalizedText } from "./site-language";

const root = document.documentElement;
const writePreference = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    // The visible preference is already applied; persistence is optional.
  }
};
initializePreferences(resolveLanguage, applyLanguage);
// A cached document does not rerun its scripts when Back or Forward restores it.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) initializePreferences(resolveLanguage, applyLanguage);
});
new MutationObserver(() => applyLanguage(root.dataset.lang === "en" ? "en" : "zh")).observe(root, {
  attributes: true,
  attributeFilter: ["data-lang"],
});

document.querySelectorAll<HTMLElement>("[data-copy]").forEach((button) => {
  const initialMarkup = button.innerHTML;
  let resetTimer: number | undefined;

  const showCopyStatus = (zh: string, en: string) => {
    window.clearTimeout(resetTimer);
    setLocalizedText(button, zh, en);
    resetTimer = window.setTimeout(() => {
      clearLocalizedText(button);
      button.innerHTML = initialMarkup;
    }, 1600);
  };

  button.addEventListener("click", async () => {
    const value = button.dataset.copy;
    if (!value) return;

    try {
      await navigator.clipboard.writeText(value);
      showCopyStatus("已复制", "Copied");
    } catch {
      showCopyStatus("失败", "Failed");
    }
  });
});

document.querySelector<HTMLElement>("[data-theme-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  writePreference("mactools-theme", next);
});

document.querySelector<HTMLElement>("[data-language-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.lang === "en" ? "zh" : "en";
  applyLanguage(next);
  writePreference("mactools-lang", next);
});

const pluginFilterButtons = [...document.querySelectorAll<HTMLButtonElement>("[data-plugin-filter]")];
const pluginCards = [...document.querySelectorAll<HTMLElement>("[data-plugin-category]")];

if (pluginFilterButtons.length && pluginCards.length) {
  const availableFilters = new Set(pluginFilterButtons.map((button) => button.dataset.pluginFilter));

  const applyPluginFilter = (filter: string) => {
    const selectedFilter = availableFilters.has(filter) ? filter : "all";

    for (const button of pluginFilterButtons) {
      button.setAttribute("aria-pressed", String(button.dataset.pluginFilter === selectedFilter));
    }

    for (const card of pluginCards) {
      const isVisible = selectedFilter === "all" || card.dataset.pluginCategory === selectedFilter;
      card.hidden = !isVisible;
    }
  };

  for (const button of pluginFilterButtons) {
    button.addEventListener("click", () => {
      const filter = button.dataset.pluginFilter ?? "all";
      applyPluginFilter(filter);

      if (filter === "all") {
        history.replaceState(null, "", `${location.pathname}${location.search}`);
      } else {
        history.replaceState(null, "", `#${filter}`);
      }
    });
  }

  applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  window.addEventListener("hashchange", () => {
    applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  });
}
