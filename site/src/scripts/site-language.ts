export type SiteLanguage = "zh" | "en";

export function resolveLanguage(stored: string | null, languages: readonly string[]): SiteLanguage {
  if (stored === "zh" || stored === "en") return stored;
  for (const language of languages) {
    const primary = language.toLowerCase().split(/[-_]/)[0];
    if (primary === "zh" || primary === "en") return primary;
  }
  return "en";
}

// Keep this function self-contained: the layout also runs it before the body is parsed.
export function applyLanguage(language: SiteLanguage) {
  const root = document.documentElement;
  if (root.dataset.lang !== language) root.dataset.lang = language;
  const htmlLanguage = language === "zh" ? "zh-CN" : "en";
  if (root.lang !== htmlLanguage) root.lang = htmlLanguage;

  for (const attribute of ["content", "aria-label", "title", "placeholder", "alt"]) {
    document.querySelectorAll<HTMLElement>(`[data-${attribute}-zh][data-${attribute}-en]`).forEach((element) => {
      element.setAttribute(attribute, element.getAttribute(`data-${attribute}-${language}`) ?? "");
    });
  }
  for (const attribute of ["text", "option"]) {
    document.querySelectorAll<HTMLElement>(`[data-${attribute}-zh][data-${attribute}-en]`).forEach((element) => {
      element.textContent = element.getAttribute(`data-${attribute}-${language}`) ?? "";
    });
  }
}

// Storage failures must not prevent language detection or metadata from being applied.
export function initializePreferences(resolve: typeof resolveLanguage, apply: typeof applyLanguage) {
  const read = (key: string) => {
    try { return localStorage.getItem(key); } catch { return null; }
  };
  const root = document.documentElement;
  const theme = read("mactools-theme");
  root.dataset.theme = theme === "light" || theme === "dark"
    ? theme
    : window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  const languages = navigator.languages?.length ? navigator.languages : [navigator.language];
  apply(resolve(read("mactools-lang"), languages));
}

// Transient feedback also follows language changes until its original markup returns.
export function setLocalizedText(element: HTMLElement, zh: string, en: string) {
  element.dataset.textZh = zh;
  element.dataset.textEn = en;
  element.textContent = document.documentElement.dataset.lang === "en" ? en : zh;
}

export function clearLocalizedText(element: HTMLElement) {
  delete element.dataset.textZh;
  delete element.dataset.textEn;
}
