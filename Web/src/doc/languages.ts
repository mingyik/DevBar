import {
  LanguageDescription,
  LanguageSupport,
  StreamLanguage,
} from "@codemirror/language";
export const documentLanguages = [
  LanguageDescription.of({
    name: "JSON",
    extensions: ["json", "jsonc"],
    load: () => import("@codemirror/lang-json").then((m) => m.json()),
  }),
  LanguageDescription.of({
    name: "JavaScript",
    alias: ["js"],
    extensions: ["js", "mjs", "cjs", "jsx"],
    load: () =>
      import("@codemirror/lang-javascript").then((m) => m.javascript()),
  }),
  LanguageDescription.of({
    name: "TypeScript",
    alias: ["ts"],
    extensions: ["ts", "tsx"],
    load: () =>
      import("@codemirror/lang-javascript").then((m) =>
        m.javascript({ typescript: true }),
      ),
  }),
  LanguageDescription.of({
    name: "Swift",
    extensions: ["swift"],
    load: () =>
      import("@codemirror/legacy-modes/mode/swift").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.swift)),
      ),
  }),
  LanguageDescription.of({
    name: "Python",
    alias: ["py"],
    extensions: ["py"],
    load: () => import("@codemirror/lang-python").then((m) => m.python()),
  }),
  LanguageDescription.of({
    name: "Go",
    extensions: ["go"],
    load: () => import("@codemirror/lang-go").then((m) => m.go()),
  }),
  LanguageDescription.of({
    name: "Java",
    extensions: ["java"],
    load: () => import("@codemirror/lang-java").then((m) => m.java()),
  }),
  LanguageDescription.of({
    name: "Kotlin",
    alias: ["kt"],
    extensions: ["kt", "kts"],
    load: () =>
      import("@codemirror/legacy-modes/mode/clike").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.kotlin)),
      ),
  }),
  LanguageDescription.of({
    name: "SQL",
    extensions: ["sql"],
    load: () => import("@codemirror/lang-sql").then((m) => m.sql()),
  }),
  LanguageDescription.of({
    name: "Shell",
    alias: ["sh", "bash", "zsh", "shellscript"],
    extensions: ["sh", "bash", "zsh"],
    load: () =>
      import("@codemirror/legacy-modes/mode/shell").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.shell)),
      ),
  }),
  LanguageDescription.of({
    name: "YAML",
    alias: ["yml"],
    extensions: ["yaml", "yml"],
    load: () => import("@codemirror/lang-yaml").then((m) => m.yaml()),
  }),
  LanguageDescription.of({
    name: "HTML",
    extensions: ["html", "htm"],
    load: () => import("@codemirror/lang-html").then((m) => m.html()),
  }),
  LanguageDescription.of({
    name: "CSS",
    extensions: ["css"],
    load: () => import("@codemirror/lang-css").then((m) => m.css()),
  }),
  LanguageDescription.of({
    name: "Diff",
    extensions: ["diff", "patch"],
    load: () =>
      import("@codemirror/legacy-modes/mode/diff").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.diff)),
      ),
  }),
  LanguageDescription.of({
    name: "Markdown",
    alias: ["md"],
    load: () => import("@codemirror/lang-markdown").then((m) => m.markdown()),
  }),
];
