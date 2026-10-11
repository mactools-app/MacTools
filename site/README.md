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
