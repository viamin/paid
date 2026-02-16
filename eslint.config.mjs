import js from "@eslint/js";

export default [
  {
    ignores: ["node_modules/", "app/assets/builds/", "vendor/", "coverage/"],
  },
  {
    ...js.configs.recommended,
    files: ["app/javascript/**/*.js", "app/views/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        window: "readonly",
        document: "readonly",
        console: "readonly",
        fetch: "readonly",
        self: "readonly",
      },
    },
  },
];
