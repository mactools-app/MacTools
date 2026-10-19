import { starterPacks } from "@/lib/starter-packs";

const pages = [
  { path: "/", priority: "1.0", changefreq: "weekly" },
  { path: "/plugins", priority: "0.9", changefreq: "weekly" },
  { path: "/packs", priority: "0.9", changefreq: "monthly" },
  ...starterPacks.map((pack) => ({ path: `/packs/${pack.id}`, priority: "0.8", changefreq: "monthly" })),
  { path: "/about", priority: "0.6", changefreq: "monthly" },
  { path: "/privacy-policy", priority: "0.5", changefreq: "yearly" },
] as const;

const lastmod = new Date().toISOString();
const entries = pages.map((page) => {
  const loc = new URL(page.path, import.meta.env.SITE).href;
  return [
    "  <url>",
    `    <loc>${loc}</loc>`,
    `    <lastmod>${lastmod}</lastmod>`,
    `    <changefreq>${page.changefreq}</changefreq>`,
    `    <priority>${page.priority}</priority>`,
    "  </url>",
  ].join("\n");
});

export function GET() {
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
      `${entries.join("\n")}\n` +
      `</urlset>\n`,
    {
      headers: {
        "Content-Type": "application/xml; charset=utf-8",
      },
    },
  );
}
