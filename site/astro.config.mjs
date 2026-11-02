import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://tickler.jdelgado.fr",
  i18n: {
    locales: ["en", "fr"],
    defaultLocale: "en",
    routing: { prefixDefaultLocale: false },
  },
});
