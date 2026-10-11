import { actionMatchRank, normalizeSearch } from "../lib/plugin-search";
import { clearLocalizedText, setLocalizedText } from "./site-language";

const settingsWindow = document.querySelector<HTMLElement>("[data-settings-window]");

if (settingsWindow) {
  const root = document.documentElement;
  const sidebarTabs = [...settingsWindow.querySelectorAll<HTMLButtonElement>("[data-settings-tab]")];
  const pluginSettingsTabs = sidebarTabs.filter((tab) => tab.dataset.settingsTab !== "market");
  const panels = [...settingsWindow.querySelectorAll<HTMLElement>("[data-settings-panel]")];
  const marketSearch = settingsWindow.querySelector<HTMLInputElement>("[data-market-search]");
  const filterButtons = [...settingsWindow.querySelectorAll<HTMLButtonElement>("[data-market-filter]")];
  const pluginRows = [...settingsWindow.querySelectorAll<HTMLElement>("[data-market-plugin]")];
  const marketList = settingsWindow.querySelector<HTMLElement>(".market-list");
  const resultCounts = [...settingsWindow.querySelectorAll<HTMLElement>("[data-result-count]")];
  const marketEmpty = settingsWindow.querySelector<HTMLElement>("[data-market-empty]");
  const actionCounts = [...settingsWindow.querySelectorAll<HTMLElement>("[data-action-result-count]")];
  const actionSummary = settingsWindow.querySelector<HTMLElement>("[data-action-result-summary]");
  const searchGroups = pluginRows.map((row) => ({
    row,
    region: row.querySelector<HTMLElement>("[data-search-actions]"),
    primary: row.querySelector<HTMLElement>("[data-search-primary]"),
    overflow: row.querySelector<HTMLElement>("[data-search-overflow]"),
    more: row.querySelector<HTMLDetailsElement>("[data-search-more]"),
    actions: [...row.querySelectorAll<HTMLElement>("[data-search-action]")],
  }));
  let activeFilter = "all";
  let previousQuery = "";
  let previousFilter = "all";

  const sortMarketRows = () => {
    if (!marketList) return;

    const language = root.dataset.lang === "en" ? "en" : "zh";
    const nameKey = language === "en" ? "pluginNameEn" : "pluginNameZh";
    const collator = new Intl.Collator(language === "en" ? "en" : "zh-CN", {
      numeric: true,
      sensitivity: "base",
    });
    const sortedRows = [...pluginRows].sort((left, right) => {
      const byName = collator.compare(left.dataset[nameKey] ?? "", right.dataset[nameKey] ?? "");
      return byName || collator.compare(left.dataset.pluginId ?? "", right.dataset.pluginId ?? "");
    });

    for (const row of sortedRows) marketList.append(row);
    if (marketEmpty) marketList.append(marketEmpty);
  };

  const sortPluginSettingsTabs = () => {
    const parent = pluginSettingsTabs[0]?.parentElement;
    if (!parent) return;

    const language = root.dataset.lang === "en" ? "en" : "zh";
    const nameKey = language === "en" ? "pluginNameEn" : "pluginNameZh";
    const collator = new Intl.Collator(language === "en" ? "en" : "zh-CN", {
      numeric: true,
      sensitivity: "base",
    });
    const sortedTabs = [...pluginSettingsTabs].sort((left, right) => {
      const byName = collator.compare(left.dataset[nameKey] ?? "", right.dataset[nameKey] ?? "");
      return byName || collator.compare(left.dataset.pluginId ?? "", right.dataset.pluginId ?? "");
    });

    for (const tab of sortedTabs) parent.append(tab);
  };

  const syncLocalizedFields = () => {
    const language = root.dataset.lang === "en" ? "en" : "zh";
    if (marketSearch) {
      marketSearch.placeholder = language === "en"
        ? marketSearch.dataset.placeholderEn ?? ""
        : marketSearch.dataset.placeholderZh ?? "";
    }
    settingsWindow.querySelectorAll<HTMLOptionElement>("[data-option-zh]").forEach((item) => {
      item.textContent = language === "en" ? item.dataset.optionEn ?? "" : item.dataset.optionZh ?? "";
    });
    settingsWindow.querySelectorAll<HTMLElement>("[data-aria-label-zh]").forEach((item) => {
      item.setAttribute(
        "aria-label",
        language === "en" ? item.dataset.ariaLabelEn ?? "" : item.dataset.ariaLabelZh ?? "",
      );
    });
    sortMarketRows();
    sortPluginSettingsTabs();
    applyMarketFilter();
  };

  const showPanel = (id: string, updateHash = true) => {
    const targetPanel = panels.find((panel) => panel.dataset.settingsPanel === id) ?? panels[0];
    if (!targetPanel) return;

    const targetID = targetPanel.dataset.settingsPanel ?? "market";
    for (const panel of panels) {
      panel.hidden = panel !== targetPanel;
    }

    for (const tab of sidebarTabs) {
      const isSelected = tab.dataset.settingsTab === targetID;
      tab.classList.toggle("is-selected", isSelected);
      tab.setAttribute("aria-selected", String(isSelected));
      if (isSelected && window.matchMedia("(max-width: 760px)").matches) {
        tab.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
      }
    }

    if (targetID !== "market") {
      targetPanel.scrollTo({ top: 0, behavior: "smooth" });
    }

    if (updateHash) {
      const nextHash = targetID === "market" ? "" : `#${targetID}`;
      history.replaceState(null, "", `${location.pathname}${location.search}${nextHash}`);
    }
  };

  for (const tab of sidebarTabs) {
    tab.addEventListener("click", () => showPanel(tab.dataset.settingsTab ?? "market"));
  }

  const applyMarketFilter = () => {
    const query = normalizeSearch(marketSearch?.value ?? "");
    const resetExpansion = query !== previousQuery || activeFilter !== previousFilter;
    const language = root.dataset.lang === "en" ? "en" : "zh";
    const collator = new Intl.Collator(language === "en" ? "en" : "zh-CN", { numeric: true, sensitivity: "base" });
    let visibleCount = 0;
    let actionCount = 0;

    for (const { row, region, primary, overflow, more, actions } of searchGroups) {
      const matchesCategory = activeFilter === "all" || row.dataset.category === activeFilter;
      const matchesSearch = !query || (row.dataset.search ?? "").includes(query);
      const ranked = actions.map((action) => ({
        action,
        rank: actionMatchRank({
          titleTerms: action.dataset.titleTerms ?? "",
          keywordTerms: action.dataset.keywordTerms ?? "",
          descriptionTerms: action.dataset.descriptionTerms ?? "",
        }, query),
      }));
      const matching = ranked.filter(({ rank }) => rank > 0).sort((left, right) =>
        right.rank - left.rank
        || collator.compare(left.action.dataset[language === "en" ? "titleEn" : "titleZh"] ?? "", right.action.dataset[language === "en" ? "titleEn" : "titleZh"] ?? "")
        || collator.compare(left.action.dataset.actionId ?? "", right.action.dataset.actionId ?? ""),
      );
      const isVisible = matchesCategory && (matchesSearch || matching.length > 0);
      row.hidden = !isVisible;
      if (isVisible) visibleCount += 1;
      if (isVisible) actionCount += matching.length;

      for (const { action, rank } of ranked) action.hidden = !isVisible || rank === 0;
      if (region) region.hidden = !isVisible || matching.length === 0;
      if (more) {
        if (resetExpansion || !query) more.open = false;
        more.hidden = !isVisible || matching.length <= 3;
        more.querySelectorAll<HTMLElement>("[data-more-count]").forEach((count) => {
          count.textContent = String(Math.max(0, matching.length - 3));
        });
      }
      for (const [index, { action }] of matching.entries()) {
        (index < 3 ? primary : overflow)?.append(action);
      }
    }

    for (const count of resultCounts) {
      count.textContent = String(visibleCount);
    }
    for (const count of actionCounts) count.textContent = String(actionCount);
    if (actionSummary) actionSummary.hidden = !query;
    if (marketEmpty) marketEmpty.hidden = visibleCount !== 0;
    previousQuery = query;
    previousFilter = activeFilter;
  };

  for (const button of filterButtons) {
    button.addEventListener("click", () => {
      activeFilter = button.dataset.marketFilter ?? "all";
      for (const item of filterButtons) {
        const isSelected = item === button;
        item.classList.toggle("is-selected", isSelected);
        item.setAttribute("aria-pressed", String(isSelected));
      }
      applyMarketFilter();
    });
  }

  marketSearch?.addEventListener("input", applyMarketFilter);
  syncLocalizedFields();
  new MutationObserver(syncLocalizedFields).observe(root, {
    attributes: true,
    attributeFilter: ["data-lang"],
  });

  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === "f") {
      const marketPanel = panels.find((panel) => panel.dataset.settingsPanel === "market");
      if (!marketPanel?.hidden) {
        event.preventDefault();
        marketSearch?.focus();
      }
    }
  });

  settingsWindow.querySelectorAll<HTMLButtonElement>("[data-setting-switch]").forEach((control) => {
    control.addEventListener("click", () => {
      control.setAttribute("aria-checked", String(control.getAttribute("aria-checked") !== "true"));
    });
  });

  settingsWindow.querySelectorAll<HTMLElement>("[data-segmented-control]").forEach((control) => {
    const buttons = [...control.querySelectorAll<HTMLButtonElement>("button")];
    for (const button of buttons) {
      button.addEventListener("click", () => {
        for (const item of buttons) {
          const isSelected = item === button;
          item.classList.toggle("is-selected", isSelected);
          item.setAttribute("aria-pressed", String(isSelected));
        }
      });
    }
  });

  settingsWindow.querySelectorAll<HTMLInputElement>("[data-range-control]").forEach((control) => {
    const output = control.parentElement?.querySelector<HTMLOutputElement>("output");
    const initialText = output?.textContent ?? "";
    const unit = initialText.replace(/^-?[\d,.]+/, "");
    control.addEventListener("input", () => {
      if (output) output.textContent = `${control.value}${unit}`;
    });
  });

  settingsWindow.querySelectorAll<HTMLButtonElement>("[data-demo-action]").forEach((button) => {
    const initialMarkup = button.innerHTML;
    button.addEventListener("click", () => {
      setLocalizedText(button, "完成", "Done");
      button.classList.add("is-complete");
      window.setTimeout(() => {
        clearLocalizedText(button);
        button.innerHTML = initialMarkup;
        button.classList.remove("is-complete");
      }, 1200);
    });
  });

  settingsWindow.querySelectorAll<HTMLButtonElement>("[data-plugin-action]").forEach((button) => {
    const row = button.closest<HTMLElement>("[data-market-plugin]");
    const initialMarkup = button.innerHTML;
    if (!row) return;

    button.addEventListener("click", () => {
      const isInstalled = row.dataset.installed === "true";
      button.disabled = true;
      button.classList.add("is-busy");
      setLocalizedText(button, isInstalled ? "卸载中" : "安装中", isInstalled ? "Uninstalling" : "Installing");

      window.setTimeout(() => {
        const nextInstalled = !isInstalled;
        row.dataset.installed = String(nextInstalled);
        row.querySelector<HTMLElement>(".market-plugin-status")?.setAttribute(
          "data-aria-label-zh",
          nextInstalled ? "已安装" : "未安装",
        );
        const status = row.querySelector<HTMLElement>(".market-plugin-status");
        status?.setAttribute(
          "data-aria-label-en",
          nextInstalled ? "Installed" : "Not installed",
        );
        syncLocalizedFields();
        clearLocalizedText(button);
        button.innerHTML = initialMarkup;
        button.disabled = false;
        button.classList.remove("is-busy");
      }, 650);
    });
  });

  const requestedPanel = location.hash.replace(/^#/, "");
  showPanel(requestedPanel || "market", false);
}
