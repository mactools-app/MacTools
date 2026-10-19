import catalog from "../../../Sources/Resources/StarterPacks.json";

export type PackText = { zh: string; en: string };
export const packText = (zh: string, en: string): PackText => ({ zh, en });

// The bundled host resource owns pack membership, copy, and stable deep-link IDs.
export const starterPacks = catalog.packs;
export const starterPluginSymbol = (id: string) => catalog.plugins[id as keyof typeof catalog.plugins]?.symbol ?? "puzzlepiece.extension";
export type StarterPack = (typeof starterPacks)[number];
export const packRoute = (id: StarterPack["id"]) => `/packs/${id}`;
export const packAppURL = (id: StarterPack["id"]) => `mactools://app/settings/starter-packs/${id}`;
