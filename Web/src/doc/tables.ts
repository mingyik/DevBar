/** Classification only: never parse or reserialize cell values. */
export function isNumericColumn(cells: string[], explicit: boolean): boolean {
  const values = cells.map((s) => s.trim()).filter(Boolean);
  return (
    !explicit &&
    values.length > 0 &&
    values.every((s) => /^[+-]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?%?$/.test(s))
  );
}
export function prepareTables(root: DocumentFragment): void {
  for (const table of Array.from(root.querySelectorAll("table"))) {
    const rows = Array.from(table.rows);
    const width = Math.max(0, ...rows.map((row) => row.cells.length));
    for (let column = 0; column < width; column++) {
      const cells = rows
        .map((row) => row.cells[column])
        .filter((cell): cell is HTMLTableCellElement => Boolean(cell));
      let explicit = false;
      for (const cell of cells) {
        const align = /^\s*text-align:\s*(left|center|right)\s*;?\s*$/i.exec(
          cell.getAttribute("style") ?? "",
        );
        if (align) {
          cell.classList.add("align-" + align[1].toLowerCase());
          explicit = true;
        }
        if (
          ["align-left", "align-center", "align-right"].some((c) =>
            cell.classList.contains(c),
          )
        )
          explicit = true;
      }
      const data = cells
        .filter((cell) => cell.tagName === "TD")
        .map((cell) => cell.textContent ?? "");
      if (isNumericColumn(data, explicit))
        for (const cell of cells) cell.classList.add("num");
    }
    if (!table.parentElement?.classList.contains("table-wrap")) {
      const wrapper = table.ownerDocument.createElement("div");
      wrapper.className = "table-wrap";
      table.replaceWith(wrapper);
      wrapper.append(table);
    }
  }
}
