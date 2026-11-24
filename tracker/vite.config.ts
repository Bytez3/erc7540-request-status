import { defineConfig } from "vite";

// Relative asset paths, so the same build works at a domain root or under a sub-path such as GitHub Pages'
// https://bytez3.github.io/erc7540-request-status/.
export default defineConfig({
  base: "./",
});
