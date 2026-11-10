/** @type {import("eslint").Rule.RuleModule} */
const devbarRestrictions = {
  meta: {
    type: "problem",
    docs: {
      description:
        "禁止 eval、new Function、字符串 setTimeout，以及联网 API；tools/tree 禁止原生 JSON。字面颜色规则归属 T0.2。",
    },
    schema: [],
    messages: {
      json: "src/tools 与 src/tree 禁止 {{name}}，只用 lossless-json。",
      eval: "禁止 eval。",
      functionConstructor: "禁止 new Function。",
      setTimeoutString: "禁止 setTimeout 传入字符串。",
      network: "禁止 {{name}}。",
    },
  },
  create(context) {
    const filename = context.filename.replaceAll("\\", "/");
    const bansNativeJSON =
      /\/src\/(tools|tree)\//.test(filename) &&
      !filename.endsWith("/src/bridge/envelope.ts");

    function calleeName(node) {
      if (node.type === "Identifier") {
        return node.name;
      }
      if (
        node.type === "MemberExpression" &&
        !node.computed &&
        node.property.type === "Identifier"
      ) {
        return node.property.name;
      }
      return null;
    }

    return {
      CallExpression(node) {
        const name = calleeName(node.callee);
        if (
          bansNativeJSON &&
          node.callee.type === "MemberExpression" &&
          !node.callee.computed &&
          node.callee.object.type === "Identifier" &&
          node.callee.object.name === "JSON" &&
          node.callee.property.type === "Identifier" &&
          (node.callee.property.name === "parse" ||
            node.callee.property.name === "stringify")
        ) {
          context.report({
            node,
            messageId: "json",
            data: { name: `JSON.${node.callee.property.name}` },
          });
        }
        if (name === "eval") {
          context.report({ node, messageId: "eval" });
        }
        if (name === "fetch") {
          context.report({
            node,
            messageId: "network",
            data: { name: "fetch" },
          });
        }
        if (
          name === "setTimeout" &&
          node.arguments[0] &&
          node.arguments[0].type === "Literal" &&
          typeof node.arguments[0].value === "string"
        ) {
          context.report({ node, messageId: "setTimeoutString" });
        }
      },
      NewExpression(node) {
        const name = calleeName(node.callee);
        if (name === "Function") {
          context.report({ node, messageId: "functionConstructor" });
        }
        if (
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
