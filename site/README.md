# MacTools website

The Astro website consumes checked-in data generated from `Plugins/*/plugin.json` and the repository-local `Localizable.xcstrings` files referenced by those manifests; it never fetches the production plugin catalog during a build.

After changing a plugin manifest, a referenced localization string, or a Marketplace asset, run:

```bash
npm run generate:plugins
npm run check:generated-plugins
npm run build
npm test
```

The website consumes the committed `src/generated/plugins.json` and
`src/generated/actions.json` files. Checksum-named assets in
`public/generated/plugin-assets/` are committed alongside them. CI rejects
stale output.

Navigation controls are loaded by `BaseLayout` on every page. Existing settings
preview models remain in use, with generic controls only for plugins without a
model. Catalog search consumes discovery metadata and static action descriptors
from those generated files. Action matches are grouped under their owning plugin;
dynamic providers remain templates on plugin pages. Plugin pages disclose declared
application and executable prerequisites without checking the visitor's Mac.

`npm test` checks search and control behavior (including unavailable storage),
generated action destinations and prerequisites, shared scripts on the built pages,
and the Fan Control preset and slider preview.

## Language behavior

The website supports English (`en`) and Simplified Chinese (`zh`, rendered as
`zh-CN`). An explicit language choice is stored in `mactools-lang`. Without a
valid saved choice, the first supported language in `navigator.languages` wins;
regional English and Chinese tags map to the corresponding supported language.
Other languages fall back to English. Chinese regional tags currently use the
Simplified Chinese translation.

`BaseLayout` initializes language in the head before the body is parsed, using
the same functions as the navigation controls. Titles, descriptions, keywords,
Open Graph and Twitter metadata, structured data, accessible labels, tooltips,
search placeholders, and select options follow that language. Page metadata is
authored as English/Chinese pairs; plugin and action translations come from the
existing generated catalogs. Keep schema identifiers in the catalogs and
translate their visible labels in `src/lib/plugin-presentation.ts`.

Storage failures leave automatic detection and the current page's controls
working. A selection cannot persist across documents when browser storage is
unavailable. Normal links load new documents; no client router is installed.
When Back or Forward restores a cached document, `pageshow` reapplies the saved
preferences so its content and metadata follow the latest language choice.
The site keeps one URL per page. Without JavaScript, including social crawlers
that do not execute scripts, the static document and metadata default to Chinese.
Language-specific social previews would require separately addressable locale
URLs; a browser-only preference is unavailable to those crawlers.

## Localization verification

Run `npm run build && npm test` after changing shared language behavior or page
metadata. The focused tests execute the actual built head initialization on every
HTML route before body controls, check title/social metadata consistency and
structured data, and cover language ordering, unsupported locales, saved choices,
reload initialization, cached history restoration, and blocked storage.
`npm run check:generated-plugins` checks that catalog authoring inputs still match
the committed output.

The October 2, 2026 audit reproduced the production title mismatch in Chromium
and WebKit: the home, catalog, about, and privacy pages showed English body copy
with Chinese titles and descriptions; plugin and action pages kept English
metadata when Chinese was selected. The fix was verified locally in both engines
on all 202 HTML routes (4 main pages, 63 plugin pages, 135 action pages), in both
languages, with no page errors. Browser checks also covered navigation, reload,
history, all 47 settings preview panels, language switching during action feedback,
regional and unsupported language preferences,
and unavailable storage. The native Safari application chrome was not automated.

The October 3 follow-up verified Chromium history restoration with the
back/forward cache explicitly enabled and `pageshow.persisted` confirmed, plus
fresh history navigation in WebKit. Cached pages now reapply the saved language
and theme. The Apple Shortcuts privacy table uses automation terminology for
shortcut names and folders.

Chinese feature-chip UI evidence: [production before](evidence/feature-localization-before.png)
and [local fixed build](evidence/feature-localization-after.png). The screenshot
comparison covers visible copy; the browser title was verified through
`document.title`, since page screenshots do not capture browser chrome.
