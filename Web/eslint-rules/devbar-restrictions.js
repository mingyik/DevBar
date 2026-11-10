/** @type {import("eslint").Rule.RuleModule} */
const devbarRestrictions = {
  meta: {
    type: "problem",
    docs: {
      description:
        "tools/tree 禁止 JSON 标识符；只禁止全局 eval、Function 和联网 API 的引用。字面颜色规则另见 no-literal-color。",
    },
    schema: [],
    messages: {
      json: "src/tools 与 src/tree 禁止 {{name}}，只用 lossless-json。",
      eval: "禁止 eval。",
      functionConstructor: "禁止 Function。",
      setTimeoutString: "禁止 {{name}} 传入字符串。",
      network: "禁止 {{name}}。",
    },
  },
  create(context) {
    const filename = context.filename.replaceAll("\\", "/");
    const bansNativeJSON =
      !/(?:^|\/)src\/bridge\/envelope\.ts$/.test(filename) &&
      /(?:^|\/)src\/(?:tools|tree)\//.test(filename);
    const globalObjects = new Set(["window", "globalThis", "self"]);
    const bannedGlobals = new Set([
      "eval",
      "Function",
      "fetch",
      "XMLHttpRequest",
      "WebSocket",
      "EventSource",
    ]);

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {import("estree").Node | null}
     */
    function unwrap(node) {
      let current = node ?? null;
      while (current && current.type === "ChainExpression") {
        current = current.expression;
      }
      return current;
    }

    /**
     * @param {import("estree").MemberExpression | import("estree").Property} node
     * @returns {string | null}
     */
    function staticKey(node) {
      const key = node.type === "MemberExpression" ? node.property : node.key;
      if (!node.computed && key.type === "Identifier") {
        return key.name;
      }
      if (key.type === "Literal" && typeof key.value === "string") {
        return key.value;
      }
      if (
        node.computed &&
        key.type === "TemplateLiteral" &&
        key.expressions.length === 0
      ) {
        return key.quasis[0]?.value.cooked ?? null;
      }
      return null;
    }

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {boolean}
     */
    function isGlobalObject(node) {
      const current = unwrap(node);
      return current?.type === "Identifier" && globalObjects.has(current.name);
    }

    /**
     * @param {import("estree").Identifier} node
     * @returns {boolean}
     */
    function isOrdinaryMethodName(node) {
      const parent = node.parent;
      if (
        !parent ||
        parent.type !== "MemberExpression" ||
        parent.computed ||
        parent.property !== node
      ) {
        return false;
      }
      return !isGlobalObject(parent.object);
    }
    /**
     * @param {import("estree").Identifier} node
     * @returns {boolean}
     */
    function isMethodOrPropertyKey(node) {
      const parent = node.parent;
      if (
        !parent ||
        (parent.type !== "Property" && parent.type !== "MethodDefinition") ||
        parent.key !== node ||
        parent.computed ||
        (parent.type === "Property" && parent.shorthand)
      ) {
        return false;
      }
      return true;
    }

    /**
     * @param {import("estree").Node} node
     * @param {string} name
     */
    function reportBanned(node, name) {
      if (name === "eval") {
        context.report({ node, messageId: "eval" });
        return;
      }
      if (name === "Function") {
        context.report({ node, messageId: "functionConstructor" });
        return;
      }
      context.report({ node, messageId: "network", data: { name } });
    }

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {string | null}
     */
    function globalCalleeName(node) {
      const current = unwrap(node);
      if (!current) {
        return null;
      }
      if (current.type === "Identifier") {
        return current.name;
      }
      if (
        current.type === "MemberExpression" &&
        isGlobalObject(current.object)
      ) {
        return staticKey(current);
      }
      return null;
    }

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {boolean}
     */
    function isStringCode(node) {
      if (!node) {
        return false;
      }
      if (node.type === "Literal" && typeof node.value === "string") {
        return true;
      }
      return node.type === "TemplateLiteral";
    }

    return {
      Identifier(node) {
        if (bansNativeJSON && node.name === "JSON") {
          context.report({ node, messageId: "json", data: { name: "JSON" } });
        }
        if (
          bannedGlobals.has(node.name) &&
          !isOrdinaryMethodName(node) &&
          !isMethodOrPropertyKey(node)
        ) {
          reportBanned(node, node.name);
        }
      },
      MemberExpression(node) {
        if (!node.computed || !isGlobalObject(node.object)) {
          return;
        }
        const name = staticKey(node);
        if (!name) {
          return;
        }
        if (bansNativeJSON && name === "JSON") {
          context.report({ node, messageId: "json", data: { name: "JSON" } });
        }
        if (bannedGlobals.has(name)) {
          reportBanned(node, name);
        }
      },
      CallExpression(node) {
        const name = globalCalleeName(node.callee);
        if (
          (name === "setTimeout" || name === "setInterval") &&
          isStringCode(node.arguments[0])
        ) {
          context.report({
            node,
            messageId: "setTimeoutString",
            data: { name },
          });
        }
      },
    };
  },
};

export default devbarRestrictions;
