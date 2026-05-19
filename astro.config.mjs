import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import sitemap from "@astrojs/sitemap";

// Site URL is read from env so the same build works against the CloudFront
// default domain pre-launch and the real domain post-launch. Override in CI
// via SITE_URL once a custom domain is wired.
const site = process.env.SITE_URL ?? "https://example.cloudfront.net";

export default defineConfig({
  site,
  integrations: [mdx(), sitemap()],
  build: {
    format: "directory",
  },
});
