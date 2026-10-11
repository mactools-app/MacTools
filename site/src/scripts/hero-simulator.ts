import { clearLocalizedText, setLocalizedText } from "./site-language";

export {};

const root = document.documentElement;

type SimulatorLanguage = "zh" | "en";

const currentLanguage = (): SimulatorLanguage => root.dataset.lang === "en" ? "en" : "zh";
const localized = (zh: string, en: string) => currentLanguage() === "en" ? en : zh;
const randomBetween = (minimum: number, maximum: number) =>
  minimum + Math.random() * (maximum - minimum);
const clamp = (value: number, minimum: number, maximum: number) =>
  Math.min(Math.max(value, minimum), maximum);
const lunarDayLabels = [
  "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
  "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
];
const calendarEventDays = new Set([1, 8, 12, 18, 24]);

const lunarLabelForDate = (date: Date) => {
  const parts = new Intl.DateTimeFormat("zh-CN-u-ca-chinese", {
    month: "long",
    day: "numeric",
  }).formatToParts(date);
  const lunarDay = Number(parts.find((part) => part.type === "day")?.value ?? 0);
  if (lunarDay === 1) {
    return parts.find((part) => part.type === "month")?.value ?? "初一";
  }
  return lunarDayLabels[lunarDay - 1] ?? "";
};

document.querySelectorAll<HTMLElement>("[data-menubar-simulator]").forEach((simulator) => {
  const toast = simulator.querySelector<HTMLElement>("[data-sim-toast]");
  const tabs = [...simulator.querySelectorAll<HTMLButtonElement>("[data-sim-tab]")];
  const views = [...simulator.querySelectorAll<HTMLElement>("[data-sim-view]")];
  let toastTimer: number | undefined;
  let cpu = 24;
  let gpu = 18;
  let memory = 72;
  let battery = 84;
  let activityDayOffset = 0;
  let calendarMonthOffset = 0;
  const calendarPopover = simulator.querySelector<HTMLElement>("[data-sim-calendar-popover]");
  const calendarPopoverTitle = calendarPopover?.querySelector<HTMLElement>("[data-sim-calendar-popover-title]");
  const calendarPopoverSubtitle = calendarPopover?.querySelector<HTMLElement>("[data-sim-calendar-popover-subtitle]");
  const calendarPopoverEvents = calendarPopover?.querySelector<HTMLElement>("[data-sim-calendar-popover-events]");
  const resolutionSecondaryPanel = simulator.querySelector<HTMLElement>("[data-sim-resolution-panel]");
  const resolutionNavigationRow = simulator.querySelector<HTMLButtonElement>("[data-sim-secondary-target=\"display-resolution\"]");
  let resolutionShowTimer: number | undefined;
  let resolutionHideTimer: number | undefined;
  let isResolutionPanelPinned = false;
  const metricHistory: Record<string, number[]> = {
    "network-download": [2.6, 3.8, 2.9, 5.4, 4.1, 6.8, 3.7, 5.2, 4.4, 7.2, 5.8, 8.1, 6.4],
    "network-upload": [0.4, 0.8, 0.5, 1.3, 0.7, 1.8, 1.1, 1.5, 0.9, 2.1, 1.2, 1.7, 1.1],
    "disk-read": [8, 14, 6, 24, 12, 28, 9, 21, 13, 31, 15, 26, 18],
    "disk-write": [2, 5, 2, 8, 3, 11, 4, 7, 3, 13, 4, 9, 5],
    memory: [68, 69, 70, 69, 71, 72, 71, 73, 72, 74, 73, 74, 72],
    battery: [91, 90, 90, 89, 88, 88, 87, 86, 86, 85, 85, 84, 84],
  };

  const hideCalendarPopover = () => {
    if (!calendarPopover || calendarPopover.hidden) return;
    calendarPopover.classList.remove("is-visible");
    calendarPopover.hidden = true;
  };

  const calendarEventsForDay = (day: number) => {
    if (day === 1) {
      return [
        {
          zh: "补充日用品",
          en: "Pick up groceries",
          timeZh: "18:00–18:30",
          timeEn: "6:00–6:30 PM",
          color: "#0a84ff",
        },
        {
          zh: "给植物浇水",
          en: "Water the plants",
          timeZh: "全天",
          timeEn: "All day",
          color: "#d92de3",
        },
      ];
    }

    const eventSets = [
      [
        { zh: "晨间散步", en: "Morning walk", timeZh: "07:30–08:00", timeEn: "7:30–8:00 AM", color: "#0a84ff" },
        { zh: "阅读时间", en: "Reading time", timeZh: "20:30–21:00", timeEn: "8:30–9:00 PM", color: "#ff9f0a" },
      ],
      [
        { zh: "喝水休息", en: "Water break", timeZh: "10:30", timeEn: "10:30 AM", color: "#bf5af2" },
        { zh: "锻炼", en: "Workout", timeZh: "18:30–19:00", timeEn: "6:30–7:00 PM", color: "#30d158" },
        { zh: "给家人打电话", en: "Call family", timeZh: "20:00–20:30", timeEn: "8:00–8:30 PM", color: "#ff375f" },
      ],
      [
        { zh: "整理房间", en: "Tidy up", timeZh: "10:00–10:30", timeEn: "10:00–10:30 AM", color: "#64d2ff" },
      ],
    ];
    return eventSets[day % eventSets.length];
  };

  const positionCalendarPopover = (cell: HTMLElement) => {
    if (!calendarPopover) return;

    const showcaseRect = simulator.getBoundingClientRect();
    const cellRect = cell.getBoundingClientRect();
    const popoverWidth = calendarPopover.offsetWidth || 230;
    const gap = 10;
    let left = cellRect.left - showcaseRect.left + cellRect.width / 2 - popoverWidth / 2;
    const top = cellRect.bottom - showcaseRect.top + gap;

    left = clamp(
      left,
      8 - showcaseRect.left,
      window.innerWidth - 8 - showcaseRect.left - popoverWidth,
    );
    calendarPopover.dataset.side = "over";
    calendarPopover.style.left = `${left}px`;
    calendarPopover.style.top = `${top}px`;
    calendarPopover.style.setProperty(
      "--sim-popover-arrow-offset",
      `${clamp(cellRect.left - showcaseRect.left + cellRect.width / 2 - left - 12, 8, popoverWidth - 32)}px`,
    );
  };

  const showCalendarPopover = (cell: HTMLButtonElement) => {
    if (!calendarPopover || !calendarPopoverTitle || !calendarPopoverSubtitle || !calendarPopoverEvents) return;
    if (!cell.classList.contains("has-events") || !cell.dataset.simCalendarDate) {
      hideCalendarPopover();
      return;
    }

    const timestamp = Number(cell.dataset.simCalendarDate);
    if (!Number.isFinite(timestamp)) {
      hideCalendarPopover();
      return;
    }
    const date = new Date(timestamp);
    const day = date.getDate();
    calendarPopoverTitle.textContent = new Intl.DateTimeFormat(
      currentLanguage() === "en" ? "en-US" : "zh-CN",
      { year: "numeric", month: "short", day: "numeric" },
    ).format(date);
    calendarPopoverSubtitle.textContent = localized(
      `${lunarLabelForDate(date)}${[0, 6].includes(date.getDay()) ? " · 周末" : ""}`,
      [0, 6].includes(date.getDay()) ? "Weekend" : "Scheduled events",
    );

    calendarPopoverEvents.replaceChildren();
    for (const event of calendarEventsForDay(day).slice(0, 6)) {
      const row = document.createElement("div");
      row.className = "sim-calendar-popover-event";
      const dot = document.createElement("i");
      dot.style.setProperty("--event-color", event.color);
      const title = document.createElement("strong");
      title.textContent = currentLanguage() === "en" ? event.en : event.zh;
      const time = document.createElement("time");
      time.textContent = currentLanguage() === "en" ? event.timeEn : event.timeZh;
      row.append(dot, title, time);
      calendarPopoverEvents.append(row);
    }

    simulator.querySelectorAll("[data-sim-calendar-cell]").forEach((calendarCell) => {
      calendarCell.classList.toggle("is-selected", calendarCell === cell);
    });
    calendarPopover.hidden = false;
    positionCalendarPopover(cell);
    requestAnimationFrame(() => calendarPopover.classList.add("is-visible"));
  };

  const clearResolutionTimers = () => {
    if (resolutionShowTimer !== undefined) window.clearTimeout(resolutionShowTimer);
    if (resolutionHideTimer !== undefined) window.clearTimeout(resolutionHideTimer);
    resolutionShowTimer = undefined;
    resolutionHideTimer = undefined;
  };

  const positionResolutionSecondaryPanel = () => {
    if (!resolutionSecondaryPanel || !resolutionNavigationRow) return;

    const showcaseRect = simulator.getBoundingClientRect();
    const rowRect = resolutionNavigationRow.getBoundingClientRect();
    const panelWidth = resolutionSecondaryPanel.offsetWidth || 216;
    const panelHeight = resolutionSecondaryPanel.offsetHeight || 220;
    const gap = 10;
    let side: "right" | "left" | "inline" = "right";
    let left = rowRect.right - showcaseRect.left + gap;

    if (rowRect.right + gap + panelWidth > window.innerWidth - 8) {
      if (rowRect.left - gap - panelWidth >= 8) {
        side = "left";
        left = rowRect.left - showcaseRect.left - gap - panelWidth;
      } else {
        side = "inline";
        left = Math.max(6, showcaseRect.width - panelWidth - 6);
      }
    }

    const maximumTop = window.innerHeight - showcaseRect.top - panelHeight - 8;
    const top = Math.max(8 - showcaseRect.top, Math.min(rowRect.top - showcaseRect.top, maximumTop));
    resolutionSecondaryPanel.dataset.side = side;
    resolutionSecondaryPanel.style.left = `${left}px`;
    resolutionSecondaryPanel.style.top = `${top}px`;
  };

  const hideResolutionSecondaryPanel = (clearSelection = false) => {
    clearResolutionTimers();
    if (!resolutionSecondaryPanel) return;

    resolutionSecondaryPanel.classList.remove("is-visible");
    resolutionSecondaryPanel.hidden = true;
    if (clearSelection && resolutionNavigationRow) {
      isResolutionPanelPinned = false;
      resolutionNavigationRow.classList.remove("is-selected");
      resolutionNavigationRow.setAttribute("aria-pressed", "false");
    }
  };

  const showResolutionSecondaryPanel = (pin = false) => {
    if (!resolutionSecondaryPanel || !resolutionNavigationRow) return;

    clearResolutionTimers();
    if (pin) {
      isResolutionPanelPinned = true;
      resolutionNavigationRow.classList.add("is-selected");
      resolutionNavigationRow.setAttribute("aria-pressed", "true");
    }
    resolutionSecondaryPanel.hidden = false;
    positionResolutionSecondaryPanel();
    requestAnimationFrame(() => resolutionSecondaryPanel.classList.add("is-visible"));
  };

  const scheduleResolutionPanelShow = () => {
    if (resolutionHideTimer !== undefined) window.clearTimeout(resolutionHideTimer);
    resolutionHideTimer = undefined;
    if (resolutionSecondaryPanel && !resolutionSecondaryPanel.hidden) return;
    if (resolutionShowTimer !== undefined) window.clearTimeout(resolutionShowTimer);
    resolutionShowTimer = window.setTimeout(() => showResolutionSecondaryPanel(), 60);
  };

  const scheduleResolutionPanelHide = () => {
    if (isResolutionPanelPinned) return;
    if (resolutionShowTimer !== undefined) window.clearTimeout(resolutionShowTimer);
    resolutionShowTimer = undefined;
    if (resolutionHideTimer !== undefined) window.clearTimeout(resolutionHideTimer);
    resolutionHideTimer = window.setTimeout(() => hideResolutionSecondaryPanel(), 160);
  };

  const updateLocalizedAttributes = () => {
    const language = currentLanguage();

    simulator.querySelectorAll<HTMLElement>("[data-aria-zh][data-aria-en]").forEach((element) => {
      const value = language === "en" ? element.dataset.ariaEn : element.dataset.ariaZh;
      if (value) element.setAttribute("aria-label", value);
    });

    simulator.querySelectorAll<HTMLElement>("[data-title-zh][data-title-en]").forEach((element) => {
      const value = language === "en" ? element.dataset.titleEn : element.dataset.titleZh;
      if (value) element.setAttribute("title", value);
    });
  };

  const selectView = (selectedView: string) => {
    hideCalendarPopover();
    if (selectedView !== "controls") hideResolutionSecondaryPanel(true);
    for (const tab of tabs) {
      const isSelected = tab.dataset.simTab === selectedView;
      tab.classList.toggle("is-selected", isSelected);
      tab.setAttribute("aria-selected", String(isSelected));
    }

    for (const view of views) {
      const isSelected = view.dataset.simView === selectedView;
      view.hidden = !isSelected;
      view.classList.toggle("is-visible", isSelected);
      if (isSelected) view.scrollTop = 0;
    }
  };

  const showToast = (zh: string, en: string) => {
    if (!toast) return;

    window.clearTimeout(toastTimer);
    setLocalizedText(toast, zh, en);
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => {
      toast.classList.remove("is-visible");
    }, 1600);
  };

  const updateMetric = (metric: string, value: number, digits = 0) => {
    const card = simulator.querySelector<HTMLElement>(`[data-sim-metric="${metric}"]`);
    const valueElement = card?.querySelector<HTMLElement>("[data-sim-value]");
    if (valueElement) valueElement.textContent = value.toFixed(digits);

    card?.querySelectorAll<HTMLElement>(".sim-spark-bars i").forEach((bar, index, bars) => {
      const wave = Math.sin((Date.now() / 780) + index * 0.72) * 0.16;
      const normalized = clamp((value / 100) + wave + randomBetween(-0.12, 0.12), 0.12, 0.96);
      bar.style.transform = `scaleY(${normalized.toFixed(2)})`;
      bar.style.opacity = String(0.52 + (index / bars.length) * 0.36);
    });
  };

  const appendMetricSample = (series: string, value: number) => {
    const samples = metricHistory[series];
    if (!samples) return;
    samples.push(Math.max(value, 0));
    if (samples.length > 13) samples.shift();
  };

  const renderMetricChart = (series: string, fixedMaximum?: number) => {
    const samples = metricHistory[series];
    if (!samples?.length) return;
    const maximum = Math.max(fixedMaximum ?? Math.max(...samples), 0.001);
    const points = samples.map((sample, index) => {
      const normalized = clamp(sample / maximum, 0, 1);
      const ratio = fixedMaximum ? normalized : Math.sqrt(normalized);
      const x = 120 * index / Math.max(samples.length - 1, 1);
      const y = 21 - ratio * 20;
      return `${x.toFixed(1)} ${y.toFixed(1)}`;
    });
    const linePath = `M ${points.join(" L ")}`;
    const areaPath = `M 0 22 L ${points.join(" L ")} L 120 22 Z`;
    simulator.querySelector<SVGPathElement>(`[data-sim-chart-line="${series}"]`)?.setAttribute("d", linePath);
    simulator.querySelector<SVGPathElement>(`[data-sim-chart-area="${series}"]`)?.setAttribute("d", areaPath);
  };

  const updateActivityStats = () => {
    const historicalFactor = Math.max(0.42, 1 + activityDayOffset * 0.09);
    const keys = Math.round((8426 + randomBetween(-120, 180)) * historicalFactor);
    const clicks = Math.round((2184 + randomBetween(-60, 90)) * historicalFactor);
    const scrolls = Math.round((1079 + randomBetween(-40, 65)) * historicalFactor);
    const minutes = Math.round((276 + randomBetween(-8, 12)) * historicalFactor);
    const formatter = new Intl.NumberFormat(currentLanguage() === "en" ? "en-US" : "zh-CN");

    const keysElement = simulator.querySelector<HTMLElement>("[data-sim-activity-keys]");
    const clicksElement = simulator.querySelector<HTMLElement>("[data-sim-activity-clicks]");
    const scrollsElement = simulator.querySelector<HTMLElement>("[data-sim-activity-scrolls]");
    const timeElement = simulator.querySelector<HTMLElement>("[data-sim-activity-time]");
    if (keysElement) keysElement.textContent = formatter.format(keys);
    if (clicksElement) clicksElement.textContent = formatter.format(clicks);
    if (scrollsElement) scrollsElement.textContent = formatter.format(scrolls);
    if (timeElement) {
      const hours = Math.floor(minutes / 60);
      const remainingMinutes = minutes % 60;
      timeElement.textContent = localized(
        `${hours}小时 ${remainingMinutes}分`,
        `${hours}h ${remainingMinutes}m`,
      );
    }
  };

  const updateActivityDate = () => {
    const label = simulator.querySelector<HTMLElement>("[data-sim-activity-date]");
    if (!label) return;

    if (activityDayOffset === 0) {
      label.textContent = localized("今天", "Today");
    } else if (activityDayOffset === -1) {
      label.textContent = localized("昨天", "Yesterday");
    } else {
      const date = new Date();
      date.setDate(date.getDate() + activityDayOffset);
      label.textContent = new Intl.DateTimeFormat(
        currentLanguage() === "en" ? "en-US" : "zh-CN",
        { month: "short", day: "numeric" },
      ).format(date);
    }

    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-activity-day]").forEach((button) => {
      const direction = Number(button.dataset.simActivityDay ?? 0);
      button.disabled = direction > 0 && activityDayOffset === 0;
    });
    updateActivityStats();
  };

  const renderCalendar = () => {
    hideCalendarPopover();
    const target = new Date();
    target.setDate(1);
    target.setMonth(target.getMonth() + calendarMonthOffset);
    const year = target.getFullYear();
    const month = target.getMonth();
    const mondayFirstOffset = (new Date(year, month, 1).getDay() + 6) % 7;
    const today = new Date();

    const titleZh = simulator.querySelector<HTMLElement>("[data-sim-calendar-title-zh]");
    const titleEn = simulator.querySelector<HTMLElement>("[data-sim-calendar-title-en]");
    if (titleZh) {
      titleZh.textContent = new Intl.DateTimeFormat("zh-CN", {
        year: "numeric",
        month: "long",
      }).format(target);
    }
    if (titleEn) {
      titleEn.textContent = new Intl.DateTimeFormat("en-US", {
        year: "numeric",
        month: "long",
      }).format(target);
    }

    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-cell]").forEach((cell, index) => {
      const date = new Date(year, month, index - mondayFirstOffset + 1);
      const day = date.getDate();
      const isDisplayedMonth = date.getMonth() === month;
      const isToday = date.toDateString() === today.toDateString();
      const number = cell.querySelector<HTMLElement>("b");
      const subtitle = cell.querySelector<HTMLElement>("small");
      const eventDots = cell.querySelector<HTMLElement>(".sim-calendar-event-dots");

      cell.disabled = false;
      cell.classList.remove("is-empty");
      cell.classList.toggle("is-outside", !isDisplayedMonth);
      cell.classList.toggle("is-today", isToday);
      const hasEvents = isDisplayedMonth && calendarEventDays.has(day);
      cell.classList.toggle("has-events", hasEvents);
      cell.classList.remove("is-selected");
      cell.dataset.simCalendarDay = String(day);
      cell.dataset.simCalendarDate = String(date.getTime());
      if (number) number.textContent = String(day);
      if (subtitle) {
        subtitle.textContent = isToday
          ? localized("今天", "Today")
          : localized(
            lunarLabelForDate(date),
            `D${((day + 14) % 30) + 1}`,
          );
      }
      eventDots?.replaceChildren();
      if (hasEvents && eventDots) {
        for (const event of calendarEventsForDay(day).slice(0, 3)) {
          const dot = document.createElement("i");
          dot.style.setProperty("--event-color", event.color);
          eventDots.append(dot);
        }
      }
      cell.setAttribute(
        "aria-label",
        new Intl.DateTimeFormat(
          currentLanguage() === "en" ? "en-US" : "zh-CN",
          { year: "numeric", month: "long", day: "numeric" },
        ).format(date),
      );
    });
  };

  const updateActionLabels = () => {
    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-action]").forEach((button) => {
      if (button.dataset.simBusy === "true") return;
      button.textContent = currentLanguage() === "en"
        ? button.dataset.actionEn ?? "Run"
        : button.dataset.actionZh ?? "操作";
    });
  };

  const synchronizeAppearance = () => {
    const appearanceToggle = simulator.querySelector<HTMLButtonElement>('[data-sim-setting="appearance"]');
    const isDark = root.dataset.theme === "dark";
    simulator.dataset.previewTheme = isDark ? "dark" : "light";
    appearanceToggle?.setAttribute("aria-checked", String(isDark));
    appearanceToggle?.classList.toggle("is-on", isDark);
  };

  const updateSimulatedData = () => {
    if (document.hidden) return;

    cpu = clamp(cpu + randomBetween(-7, 8), 12, 68);
    gpu = clamp(gpu + randomBetween(-6, 7), 7, 54);
    memory = clamp(memory + randomBetween(-1.8, 1.8), 64, 83);
    battery = clamp(battery - randomBetween(0, 0.015), 78, 84);

    updateMetric("cpu", cpu);
    updateMetric("gpu", gpu);
    updateMetric("memory", memory);
    updateMetric("battery", battery);

    const cpuCard = simulator.querySelector<HTMLElement>('[data-sim-metric="cpu"]');
    const gpuCard = simulator.querySelector<HTMLElement>('[data-sim-metric="gpu"]');
    const cpuTemp = cpuCard?.querySelector<HTMLElement>("[data-sim-temp]");
    const gpuTemp = gpuCard?.querySelector<HTMLElement>("[data-sim-temp]");
    if (cpuTemp) cpuTemp.textContent = `${Math.round(46 + cpu * 0.22)}°C`;
    if (gpuTemp) gpuTemp.textContent = `${Math.round(43 + gpu * 0.21)}°C`;

    const cpuFootnote = cpuCard?.querySelector<HTMLElement>("[data-sim-footnote]");
    if (cpuFootnote) {
      const load = (0.72 + cpu * 0.029).toFixed(2);
      const power = (1.2 + cpu * 0.067).toFixed(1);
      setLocalizedText(cpuFootnote,
        `负载 ${load} · 功率 ${power} W`,
        `Load ${load} · Power ${power} W`,
      );
    }

    const network = simulator.querySelector<HTMLElement>('[data-sim-metric="network"]');
    const download = randomBetween(1.8, 8.6);
    const upload = randomBetween(0.3, 2.4);
    const networkValue = network?.querySelector<HTMLElement>("[data-sim-value]");
    const downloadValue = network?.querySelector<HTMLElement>("[data-sim-down]");
    const uploadValue = network?.querySelector<HTMLElement>("[data-sim-up]");
    if (networkValue) networkValue.textContent = (download + upload).toFixed(1);
    if (downloadValue) downloadValue.textContent = `${download.toFixed(1)} MB/s`;
    if (uploadValue) uploadValue.textContent = `${upload.toFixed(1)} MB/s`;
    appendMetricSample("network-download", download);
    appendMetricSample("network-upload", upload);
    renderMetricChart("network-download");
    renderMetricChart("network-upload");

    const disk = simulator.querySelector<HTMLElement>('[data-sim-metric="disk"]');
    const diskAvailable = clamp(41 + randomBetween(-0.4, 0.4), 40.4, 41.6);
    const diskRead = randomBetween(5.5, 32);
    const diskWrite = randomBetween(1.2, 13);
    const diskValue = disk?.querySelector<HTMLElement>("[data-sim-value]");
    const diskReadValue = disk?.querySelector<HTMLElement>("[data-sim-disk-read]");
    const diskWriteValue = disk?.querySelector<HTMLElement>("[data-sim-disk-write]");
    if (diskValue) diskValue.textContent = diskAvailable.toFixed(1);
    if (diskReadValue) diskReadValue.textContent = `${diskRead.toFixed(0)} MB/s`;
    if (diskWriteValue) diskWriteValue.textContent = `${diskWrite.toFixed(1)} MB/s`;
    appendMetricSample("disk-read", diskRead);
    appendMetricSample("disk-write", diskWrite);
    renderMetricChart("disk-read");
    renderMetricChart("disk-write");

    simulator.querySelectorAll<HTMLElement>('[data-sim-metric="memory"] [data-sim-used]').forEach((memoryUsed) => {
      memoryUsed.textContent = (16 * memory / 100).toFixed(1);
    });
    appendMetricSample("memory", memory);
    renderMetricChart("memory", 100);

    const deviceLevel = simulator.querySelector<HTMLElement>('[data-sim-device-level="mac"]');
    const deviceBar = simulator.querySelector<HTMLElement>('[data-sim-device-bar="mac"]');
    if (deviceLevel) deviceLevel.textContent = `${Math.round(battery)}%`;
    if (deviceBar) deviceBar.style.width = `${battery.toFixed(1)}%`;
    appendMetricSample("battery", battery);
    renderMetricChart("battery", 100);

    simulator.querySelectorAll<HTMLElement>("[data-sim-process-cpu]").forEach((process, index) => {
      const factor = [0.16, 0.12, 0.07][index] ?? 0.05;
      process.textContent = `${Math.max(0.8, cpu * factor + randomBetween(-1.2, 1.2)).toFixed(1)}%`;
    });

    if (activityDayOffset === 0) updateActivityStats();
  };

  for (const tab of tabs) {
    tab.addEventListener("click", () => {
      const selectedView = tab.dataset.simTab;
      if (selectedView) selectView(selectedView);
    });
  }

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-disclosure]").forEach((button) => {
    button.addEventListener("click", () => {
      const item = button.closest<HTMLElement>(".sim-feature-item");
      const detail = item?.querySelector<HTMLElement>("[data-sim-disclosure-detail]");
      if (!item || !detail) return;

      const shouldOpen = button.getAttribute("aria-expanded") !== "true";
      simulator.querySelectorAll<HTMLButtonElement>("[data-sim-disclosure]").forEach((otherButton) => {
        const otherItem = otherButton.closest<HTMLElement>(".sim-feature-item");
        const otherDetail = otherItem?.querySelector<HTMLElement>("[data-sim-disclosure-detail]");
        const isCurrent = otherButton === button && shouldOpen;
        otherButton.setAttribute("aria-expanded", String(isCurrent));
        otherItem?.classList.toggle("is-expanded", isCurrent);
        if (otherDetail) otherDetail.hidden = !isCurrent;
      });

      if (item.dataset.simPlugin !== "display-resolution" || !shouldOpen) {
        hideResolutionSecondaryPanel(true);
      }
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-setting]").forEach((button) => {
    button.addEventListener("click", () => {
      const isOn = button.getAttribute("aria-checked") !== "true";
      button.setAttribute("aria-checked", String(isOn));
      button.classList.toggle("is-on", isOn);

      if (button.dataset.simSetting === "appearance") {
        const theme = isOn ? "dark" : "light";
        root.dataset.theme = theme;
        localStorage.setItem("mactools-theme", theme);
        synchronizeAppearance();
      }
    });
  });

  simulator.querySelectorAll<HTMLInputElement>("[data-sim-range]").forEach((range) => {
    const updateRangeProgress = () => {
      const minimum = Number(range.min);
      const maximum = Number(range.max);
      const value = Number(range.value);
      const progress = maximum > minimum
        ? (value - minimum) / (maximum - minimum) * 100
        : 0;
      range.style.setProperty("--sim-range-progress", `${clamp(progress, 0, 100)}%`);
    };

    updateRangeProgress();
    range.addEventListener("input", () => {
      const value = range.closest(".sim-feature-detail")?.querySelector<HTMLElement>("[data-sim-range-value]");
      if (value) value.textContent = `${range.value}${range.dataset.simRangeUnit ?? ""}`;
      updateRangeProgress();
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-detail-switch]").forEach((button) => {
    button.addEventListener("click", () => {
      const isOn = button.getAttribute("aria-checked") !== "true";
      button.setAttribute("aria-checked", String(isOn));
      button.classList.toggle("is-on", isOn);
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-detail-option]").forEach((button) => {
    button.addEventListener("click", () => {
      const mode = button.dataset.simDetailMode;
      if (button.dataset.simSecondaryTarget === "display-resolution") {
        if (isResolutionPanelPinned && button.classList.contains("is-selected")) {
          hideResolutionSecondaryPanel(true);
        } else {
          showResolutionSecondaryPanel(true);
        }
        return;
      }

      if (mode === "select" || mode === "navigation") {
        if (button.classList.contains("is-selected")) return;
        button.closest(".sim-detail-list")
          ?.querySelectorAll<HTMLButtonElement>(`[data-sim-detail-mode="${mode}"]`)
          .forEach((option) => {
            const isSelected = option === button;
            option.classList.toggle("is-selected", isSelected);
            option.setAttribute("aria-pressed", String(isSelected));
          });
      }

      const zh = button.querySelector<HTMLElement>("[data-i18n-zh]")?.textContent?.trim();
      const en = button.querySelector<HTMLElement>("[data-i18n-en]")?.textContent?.trim();
      if (zh && en) {
        showToast(
          mode === "action" ? `${zh} · 操作仅为模拟` : `${zh} · 已选择`,
          mode === "action" ? `${en} · action simulated` : `${en} · selected`,
        );
      }
    });
  });

  resolutionNavigationRow?.addEventListener("mouseenter", scheduleResolutionPanelShow);
  resolutionNavigationRow?.addEventListener("mouseleave", scheduleResolutionPanelHide);
  resolutionNavigationRow?.addEventListener("focus", () => showResolutionSecondaryPanel());
  resolutionNavigationRow?.addEventListener("blur", scheduleResolutionPanelHide);
  resolutionSecondaryPanel?.addEventListener("mouseenter", () => {
    if (resolutionHideTimer !== undefined) window.clearTimeout(resolutionHideTimer);
    resolutionHideTimer = undefined;
  });
  resolutionSecondaryPanel?.addEventListener("mouseleave", scheduleResolutionPanelHide);
  resolutionSecondaryPanel?.addEventListener("focusin", () => {
    if (resolutionHideTimer !== undefined) window.clearTimeout(resolutionHideTimer);
    resolutionHideTimer = undefined;
  });
  resolutionSecondaryPanel?.addEventListener("focusout", scheduleResolutionPanelHide);

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-resolution-option]").forEach((button) => {
    button.addEventListener("click", () => {
      if (button.classList.contains("is-selected")) return;

      simulator.querySelectorAll<HTMLButtonElement>("[data-sim-resolution-option]").forEach((option) => {
        const isSelected = option === button;
        option.classList.toggle("is-selected", isSelected);
        option.setAttribute("aria-checked", String(isSelected));
      });

      const resolution = button.dataset.simResolutionValue?.replace("x", " × ");
      const summary = resolutionNavigationRow?.querySelector<HTMLElement>(".sim-detail-row-copy small");
      if (resolution && summary) summary.textContent = resolution;
      if (resolution) {
        showToast(`分辨率 ${resolution} · 已选择`, `Resolution ${resolution} · selected`);
      }
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-action]").forEach((button) => {
    button.addEventListener("click", () => {
      button.dataset.simBusy = "true";
      button.disabled = true;
      setLocalizedText(button, "处理中", "Working");

      window.setTimeout(() => {
        setLocalizedText(button, "完成", "Done");
        showToast(`${button.dataset.pluginNameZh ?? "插件"} · 已完成（模拟）`, `${button.dataset.pluginNameEn ?? "Plugin"} · completed (simulation)`);

        window.setTimeout(() => {
          clearLocalizedText(button);
          button.dataset.simBusy = "false";
          button.disabled = false;
          updateActionLabels();
        }, 900);
      }, 620);
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-activity-day]").forEach((button) => {
    button.addEventListener("click", () => {
      const direction = Number(button.dataset.simActivityDay ?? 0);
      activityDayOffset = Math.min(0, Math.max(-14, activityDayOffset + direction));
      updateActivityDate();
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-nav]").forEach((button) => {
    button.addEventListener("click", () => {
      hideCalendarPopover();
      const action = button.dataset.simCalendarNav;
      if (action === "previous") calendarMonthOffset -= 1;
      if (action === "next") calendarMonthOffset += 1;
      if (action === "today") calendarMonthOffset = 0;
      renderCalendar();
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-cell]").forEach((button) => {
    button.addEventListener("mouseenter", () => showCalendarPopover(button));
    button.addEventListener("mouseleave", hideCalendarPopover);
    button.addEventListener("focus", () => showCalendarPopover(button));
    button.addEventListener("blur", hideCalendarPopover);
    button.addEventListener("click", () => {
      if (!button.dataset.simCalendarDay) return;
      simulator.querySelectorAll("[data-sim-calendar-cell]").forEach((cell) => {
        cell.classList.toggle("is-selected", cell === button);
      });
    });
  });

  simulator.addEventListener("wheel", (event) => {
    if (event.ctrlKey) return;

    const target = event.target;
    if (!(target instanceof Element)) return;

    const secondaryScroller = target.closest<HTMLElement>("[data-sim-resolution-panel]");
    const isOverMainPanel = target.closest(".sim-panel") !== null;
    const scroller = secondaryScroller
      ?? (isOverMainPanel
        ? simulator.querySelector<HTMLElement>(".sim-panel-view.is-visible:not([hidden])")
        : null);
    if (!scroller) return;

    event.preventDefault();
    const multiplier = event.deltaMode === 1
      ? 16
      : event.deltaMode === 2
        ? scroller.clientHeight
        : 1;
    scroller.scrollTop += event.deltaY * multiplier;
  }, { passive: false });

  views.forEach((view) => view.addEventListener("scroll", () => {
    hideCalendarPopover();
    hideResolutionSecondaryPanel(true);
  }, { passive: true }));
  window.addEventListener("resize", () => {
    hideCalendarPopover();
    hideResolutionSecondaryPanel(true);
  }, { passive: true });

  const rootObserver = new MutationObserver((records) => {
    updateLocalizedAttributes();
    updateActionLabels();
    updateActivityDate();
    renderCalendar();

    if (records.some((record) => record.attributeName === "data-theme")) {
      synchronizeAppearance();
    }
  });
  rootObserver.observe(root, { attributes: true, attributeFilter: ["data-lang", "data-theme"] });

  synchronizeAppearance();
  updateLocalizedAttributes();
  updateActionLabels();
  updateActivityDate();
  renderCalendar();
  updateSimulatedData();
  window.setInterval(updateSimulatedData, 1_650);
});
