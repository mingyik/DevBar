// Narrow signatures for the APIs used here; runtime dependencies remain pinned.
declare module "markdown-it" {
  interface Token {
    content: string;
    info: string;
  }
  export default class MarkdownIt {
    constructor(options: {
      html: boolean;
      linkify: boolean;
      typographer: boolean;
      breaks: boolean;
    });
    use(plugin: unknown): this;
    render(text: string): string;
    renderer: {
      rules: Record<
        string,
        ((tokens: Token[], index: number) => string) | undefined
      >;
    };
    utils: { escapeHtml(text: string): string };
  }
}
declare module "markdown-it-task-lists" {
  const plugin: unknown;
  export default plugin;
}
