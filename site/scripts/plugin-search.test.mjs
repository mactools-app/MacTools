import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';

const site = fileURLToPath(new URL('../', import.meta.url));
const modules = new Map();
function loadSource(path) {
  if (modules.has(path)) return modules.get(path);
  if (path.endsWith('.json')) return JSON.parse(readFileSync(path, 'utf8'));
  const module = { exports: {} };
  const code = ts.transpileModule(readFileSync(path, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  runInNewContext(code, { module, exports: module.exports, require(specifier) {
    const source = specifier.startsWith('@/') ? resolve(site, 'src', specifier.slice(2)) : resolve(dirname(path), specifier);
    return loadSource(source.endsWith('.json') ? source : `${source}.ts`);
  } });
  modules.set(path, module.exports);
  return module.exports;
}
const { buildPluginSearch, actionMatchRank, normalizeSearch } = loadSource(resolve(site, 'src/lib/plugin-search.ts'));
const plugins = JSON.parse(readFileSync(resolve(site, 'src/generated/plugins.json'), 'utf8')).plugins;
const actions = JSON.parse(readFileSync(resolve(site, 'src/generated/actions.json'), 'utf8')).actions;
const search = buildPluginSearch(plugins, actions);

test('task queries discover the owning static action and existing names still match', () => {
  for (const [query, pluginID, actionID] of [
    ['left half', 'window-layouts', 'window-layouts/left-half'],
    ['左半屏', 'window-layouts', 'window-layouts/left-half'],
    ['pause clipboard history', 'clipboard', 'clipboard/pause-collection'],
  ]) {
    const owners = [...search].filter(([, entry]) => entry.terms.includes(query) || entry.actions.some(action => actionMatchRank(action, query)));
    assert.deepEqual(owners.map(([id]) => id), [pluginID]);
    assert.equal(owners[0][1].actions.find(action => actionMatchRank(action, query)).id, actionID);
  }
  for (const term of ['theme', 'dark mode', 'switch the system']) assert.ok(search.get('appearance').terms.includes(term));
});

test('optional discovery and blank translations preserve fallback and action identity', () => {
  const plugin = { id: 'fixture', displayName: 'Base Plugin', summary: 'Base summary', localizedMetadata: { en: { displayName: ' ' } } };
  const enriched = { ...plugin, id: 'enriched', product: { discovery: {
    keywords: ['keyword'], localizedSynonyms: { 'zh-Hans': ['别名'], en: ['alias'] },
    useCases: [{ title: { en: 'Perform a task', 'zh-Hans': '完成任务' } }],
  }, actions: { providers: [{ kind: 'dynamic', dynamicTemplates: [{ id: 'local' }] }] } } };
  const entry = providerID => ({ pluginID: 'fixture', providerID, route: `/plugins/fixture/actions/${providerID}/run/`, action: {
    id: 'run', title: { en: ' ', 'zh-Hans': '运行操作' }, description: { en: 'Run something', 'zh-Hans': '' }, keywords: ['launch'],
  } });
  const index = buildPluginSearch([plugin, enriched], [entry('one'), entry('two'), { ...entry('missing'), pluginID: 'missing' }]);
  assert.ok(index.get('fixture').terms.includes('base plugin'));
  for (const term of ['keyword', '别名', 'alias', 'perform a task', '完成任务']) assert.ok(index.get('enriched').terms.includes(term));
  assert.equal(index.get('enriched').actions.length, 0, 'dynamic templates are not static results');
  const [first, second] = index.get('fixture').actions;
  assert.deepEqual({ ...first.title }, { en: '运行操作', zh: '运行操作' });
  assert.deepEqual({ ...first.description }, { en: 'Run something', zh: 'Run something' });
  assert.notEqual(first.id, second.id);
  assert.notEqual(first.route, second.route);
  assert.equal(actionMatchRank(first, 'base plugin'), 0, 'parent text must not match every action');
  assert.ok(actionMatchRank(first, '运行操作') > actionMatchRank(first, 'launch'));
  assert.ok(actionMatchRank(first, 'launch') > actionMatchRank(first, 'run something'));
  assert.equal(actionMatchRank(first, ''), 0);
  assert.equal(normalizeSearch('  LEFT HALF  '), 'left half');
});

function element(dataset = {}) {
  return { dataset, hidden: false, open: false, textContent: '', children: [], listeners: new Map(),
    classList: { toggle() {} }, addEventListener(name, callback) { this.listeners.set(name, callback); }, setAttribute() {},
    append(child) {
      if (child.parent) child.parent.children = child.parent.children.filter(item => item !== child);
      this.children.push(child); child.parent = this;
    },
    querySelector(selector) { return this.selectors?.[selector]?.[0] ?? null; },
    querySelectorAll(selector) { return this.selectors?.[selector] ?? []; },
    closest() { return null; }, focus() { this.focused = true; },
  };
}
function runCatalog() {
  const root = element({ lang: 'en' });
  const input = element({ placeholderEn: 'Search', placeholderZh: '搜索' }); input.value = '';
  const primary = element(), overflow = element(), more = element(), region = element();
  const moreCount = element(); more.selectors = { '[data-more-count]': [moreCount] };
  const actionNodes = ['One', 'Two', 'Three', 'Four'].map((title, index) => element({
    titleTerms: `task ${title.toLowerCase()}`, keywordTerms: '', descriptionTerms: '', titleEn: title, titleZh: title, actionId: `provider/${index}`,
  }));
  actionNodes.forEach(action => primary.append(action));
  const owner = element({ category: 'display', search: 'owner', pluginNameEn: 'Owner', pluginNameZh: '拥有者', pluginId: 'owner' });
  owner.selectors = { '[data-search-actions]': [region], '[data-search-primary]': [primary], '[data-search-overflow]': [overflow], '[data-search-more]': [more], '[data-search-action]': actionNodes };
  const other = element({ category: 'audio', search: 'other', pluginNameEn: 'Other', pluginNameZh: '其他', pluginId: 'other' });
  const list = element(), count = element(), actionCount = element(), summary = element(), empty = element();
  const filters = ['all', 'audio'].map(filter => element({ marketFilter: filter }));
  const settings = element(); settings.selectors = {
    '[data-market-search]': [input], '[data-market-filter]': filters, '[data-market-plugin]': [owner, other], '.market-list': [list],
    '[data-result-count]': [count], '[data-market-empty]': [empty], '[data-action-result-count]': [actionCount], '[data-action-result-summary]': [summary],
  };
  let languageChanged;
  const module = { exports: {} };
  const code = ts.transpileModule(readFileSync(resolve(site, 'src/scripts/plugin-settings.ts'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  runInNewContext(code, { module, exports: module.exports, require: specifier => loadSource(resolve(site, 'src/scripts', `${specifier}.ts`)),
    document: { documentElement: root, querySelector: () => settings }, window: { addEventListener() {}, matchMedia: () => ({ matches: false }) },
    MutationObserver: class { constructor(callback) { languageChanged = callback; } observe() {} }, Intl, location: { hash: '' },
  });
  return { root, input, owner, other, primary, overflow, more, moreCount, region, count, actionCount, summary, empty, filters, languageChanged,
    query(value) { input.value = value; input.listeners.get('input')(); },
  };
}

test('catalog groups action-only matches, counts collapsed results and preserves filters and query', () => {
  const ui = runCatalog();
  assert.equal(ui.owner.hidden, false); assert.equal(ui.region.hidden, true); assert.equal(ui.summary.hidden, true);
  ui.query('task');
  assert.equal(ui.owner.hidden, false); assert.equal(ui.other.hidden, true);
  assert.equal(ui.count.textContent, '1'); assert.equal(ui.actionCount.textContent, '4');
  assert.equal(ui.primary.children.filter(node => !node.hidden).length, 3);
  assert.equal(ui.overflow.children.filter(node => !node.hidden).length, 1);
  assert.equal(ui.moreCount.textContent, '1');
  ui.more.open = true;
  ui.root.dataset.lang = 'zh'; ui.languageChanged();
  assert.equal(ui.input.value, 'task'); assert.equal(ui.more.open, true); assert.equal(ui.input.placeholder, '搜索');
  ui.filters[1].listeners.get('click')();
  assert.equal(ui.owner.hidden, true); assert.equal(ui.count.textContent, '0'); assert.equal(ui.actionCount.textContent, '0');
  assert.equal(ui.empty.hidden, false); assert.equal(ui.more.open, false);
  ui.languageChanged(); assert.equal(ui.count.textContent, '0', 'language change preserves category filter');
  ui.filters[0].listeners.get('click')();
  ui.more.open = true; ui.query('task one');
  assert.equal(ui.more.open, false); assert.equal(ui.more.hidden, true); assert.equal(ui.actionCount.textContent, '1');
  ui.query('');
  assert.equal(ui.count.textContent, '2'); assert.equal(ui.region.hidden, true); assert.equal(ui.summary.hidden, true);
  assert.equal(ui.owner.hidden, false); assert.equal(ui.other.hidden, false);
  ui.query('missing'); assert.equal(ui.empty.hidden, false);
});

test('built search links preserve every static action route and prerequisites render only when declared', () => {
  const catalog = readFileSync(resolve(site, 'dist/plugins/index.html'), 'utf8');
  for (const entry of actions) {
    assert.ok(catalog.includes(`href="${entry.route}"`), entry.route);
    assert.ok(existsSync(resolve(site, 'dist', entry.route.slice(1), 'index.html')), entry.route);
    assert.ok(search.get(entry.pluginID).actions.some(action => action.id === `${entry.providerID}/${entry.action.id}` && action.route === entry.route));
  }
  for (const plugin of plugins) {
    const html = readFileSync(resolve(site, 'dist/plugins', plugin.id, 'index.html'), 'utf8');
    for (const field of ['applications', 'executables']) {
      const declared = plugin.product?.requirements?.[field] ?? [];
      assert.equal(html.includes(`data-prerequisite="${field}"`), declared.length > 0, `${plugin.id} ${field}`);
      for (const item of declared) for (const value of typeof item === 'string' ? [item] : [item.name, item.bundleID]) assert.ok(html.includes(value), `${plugin.id}: ${value}`);
    }
  }
});
