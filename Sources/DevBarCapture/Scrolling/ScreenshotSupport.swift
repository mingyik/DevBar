// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import Accelerate
import CoreGraphics
import Foundation

enum ScreenshotSupport {
  // MARK: - Scrolling capture

  /// A failed scroll target must never keep the capture alive forever or
  /// exhaust memory. Reaching a guard keeps the valid portion and explains
  /// why the capture stopped.
  static let scrollingCaptureMaximumDuration: TimeInterval = 120
  static let scrollingCaptureMaximumFrames = 512
  static let scrollingCaptureMaximumRetainedPixels = 60_000_000
  static let scrollingCaptureMaximumPixels = 60_000_000

  struct ScrollingSample: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    var isValid: Bool {
      width > 0 && height > 0 && pixels.count == width * height
    }
  }

  /// Only grayscale registration data is retained, never full capture frames.
  struct ScrollingAnchors {
    struct Entry {
      let sample: ScrollingSample
      let top: Int
    }
    private(set) var entries: [Entry] = []
    static let maximumCount = 8
    static let maximumBytes = 4 * 1024 * 1024
    var retainedBytes: Int { entries.reduce(0) { $0 + $1.sample.pixels.count } }

    mutating func remember(_ sample: ScrollingSample, at top: Int) {
      guard sample.isValid, sample.pixels.count <= Self.maximumBytes,
        !entries.contains(where: { $0.top == top })
      else { return }
      entries.append(Entry(sample: sample, top: top))
      entries.sort { $0.top < $1.top }
      while entries.count > Self.maximumCount || retainedBytes > Self.maximumBytes {
        // Keep the extremes; remove the most redundant interior viewpoint.
        let removable = entries.count > 2 ? Array(1..<(entries.count - 1)) : [0]
        let index = removable.min {
          entries[min($0 + 1, entries.count - 1)].top - entries[max(0, $0 - 1)].top
            < entries[min($1 + 1, entries.count - 1)].top - entries[max(0, $1 - 1)].top
        }!
        entries.remove(at: index)
      }
    }

    enum Registration: Equatable {
      case position(Int)
      case unavailable
      case ambiguous
    }

    func registration(
      matching sample: ScrollingSample, columns: Range<Int>?, allowOverlap: Bool
    ) -> Registration {
      let exact = entries.filter { $0.sample == sample }.map(\.top)
      if !exact.isEmpty {
        return exact.allSatisfy { $0 == exact[0] } ? .position(exact[0]) : .ambiguous
      }
      guard allowOverlap else { return .unavailable }
      var positions: [Int] = []
      for entry in entries {
        guard
          case .advanced(let overlap, let direction, _) = scrollingTransition(
            previous: entry.sample, current: sample, contentColumns: columns)
        else { continue }
        let delta = sample.height - overlap
        positions.append(entry.top + (direction == .forward ? delta : -delta))
      }
      // Ambiguous repeated text must not relocate the viewport arbitrarily.
      guard let first = positions.first else { return .unavailable }
      guard positions.allSatisfy({ abs($0 - first) <= 1 }) else { return .ambiguous }
      return .position(first)
    }
  }

  static func scrollingContentSample(
    _ sample: ScrollingSample, top: Int, bottom: Int
  ) -> ScrollingSample? {
    guard sample.isValid, top >= 0, bottom >= 0, top + bottom < sample.height else {
      return nil
    }
    if top == 0 && bottom == 0 { return sample }
    return ScrollingSample(
      width: sample.width, height: sample.height - top - bottom,
      pixels: Array(sample.pixels[(top * sample.width)..<((sample.height - bottom) * sample.width)])
    )
  }

  enum ScrollingDirection: Equatable {
    case forward
    case backward
  }

  enum ScrollingTransition: Equatable {
    case end
    case advanced(
      overlap: Int,
      direction: ScrollingDirection,
      contentColumns: Range<Int>)
    case unmatched
  }

  static func scrollingSamplesAreStable(
    _ previous: ScrollingSample,
    _ current: ScrollingSample,
    contentColumns: Range<Int>? = nil
  ) -> Bool {
    guard previous.isValid, current.isValid,
      previous.width == current.width,
      previous.height == current.height
    else { return false }
    let columns = contentColumns ?? 0..<previous.width
    guard columns.lowerBound >= 0, columns.upperBound <= previous.width,
      !columns.isEmpty
    else { return false }
    // Empty space must not dilute movement in a narrow column of text.
    return scrollingColumnTiles(in: columns, sampleWidth: previous.width).allSatisfy {
      scrollingDifference(previous, current, columns: $0) <= 1.5
    }
  }

  /// Finds how many rows two successive views share. The calculation is
  /// deliberately pure: captures only provide small grayscale samples and
  /// the exact same matching policy is exercised by the test harness.
  static func scrollingTransition(
    previous: ScrollingSample,
    current: ScrollingSample,
    contentColumns: Range<Int>? = nil
  ) -> ScrollingTransition {
    guard previous.isValid, current.isValid,
      previous.width == current.width,
      previous.height == current.height,
      previous.height >= 24
    else { return .unmatched }

    let columns = contentColumns ?? 0..<previous.width
    guard columns.lowerBound >= 0,
      columns.upperBound <= previous.width,
      !columns.isEmpty
    else { return .unmatched }

    if scrollingSamplesAreStable(
      previous,
      current,
      contentColumns: columns)
    {
      return .end
    }

    let height = previous.height
    // The final scroll at the bottom of a page is often only a few rows.
    // Treating every advance below 18% as a mismatch discarded an otherwise
    // valid capture on short pages just before it could detect the end.
    let minimumAdvance = max(2, Int((Double(height) * 0.01).rounded()))
    let maximumAdvance = min(height - 8, Int((Double(height) * 0.88).rounded()))
    guard minimumAdvance <= maximumAdvance else { return .unmatched }

    struct Match {
      let advance: Int
      let reversed: Bool
      let contentColumns: Range<Int>
      let supportingTiles: Int
      let longestRun: Int
      let matchingRows: Int
      let difference: Double
    }

    let tiles = scrollingColumnTiles(in: columns, sampleWidth: previous.width)
    if previous.width > 32 {
      // Keep native detail where pixels actually change, instead of
      // shrinking a wide Terminal until different digits look alike.
      // Limit the expensive offset search to 32 representative columns.
      let selected: [(column: Int, bounds: Range<Int>)]
      if columns.count <= 32 {
        selected = columns.map { ($0, $0..<($0 + 1)) }
      } else {
        let perTile = max(1, 32 / tiles.count)
        selected = tiles.flatMap { tile in
          tile.map { column in
            (
              column: column,
              difference: scrollingDifference(
                previous, current, columns: column..<(column + 1))
            )
          }.sorted {
            if $0.difference != $1.difference { return $0.difference > $1.difference }
            return $0.column < $1.column
          }.prefix(perTile).map(\.column).sorted().map { ($0, tile) }
        }
      }
      func compact(_ sample: ScrollingSample) -> ScrollingSample {
        var pixels = [UInt8]()
        pixels.reserveCapacity(selected.count * sample.height)
        for row in 0..<sample.height {
          let start = row * sample.width
          for selection in selected { pixels.append(sample.pixels[start + selection.column]) }
        }
        return .init(width: selected.count, height: sample.height, pixels: pixels)
      }
      let transition = scrollingTransition(previous: compact(previous), current: compact(current))
      if case .advanced(let overlap, let direction, let matched) = transition {
        let lower = selected[matched.lowerBound].bounds.lowerBound
        let upper = selected[matched.upperBound - 1].bounds.upperBound
        return .advanced(
          overlap: overlap, direction: direction,
          contentColumns: lower..<upper)
      }
      return transition
    }
    let movingTiles = tiles.filter {
      scrollingDifference(previous, current, columns: $0) > 1.5
    }
    guard !movingTiles.isEmpty else { return .unmatched }

    // Compute pixel differences in Accelerate, once per offset. The old
    // nested Swift pixel loops repeated the work for each tile and candidate
    // and took seconds per Retina frame in unoptimized Developer builds.
    let previousPixels = previous.pixels.map(Float.init)
    let currentPixels = current.pixels.map(Float.init)
    var differences = [Float](repeating: 0, count: previous.pixels.count)
    var matches: [Match] = []
    for advance in minimumAdvance...maximumAdvance {
      if Task.isCancelled { return .unmatched }
      for reversed in [false, true] {
        let count = (height - advance) * previous.width
        previousPixels.withUnsafeBufferPointer { lhs in
          currentPixels.withUnsafeBufferPointer { rhs in
            vDSP_vsub(
              rhs.baseAddress! + (reversed ? advance * previous.width : 0), 1,
              lhs.baseAddress! + (reversed ? 0 : advance * previous.width), 1,
              &differences, 1, vDSP_Length(count))
          }
        }
        vDSP_vabs(differences, 1, &differences, 1, vDSP_Length(count))
        guard
          let match = scrollingCandidate(
            previous: previous,
            advance: advance,
            tiles: movingTiles,
            differences: differences)
        else { continue }
        matches.append(
          Match(
            advance: advance,
            reversed: reversed,
            contentColumns: match.contentColumns,
            supportingTiles: match.supportingTiles,
            longestRun: match.longestRun,
            matchingRows: match.matchingRows,
            difference: match.difference))
      }
    }
    guard !matches.isEmpty else { return .unmatched }
    matches.sort {
      if $0.contentColumns.count != $1.contentColumns.count {
        return $0.contentColumns.count > $1.contentColumns.count
      }
      if $0.supportingTiles != $1.supportingTiles {
        return $0.supportingTiles > $1.supportingTiles
      }
      // Similar digits can pass the row tolerance at a wrong offset.
      // Prefer the closer pixel match before rewarding a longer overlap,
      // which otherwise biases sparse text toward a shorter scroll.
      if $0.difference != $1.difference { return $0.difference < $1.difference }
      if $0.longestRun != $1.longestRun { return $0.longestRun > $1.longestRun }
      return $0.matchingRows > $1.matchingRows
    }

    let best = matches[0]
    let requiredRun = max(8, min(28, height / 12))
    guard best.longestRun >= requiredRun else {
      return .unmatched
    }

    // Repeated content can match equally well over different lengths.
    // Require comparable support so a short blank band does not veto a
    // longer match, but reject any equally precise, substantial rival.
    // Scale the error margin down for precise matches: an approximate
    // low-contrast pattern must not veto an exact overlap.
    let ambiguityTolerance = min(0.75, best.difference)
    if matches.dropFirst().contains(where: { rival in
      (rival.reversed != best.reversed || abs(rival.advance - best.advance) > 2)
        && rival.contentColumns.count >= best.contentColumns.count - 1
        && rival.supportingTiles >= best.supportingTiles - 1
        && rival.longestRun >= max(requiredRun, best.longestRun / 2)
        && rival.matchingRows >= max(requiredRun, best.matchingRows / 2)
        && rival.difference <= best.difference + ambiguityTolerance
    }) {
      return .unmatched
    }
    return .advanced(
      overlap: height - best.advance,
      direction: best.reversed ? .backward : .forward,
      contentColumns: best.contentColumns)
  }

  /// A fixed footer stays at the same viewport rows while the page behind it
  /// advances. Keeping that suffix in every new strip repeats it throughout
  /// the final image, so identify it separately from the moving overlap.
  static func scrollingFixedBottomRows(
    previous: ScrollingSample,
    current: ScrollingSample,
    overlap: Int,
    contentColumns: Range<Int>
  ) -> Int {
    guard previous.isValid, current.isValid,
      previous.width == current.width,
      previous.height == current.height,
      overlap > 0, overlap < previous.height,
      contentColumns.lowerBound >= 0,
      contentColumns.upperBound <= previous.width,
      !contentColumns.isEmpty
    else { return 0 }

    var rows = 0
    for row in stride(from: previous.height - 1, through: 0, by: -1) {
      let start = row * previous.width
      var difference = 0
      for column in contentColumns {
        difference += abs(
          Int(previous.pixels[start + column])
            - Int(current.pixels[start + column]))
      }
      let average = Double(difference) / Double(contentColumns.count)
      guard average <= 2 else { break }
      rows += 1
    }

    let minimumRows = max(4, min(12, previous.height / 100))
    guard rows >= minimumRows, rows < overlap else { return 0 }
    return rows
  }

  static func scrollingFixedTopRows(
    previous: ScrollingSample, current: ScrollingSample, overlap: Int,
    contentColumns: Range<Int>
  ) -> Int {
    guard previous.isValid, current.isValid else { return 0 }
    func reversed(_ sample: ScrollingSample) -> ScrollingSample {
      var pixels: [UInt8] = []
      pixels.reserveCapacity(sample.pixels.count)
      for row in (0..<sample.height).reversed() {
        pixels.append(contentsOf: sample.pixels[(row * sample.width)..<((row + 1) * sample.width)])
      }
      return ScrollingSample(width: sample.width, height: sample.height, pixels: pixels)
    }
    let rows = scrollingFixedBottomRows(
      previous: reversed(previous), current: reversed(current), overlap: overlap,
      contentColumns: contentColumns)
    guard rows > 0 else { return 0 }
    // An unchanged blank margin is not evidence of an anchored toolbar.
    var darkest: UInt8 = 255
    var lightest: UInt8 = 0
    for row in 0..<rows {
      for column in contentColumns {
        let pixel = previous.pixels[row * previous.width + column]
        darkest = min(darkest, pixel)
        lightest = max(lightest, pixel)
      }
    }
    return Int(lightest) - Int(darkest) >= 16 ? rows : 0
  }

  /// Rows newly revealed by a forward scroll. A fixed footer shifts this
  /// range upward by its own height; its pixels are appended once at the end.
  static func scrollingNewContentRows(
    imageHeight: Int,
    overlap: Int,
    fixedBottomRows: Int
  ) -> Range<Int>? {
    guard imageHeight > 0,
      overlap > 0, overlap < imageHeight,
      fixedBottomRows >= 0, fixedBottomRows < overlap
    else { return nil }
    return (overlap - fixedBottomRows)..<(imageHeight - fixedBottomRows)
  }

  private static func scrollingDifference(
    _ lhs: ScrollingSample,
    _ rhs: ScrollingSample,
    columns: Range<Int>
  ) -> Double {
    guard columns.lowerBound >= 0,
      columns.upperBound <= lhs.width,
      !columns.isEmpty
    else { return .infinity }
    let topInset = max(0, lhs.height / 24)
    var difference = 0
    var count = 0
    for row in topInset..<(lhs.height - topInset) {
      let start = row * lhs.width
      for column in columns {
        difference += abs(
          Int(lhs.pixels[start + column])
            - Int(rhs.pixels[start + column]))
        count += 1
      }
    }
    return count > 0 ? Double(difference) / Double(count) : .infinity
  }

  private struct ScrollingCandidate {
    let contentColumns: Range<Int>
    let supportingTiles: Int
    let longestRun: Int
    let matchingRows: Int
    let difference: Double
  }

  private static func scrollingColumnTiles(
    in columns: Range<Int>,
    sampleWidth: Int
  ) -> [Range<Int>] {
    let tileWidth = max(2, sampleWidth / 8)
    var tiles: [Range<Int>] = []
    var lower = columns.lowerBound
    while lower < columns.upperBound {
      let upper = min(columns.upperBound, lower + tileWidth)
      if upper - lower >= 2 || tiles.isEmpty {
        tiles.append(lower..<upper)
      }
      lower = upper
    }
    return tiles
  }

  private static func scrollingCandidate(
    previous: ScrollingSample,
    advance: Int,
    tiles: [Range<Int>],
    differences: [Float]
  ) -> ScrollingCandidate? {
    let requiredRun = max(8, min(28, previous.height / 12))
    let matches = tiles.map { tile -> (Range<Int>, ScrollingRowMatch?) in
      guard
        let match = scrollingMatch(
          previous: previous,
          advance: advance,
          columns: tile,
          differences: differences),
        match.longestRun >= requiredRun,
        match.matchingRows >= max(requiredRun, match.comparedRows / 3)
      else { return (tile, nil) }
      return (tile, match)
    }

    let minimumTiles = matches.count >= 3 ? 2 : 1
    var runs: [[(Range<Int>, ScrollingRowMatch)]] = []
    var run: [(Range<Int>, ScrollingRowMatch)] = []
    var skippedOneTile = false
    for (tile, match) in matches {
      if let match {
        run.append((tile, match))
      } else if !run.isEmpty, !skippedOneTile {
        skippedOneTile = true
      } else {
        if !run.isEmpty { runs.append(run) }
        run = []
        skippedOneTile = false
      }
    }
    if !run.isEmpty { runs.append(run) }

    return runs.compactMap { supported -> ScrollingCandidate? in
      guard supported.count >= minimumTiles,
        let first = supported.first,
        let last = supported.last
      else { return nil }
      let contentColumns = first.0.lowerBound..<last.0.upperBound
      guard
        let combined = scrollingMatch(
          previous: previous,
          advance: advance,
          columns: contentColumns,
          differences: differences),
        combined.longestRun >= requiredRun,
        combined.matchingRows >= max(requiredRun, combined.comparedRows / 3)
      else { return nil }
      return ScrollingCandidate(
        contentColumns: contentColumns,
        supportingTiles: supported.count,
        longestRun: combined.longestRun,
        matchingRows: combined.matchingRows,
        difference: combined.difference)
    }.max {
      if $0.contentColumns.count != $1.contentColumns.count {
        return $0.contentColumns.count < $1.contentColumns.count
      }
      if $0.matchingRows != $1.matchingRows {
        return $0.matchingRows < $1.matchingRows
      }
      return $0.difference > $1.difference
    }
  }

  private struct ScrollingRowMatch {
    let longestRun: Int
    let matchingRows: Int
    let comparedRows: Int
    let difference: Double
  }

  private static func scrollingMatch(
    previous: ScrollingSample,
    advance: Int,
    columns: Range<Int>,
    differences: [Float]
  ) -> ScrollingRowMatch? {
    let width = previous.width
    // Trim the shared rows, not the whole viewport. A viewport-sized inset
    // can erase a valid smaller overlap and strand a long capture on its
    // last accepted frame, or favor a blank band at the wrong offset.
    let edgeInset = max(2, (previous.height - advance) / 10)
    let lastRow = previous.height - advance - edgeInset
    guard lastRow > edgeInset,
      columns.lowerBound >= 0,
      columns.upperBound <= width,
      !columns.isEmpty
    else { return nil }

    let rowCount = lastRow - edgeInset
    var rowDifferences = [Float](repeating: 0, count: rowCount)
    let weights = [Float](repeating: 1, count: columns.count)
    differences.withUnsafeBufferPointer { buffer in
      vDSP_desamp(
        buffer.baseAddress! + edgeInset * width + columns.lowerBound,
        vDSP_Stride(width), weights, &rowDifferences,
        vDSP_Length(rowCount), vDSP_Length(columns.count))
    }
    var longestRun = 0
    var run = 0
    var matchingRows = 0
    var totalDifference: Float = 0
    let threshold = Float(columns.count * 8)
    rowDifferences.withUnsafeBufferPointer { rows in
      var row = 0
      while row < rowCount {
        if rows[row] <= threshold {
          totalDifference += rows[row]
          run += 1
          matchingRows += 1
          if run > longestRun { longestRun = run }
        } else {
          // Bound the influence of a changing block without treating
          // its rows as matches or discarding their error entirely.
          totalDifference += threshold
          run = 0
        }
        row += 1
      }
    }
    return ScrollingRowMatch(
      longestRun: longestRun,
      matchingRows: matchingRows,
      comparedRows: rowCount,
      difference: Double(totalDifference) / Double(rowCount * columns.count))
  }

  static func scrollingPixelRange(
    sampleColumns: Range<Int>,
    sampleWidth: Int,
    imageWidth: Int
  ) -> Range<Int>? {
    guard sampleWidth > 0, imageWidth > 0,
      sampleColumns.lowerBound >= 0,
      sampleColumns.upperBound <= sampleWidth,
      !sampleColumns.isEmpty
    else { return nil }
    let lower = sampleColumns.lowerBound * imageWidth / sampleWidth
    let upper = (sampleColumns.upperBound * imageWidth + sampleWidth - 1) / sampleWidth
    guard lower >= 0, upper <= imageWidth, lower < upper else { return nil }
    return lower..<upper
  }

}
