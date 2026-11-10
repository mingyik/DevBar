/** @type {import("eslint").Rule.RuleModule} */
const devbarRestrictions = {
  meta: {
    type: "problem",
    docs: {
      description:
        "禁止 eval、Function、字符串定时器，以及联网 API；tools/tree 禁止访问原生 JSON.parse / JSON.stringify。字面颜色规则归属 T0.2。",
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

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {import("estree").Node | null}
     */
    function unwrap(node) {
      let current = node ?? null;
      while (current) {
        if (current.type === "ChainExpression") {
          current = current.expression;
          continue;
        }
        break;
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
      if (
        (node.computed || key.type === "Literal") &&
        key.type === "Literal" &&
        typeof key.value === "string"
      ) {
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
     * @returns {string | null}
     */
    function calleeName(node) {
      const current = unwrap(node);
      if (!current) {
        return null;
      }
      if (current.type === "Identifier") {
        return current.name;
      }
      if (current.type === "MemberExpression") {
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

    /**
     * @param {import("estree").Node | null | undefined} node
     */
    function reportJSONPattern(node) {
      if (!node || node.type !== "ObjectPattern") {
        return;
      }
      for (const prop of node.properties) {
        if (prop.type !== "Property") {
          continue;
        }
        const name = staticKey(prop);
        if (name === "parse" || name === "stringify") {
          context.report({
            node: prop,
            messageId: "json",
            data: { name: `JSON.${name}` },
          });
        }
      }
    }

    /**
     * @param {import("estree").Node | null | undefined} node
     * @returns {boolean}
     */
    function isJSON(node) {
      const current = unwrap(node);
      return current?.type === "Identifier" && current.name === "JSON";
    }

    return {
      MemberExpression(node) {
        if (!bansNativeJSON || !isJSON(node.object)) {
          return;
        }
        const name = staticKey(node);
        if (name === "parse" || name === "stringify") {
          context.report({
            node,
            messageId: "json",
            data: { name: `JSON.${name}` },
          });
        }
      },
      VariableDeclarator(node) {
        if (!bansNativeJSON || !isJSON(node.init)) {
          return;
        }
        reportJSONPattern(node.id);
      },
      AssignmentExpression(node) {
        if (!bansNativeJSON || !isJSON(node.right)) {
          return;
        }
        reportJSONPattern(node.left);
      },
      CallExpression(node) {
        const name = calleeName(node.callee);
        if (name === "eval") {
          context.report({ node, messageId: "eval" });
        } else if (name === "Function") {
          context.report({ node, messageId: "functionConstructor" });
        } else if (
          name === "fetch" ||
          name === "XMLHttpRequest" ||
          name === "WebSocket" ||
          name === "EventSource"
        ) {
          context.report({ node, messageId: "network", data: { name } });
        }
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
      NewExpression(node) {
        const name = calleeName(node.callee);
        if (name === "Function") {
          context.report({ node, messageId: "functionConstructor" });
        } else if (
          name === "XMLHttpRequest" ||
          name === "WebSocket" ||
          name === "EventSource"
        ) {
          context.report({ node, messageId: "network", data: { name } });
        }
      },
    };
  },
};

export default devbarRestrictions;
