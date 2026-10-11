import { localizedPluginText, type Plugin } from "./plugins";

type LocalizedText = { zh: string; en: string };
type LocalizedValue = Record<string, string | null | undefined>;

export type StaticActionEntry = {
  pluginID: string;
  providerID: string;
  route: string;
  action: {
    id: string;
    title?: LocalizedValue;
    description?: LocalizedValue;
    keywords?: string[];
  };
};

export type ActionSearchTerms = {
  titleTerms: string;
  keywordTerms: string;
  descriptionTerms: string;
};

export type SearchAction = ActionSearchTerms & {
  id: string;
  providerID: string;
  route: string;
  title: LocalizedText;
  description: LocalizedText;
};

type Discovery = {
  keywords?: string[];
  localizedSynonyms?: Record<string, string[]>;
  useCases?: Array<{ title?: LocalizedValue }>;
};

export function normalizeSearch(value: string): string {
  return value.trim().toLowerCase();
}

function terms(values: Array<string | null | undefined>): string {
  return normalizeSearch(values.filter((value) => value?.trim()).join(" "));
}

function localizedText(value: LocalizedValue | undefined, fallback = ""): LocalizedText {
  const first = (locales: string[]) => locales.map((locale) => value?.[locale]?.trim()).find(Boolean);
  const zh = first(["zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW"]);
  const en = first(["en", "en-US", "en-GB"]);
  return { zh: zh || en || fallback, en: en || zh || fallback };
}

export function buildPluginSearch(plugins: Plugin[], entries: StaticActionEntry[]) {
  const search = new Map<string, { terms: string; actions: SearchAction[] }>();
  for (const plugin of plugins) {
    const text = localizedPluginText(plugin);
    const discovery = plugin.product?.discovery as Discovery | undefined;
    search.set(plugin.id, {
      terms: terms([
        text.zh.displayName, text.zh.summary, text.en.displayName, text.en.summary,
        ...(discovery?.keywords ?? []),
        ...Object.values(discovery?.localizedSynonyms ?? {}).flat(),
        ...(discovery?.useCases ?? []).flatMap((item) => Object.values(item.title ?? {})),
      ]),
      actions: [],
    });
  }
  for (const entry of entries) {
    const owner = search.get(entry.pluginID);
    if (!owner) continue;
    const title = localizedText(entry.action.title, entry.action.id);
    const description = localizedText(entry.action.description);
    owner.actions.push({
      id: `${entry.providerID}/${entry.action.id}`,
      providerID: entry.providerID,
      route: entry.route,
      title,
      description,
      titleTerms: terms([...Object.values(entry.action.title ?? {}), title.zh, title.en]),
      keywordTerms: terms(entry.action.keywords ?? []),
      descriptionTerms: terms(Object.values(entry.action.description ?? {})),
    });
  }
  return search;
}

export function actionMatchRank(action: ActionSearchTerms, query: string): number {
  if (!query) return 0;
  if (action.titleTerms.includes(query)) return 3;
  if (action.keywordTerms.includes(query)) return 2;
  return action.descriptionTerms.includes(query) ? 1 : 0;
}
