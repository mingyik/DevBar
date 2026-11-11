import {
  LanguageDescription,
  LanguageSupport,
  StreamLanguage,
} from "@codemirror/language";
export const documentLanguages = [
  LanguageDescription.of({
    name: "JSON",
    load: () => import("@codemirror/lang-json").then((m) => m.json()),
  }),
  LanguageDescription.of({
    name: "JavaScript",
    alias: ["js"],
    load: () =>
      import("@codemirror/lang-javascript").then((m) => m.javascript()),
  }),
  LanguageDescription.of({
    name: "TypeScript",
    alias: ["ts"],
    load: () =>
      import("@codemirror/lang-javascript").then((m) =>
        m.javascript({ typescript: true }),
      ),
  }),
  LanguageDescription.of({
    name: "Swift",
    load: () =>
      import("@codemirror/legacy-modes/mode/swift").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.swift)),
      ),
  }),
  LanguageDescription.of({
    name: "Python",
    alias: ["py"],
    load: () => import("@codemirror/lang-python").then((m) => m.python()),
  }),
  LanguageDescription.of({
    name: "Go",
    load: () => import("@codemirror/lang-go").then((m) => m.go()),
  }),
  LanguageDescription.of({
    name: "Java",
    load: () => import("@codemirror/lang-java").then((m) => m.java()),
  }),
  LanguageDescription.of({
    name: "Kotlin",
    alias: ["kt"],
    load: () =>
      import("@codemirror/legacy-modes/mode/clike").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.kotlin)),
      ),
  }),
  LanguageDescription.of({
    name: "SQL",
    load: () => import("@codemirror/lang-sql").then((m) => m.sql()),
  }),
  LanguageDescription.of({
    name: "Shell",
    alias: ["sh", "bash", "zsh", "shellscript"],
    load: () =>
      import("@codemirror/legacy-modes/mode/shell").then(
        (m) => new LanguageSupport(StreamLanguage.define(m.shell)),
      ),
  }),
  LanguageDescription.of({
    name: "YAML",
    alias: ["yml"],
    load: () => import("@codemirror/lang-yaml").then((m) => m.yaml()),
  }),
  LanguageDescription.of({
    name: "HTML",
    load: () => import("@codemirror/lang-html").then((m) => m.html()),
  }),
  LanguageDescription.of({
    name: "CSS",
    load: () => import("@codemirror/lang-css").then((m) => m.css()),
  }),
  LanguageDescription.of({
    name: "Diff",
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
