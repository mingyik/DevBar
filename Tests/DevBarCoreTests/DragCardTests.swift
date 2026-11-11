import Testing

@testable import DevBarCore

@Test func dragCardClampsWidthAndKeepsHeight() {
  #expect(DragCard.height == 56)
  #expect(DragCard.width(title: "a", hasThumb: false) == 160)
  #expect(DragCard.width(title: String(repeating: "字", count: 80), hasThumb: true) == 260)
  #expect(DragCard.width(title: "hello", hasThumb: false) >= 160)
  #expect(DragCard.width(title: "hello", hasThumb: false) <= 260)
}

@Test func dragCardUsesFirstNonEmptyLineAndFileCount() {
  #expect(DragCard.firstLine("\n  \nhello\nworld") == "hello")
  #expect(DragCard.firstLine("   ") == "")
  #expect(DragCard.textSubtitle(characters: 120) == "120 字符")
  #expect(DragCard.fileSubtitle(names: ["first.txt", "second.txt"]) == "first.txt 等 2 个文件")
  #expect(DragCard.fileSubtitle(names: ["only.txt"]) == "only.txt")
}

@Test func dragCardBoundsMillionCharacterTitleBeforeDrawing() {
  let text = "\n  " + String(repeating: "字", count: 1_000_000)
  let title = DragCard.firstLine(text)
  #expect(title.count == 161)
  #expect(title.hasSuffix("…"))
  #expect(DragCard.firstLine("\n  first line  \nsecond") == "first line")
}
