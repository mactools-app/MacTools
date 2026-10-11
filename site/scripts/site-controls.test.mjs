import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';

const site = new URL('../', import.meta.url);
const compile = (path) => ts.transpileModule(readFileSync(new URL(path, site), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;
const controls = compile('src/scripts/site-controls.ts');
const languageScript = compile('src/scripts/site-language.ts');

function element(attributes = {}, textContent = '') {
  return {
    attributes: { ...attributes }, textContent,
    getAttribute(key) { return this.attributes[key] ?? null; },
    setAttribute(key, value) { this.attributes[key] = value; },
  };
}

function environment(storage, languages = ['en-US'], elements = []) {
  const root = { dataset: { theme: 'light', lang: 'zh' }, lang: 'zh-CN' };
  const listeners = new Map();
  const document = {
    documentElement: root,
    querySelector: (selector) => ({ addEventListener: (_, callback) => listeners.set(selector, callback) }),
    querySelectorAll: (selector) => {
      const attributes = [...selector.matchAll(/\[([^\]]+)\]/g)].map((match) => match[1]);
      return attributes.length ? elements.filter((item) => attributes.every((key) => key in item.attributes)) : [];
    },
  };
  const exports = {};
  const context = {
    document, exports,
    window: { matchMedia: () => ({ matches: false }), addEventListener: (event, callback) => listeners.set(event, callback) },
    navigator: { languages, language: languages[0] ?? '' },
    localStorage: storage,
    MutationObserver: class { observe() {} },
  };
  runInNewContext(languageScript, context);
  return { context, root, listeners, language: exports };
}

function runControls(storage) {
  const localized = element({ 'data-aria-label-en': 'Open in MacTools', 'data-aria-label-zh': '在 MacTools 中打开' });
  const title = element({ 'data-text-en': 'English title', 'data-text-zh': '中文标题' });
  const description = element({ 'data-content-en': 'English description', 'data-content-zh': '中文简介' });
  const env = environment(storage, ['en-US'], [localized, title, description]);
  runInNewContext(controls, { ...env.context, exports: {}, require: () => env.language });
  return { ...env, localized, title, description };
}

test('theme and language toggle once and persist across page loads', () => {
  const values = new Map();
  const storage = { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) };
  const first = runControls(storage);
  assert.equal(first.root.lang, 'en');
  assert.equal(first.title.textContent, 'English title');
  assert.equal(first.description.getAttribute('content'), 'English description');
  assert.equal(first.localized.getAttribute('aria-label'), 'Open in MacTools');
  first.listeners.get('[data-theme-toggle]')();
  first.listeners.get('[data-language-toggle]')();
  assert.equal(first.root.dataset.theme, 'dark');
  assert.equal(first.root.lang, 'zh-CN');
  assert.equal(first.title.textContent, '中文标题');
  assert.equal(first.description.getAttribute('content'), '中文简介');
  const next = runControls(storage);
  assert.equal(next.root.dataset.theme, 'dark');
  assert.equal(next.root.lang, 'zh-CN');
  assert.equal(next.title.textContent, '中文标题');
  assert.equal(next.localized.getAttribute('aria-label'), '在 MacTools 中打开');
});

test('cached history restoration reapplies the preference selected on another page', () => {
  const values = new Map();
  const storage = { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) };
  const { root, listeners, title, description, localized } = runControls(storage);
  assert.equal(root.lang, 'en');
  values.set('mactools-lang', 'zh');
  values.set('mactools-theme', 'dark');
  listeners.get('pageshow')({ persisted: false });
  assert.equal(root.lang, 'en');
  listeners.get('pageshow')({ persisted: true });
  assert.equal(root.lang, 'zh-CN');
  assert.equal(root.dataset.theme, 'dark');
  assert.equal(title.textContent, '中文标题');
  assert.equal(description.getAttribute('content'), '中文简介');
  assert.equal(localized.getAttribute('aria-label'), '在 MacTools 中打开');
  values.set('mactools-lang', 'en');
  listeners.get('pageshow')({ persisted: true });
  assert.equal(root.lang, 'en');
  assert.equal(title.textContent, 'English title');
});

test('unavailable storage does not prevent controls from working', () => {
  const blocked = () => { throw new Error('Storage blocked'); };
  const { root, listeners, title } = runControls({ getItem: blocked, setItem: blocked });
  assert.equal(root.lang, 'en');
  assert.equal(title.textContent, 'English title');
  listeners.get('[data-theme-toggle]')();
  listeners.get('[data-language-toggle]')();
  assert.equal(root.dataset.theme, 'dark');
  assert.equal(root.lang, 'zh-CN');
  assert.doesNotThrow(() => listeners.get('pageshow')({ persisted: true }));
  assert.equal(root.lang, 'en');
});

function htmlFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? htmlFiles(path) : entry.name.endsWith('.html') ? [path] : [];
  });
}

test('every rendered navigation includes the same controls bundle exactly once', () => {
  const dist = new URL('dist/', site);
  // Astro can inline controls or emit a shared module imported by a page entry.
  const controlScripts = (html) => {
    const visited = new Set();
    const inspect = (contents, base) => {
      const controls = contents.includes('data-theme-toggle') ? [contents] : [];
      for (const [, dependency] of contents.matchAll(/\b(?:import|export)\s*(?:[^"'`;]*?\sfrom\s*)?["'`]([^"'`]+)["'`]/g)) {
        const url = dependency.startsWith('/') ? new URL(dependency.slice(1), dist) : new URL(dependency, base);
        if (visited.has(url.href)) continue;
        visited.add(url.href);
        controls.push(...inspect(readFileSync(url, 'utf8'), url));
      }
      return controls;
    };
    return [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].flatMap(([, attributes, contents]) => {
      const src = attributes.match(/src="([^"]+)"/)?.[1];
      if (!src) return inspect(contents, dist);
      const url = new URL(src.replace(/^\//, ''), dist);
      if (visited.has(url.href)) return [];
      visited.add(url.href);
      return inspect(readFileSync(url, 'utf8'), url);
    });
  };
  const home = readFileSync(new URL('index.html', dist), 'utf8');
  const sharedControls = controlScripts(home);
  assert.equal(sharedControls.length, 1);
  let checked = 0;
  for (const path of htmlFiles(fileURLToPath(dist))) {
    const html = readFileSync(path, 'utf8');
    if (!html.includes('data-theme-toggle')) continue;
    assert.deepEqual(controlScripts(html), sharedControls, path);
    checked++;
  }
  assert.ok(checked > 100, 'include generated plugin and action pages');
});

test('Fan Control retains its preset and speed slider preview', () => {
  const html = readFileSync(new URL('dist/plugins/index.html', site), 'utf8');
  const panel = html.split('data-settings-panel="fan-control"')[1]?.split('<section class="settings-panel ')[0];
  assert.ok(panel);
  assert.match(panel, /Full speed/);
  assert.match(panel, /Quiet work/);
  assert.match(panel, /type="range"/);
  assert.match(panel, /6800/);
});

test('language resolution honors the first supported browser preference and explicit choice', () => {
  const { language } = environment({ getItem: () => null });
  for (const [stored, languages, expected] of [
    ['zh', ['en-US'], 'zh'],
    ['en', ['zh-CN'], 'en'],
    [null, ['en-GB', 'zh-CN'], 'en'],
    [null, ['zh-Hant-TW', 'en-US'], 'zh'],
    [null, ['fr-FR', 'zh-Hans'], 'zh'],
    ['invalid', ['de-DE'], 'en'],
    [null, [], 'en'],
  ]) assert.equal(language.resolveLanguage(stored, languages), expected);
});

// Read the actual built head to exercise the script before any body controls load.
const decode = (value) => value.replace(/&(#(?:x[0-9a-f]+|[0-9]+)|amp|quot|apos|lt|gt);/gi, (_, entity) => {
  if (entity.startsWith('#')) return String.fromCodePoint(entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : Number(entity.slice(1)));
  return { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>' }[entity];
});
function builtHead(html) {
  const head = html.split('</head>')[0];
  const elements = [...head.matchAll(/<(meta|title|script)\b([^>]*?)>(?:([\s\S]*?)<\/\1>)?/g)].map(([, tag, source, contents]) => {
    const attributes = Object.fromEntries([...source.matchAll(/([^\s=]+)="([^"]*)"/g)].map(([, key, value]) => [key, decode(value)]));
    return { ...element(attributes, decode(contents ?? '')), tag };
  });
  const bootstrap = head.match(/<script\b[^>]*data-site-preferences[^>]*>([\s\S]*?)<\/script>/)?.[1];
  assert.ok(bootstrap, 'preference initialization is in the head');
  return { elements, bootstrap };
}

test('every generated route localizes its built head before body scripts, including blocked storage', () => {
  const paths = htmlFiles(fileURLToPath(new URL('dist/', site)));
  assert.ok(paths.length > 100, 'include all plugin and action pages');
  for (const path of paths) {
    const html = readFileSync(path, 'utf8');
    for (const locale of ['en', 'zh']) {
      const { elements, bootstrap } = builtHead(html);
      const blocked = () => { throw new Error('Storage blocked'); };
      for (const item of elements) {
        if (item.getAttribute('data-text-zh') !== null) assert.equal(item.textContent, item.getAttribute('data-text-zh'), path);
        if (item.getAttribute('data-content-zh') !== null) assert.equal(item.getAttribute('content'), item.getAttribute('data-content-zh'), path);
      }
      const env = environment({ getItem: blocked }, [locale === 'en' ? 'en-US' : 'zh-TW'], elements);
      runInNewContext(bootstrap, env.context);
      assert.equal(env.root.lang, locale === 'zh' ? 'zh-CN' : 'en', path);
      const title = elements.find((item) => item.tag === 'title');
      const description = elements.find((item) => item.getAttribute('name') === 'description');
      assert.ok(title.textContent.trim(), path);
      assert.ok(description.getAttribute('content')?.trim(), path);
      for (const property of ['og:title', 'twitter:title']) {
        const meta = elements.find((item) => item.getAttribute('property') === property || item.getAttribute('name') === property);
        assert.equal(meta.getAttribute('content'), title.textContent, path);
      }
      for (const property of ['og:description', 'twitter:description']) {
        const meta = elements.find((item) => item.getAttribute('property') === property || item.getAttribute('name') === property);
        assert.equal(meta.getAttribute('content'), description.getAttribute('content'), path);
      }
      assert.equal(elements.find((item) => item.getAttribute('property') === 'og:locale').getAttribute('content'), locale === 'en' ? 'en_US' : 'zh_CN', path);
      if (locale === 'en') {
        assert.doesNotMatch(title.textContent, /[\u3400-\u9fff]/u, path);
        assert.doesNotMatch(description.getAttribute('content'), /[\u3400-\u9fff]/u, path);
      }
      for (const schema of elements.filter((item) => item.getAttribute('type') === 'application/ld+json')) {
        const parsed = JSON.parse(schema.textContent);
        for (const item of Array.isArray(parsed) ? parsed : [parsed]) {
          assert.equal(item.inLanguage, env.root.lang, path);
          if (item.description) assert.equal(item.description, description.getAttribute('content'), path);
        }
      }
    }
  }
});


test('action feedback follows language changes and releases the original markup', () => {
  const feedback = element();
  // Reflect data attributes like a browser element without introducing a DOM dependency.
  feedback.dataset = new Proxy({}, {
    set(_, key, value) { feedback.attributes[key === 'textZh' ? 'data-text-zh' : 'data-text-en'] = value; return true; },
    deleteProperty(_, key) { delete feedback.attributes[key === 'textZh' ? 'data-text-zh' : 'data-text-en']; return true; },
  });
  const env = environment({ getItem: () => null }, ['en-US'], [feedback]);
  env.language.applyLanguage('en');
  env.language.setLocalizedText(feedback, '完成', 'Done');
  assert.equal(feedback.textContent, 'Done');
  env.language.applyLanguage('zh');
  assert.equal(feedback.textContent, '完成');
  env.language.clearLocalizedText(feedback);
  feedback.textContent = 'Original control';
  env.language.applyLanguage('en');
  assert.equal(feedback.textContent, 'Original control');
});
