import CoreGraphics
import Testing

@testable import DevBarCore

@Test func clipboardThumbnailFillsAndCenterCropsWithoutDistortion() {
  let slot = CGRect(x: 12, y: 8, width: 40, height: 40)
  let wide = DragCard.imageFillFrame(size: CGSize(width: 200, height: 100), in: slot)
  #expect(wide == CGRect(x: -8, y: 8, width: 80, height: 40))
  let tall = DragCard.imageFillFrame(size: CGSize(width: 100, height: 200), in: slot)
  #expect(tall == CGRect(x: 12, y: -12, width: 40, height: 80))
  #expect(DragCard.imageFillFrame(size: CGSize(width: 100, height: 100), in: slot) == slot)
  #expect(DragCard.imageFillFrame(size: .zero, in: slot) == .zero)
}

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
  #expect(DragCard.previewText("first line\nsecond line") == "first line\nsecond line")
  #expect(DragCard.previewText(String(repeating: "字", count: 400)).count == 321)
  #expect(DragCard.textSubtitle(characters: 120) == "120 字符")
  #expect(DragCard.fileSubtitle(names: ["first.txt", "second.txt"]) == "2 个文件")
  #expect(DragCard.fileSubtitle(names: ["only.txt"]) == "")
}

@Test func clipTagUsesFormatNotChineseKind() {
  #expect(ClipTag.label(kind: .text, types: [], fileNames: [], text: "hello") == "TXT")
  #expect(ClipTag.label(kind: .text, types: [], fileNames: [], text: " https://a.b/c ") == "URL")
  #expect(ClipTag.label(kind: .text, types: [], fileNames: [], text: "https://a b") == "TXT")
  #expect(
    ClipTag.label(kind: .image, types: ["public.tiff", "public.png"], fileNames: [], text: "")
      == "TIFF")
  #expect(ClipTag.label(kind: .image, types: ["x.unknown"], fileNames: [], text: "") == "IMG")
  #expect(ClipTag.label(kind: .files, types: [], fileNames: ["a.svg"], text: "") == "SVG")
  #expect(
    ClipTag.label(kind: .files, types: [], fileNames: ["a.svg", "b.SVG"], text: "") == "SVG")
  #expect(
    ClipTag.label(kind: .files, types: [], fileNames: ["a.svg", "b.png"], text: "") == "FILE")
  #expect(ClipTag.label(kind: .files, types: [], fileNames: ["folder"], text: "") == "FILE")
  #expect(ClipTag.label(kind: .files, types: [], fileNames: ["folder/"], text: "") == "DIR")
  #expect(DragCard.lineCount("") == 0)
  #expect(DragCard.lineCount("one") == 1)
  #expect(DragCard.lineCount("one\ntwo\nthree") == 3)
}

@Test func dragCardBoundsMillionCharacterTitleBeforeDrawing() {
  let text = "\n  " + String(repeating: "字", count: 1_000_000)
  let title = DragCard.firstLine(text)
  #expect(title.count == 161)
  #expect(title.hasSuffix("…"))
  #expect(DragCard.firstLine("\n  first line  \nsecond") == "first line")
}
