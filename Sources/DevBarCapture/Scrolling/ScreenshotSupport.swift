// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted for DevBar.

import Accelerate
import CoreGraphics
import Foundation

enum ScreenshotSupport {
  // MARK: - Scrolling capture

  /// Limits bound output dimensions and retained image memory, not the time
  /// spent scrolling or revisiting content. At a limit the valid image is kept
  /// while the user chooses completion, saving, or cancellation.
  static let scrollingCaptureMaximumHeight = 200_000
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

    /// Re-derive every remembered viewpoint, e.g. after masking new columns.
    mutating func transformSamples(_ transform: (ScrollingSample) -> ScrollingSample) {
      entries = entries.map { Entry(sample: transform($0.sample), top: $0.top) }
    }

    enum Registration: Equatable {
      case position(Int)
      case unavailable
      case ambiguous
    }

    func registration(
      matching sample: ScrollingSample, columns: Range<Int>?, allowOverlap: Bool,
      minimumOverlap: Int = 0
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
            previous: entry.sample, current: sample, contentColumns: columns),
          overlap >= max(1, minimumOverlap)
        else { continue }
        let delta = sample.height - overlap
        positions.append(entry.top + (direction == .forward ? delta : -delta))
      }
      // Ambiguous repeated text must not relocate the viewport arbitrarily.
      guard let first = positions.first else { return .unavailable }
      guard positions.allSatisfy({ abs($0 - first) <= 1 }) else { return .ambiguous }
      return .position(first)
    }

    /// Confirms a position against several independent viewports. One matching
    /// pair can be a repeated-content alias, so a reversal needs agreement from
    /// more than one remembered viewport before it may move the stitch.
    func verified(
      matching sample: ScrollingSample, columns: Range<Int>?, minimumOverlap: Int,
      minimumSupport: Int = 2
    ) -> Registration {
      var positions: [Int] = []
      for entry in entries {
        if entry.sample == sample {
          positions.append(entry.top)
          continue
        }
        guard
          case .advanced(let overlap, let direction, _) = scrollingTransition(
            previous: entry.sample, current: sample, contentColumns: columns),
          overlap >= minimumOverlap
        else { continue }
        let delta = sample.height - overlap
        positions.append(entry.top + (direction == .forward ? delta : -delta))
      }
      guard !positions.isEmpty else { return .unavailable }
      positions.sort()
      var groups: [(position: Int, count: Int)] = []
      var index = 0
      while index < positions.count {
        var end = index + 1
        while end < positions.count, abs(positions[end] - positions[index]) <= 1 { end += 1 }
        groups.append((positions[index], end - index))
        index = end
      }
      groups.sort { $0.count > $1.count }
      guard let best = groups.first, best.count >= minimumSupport else {
        return .ambiguous
      }
      // Any other position that also meets the support threshold is a real
      // alternative, not noise: adopting the best-known one could duplicate
      // or reorder rows in repeated content.
      if groups.dropFirst().contains(where: { $0.count >= minimumSupport }) {
        return .ambiguous
      }
      return .position(best.position)
    }
  }

  /// Blank the sample columns that belong to an excluded right band. Constant
  /// columns are non-informative, so the matcher ignores them.
  static func scrollingMaskedSample(
    _ sample: ScrollingSample, sourceWidth: Int, rightPixels: Int
  ) -> ScrollingSample {
    guard rightPixels > 0, sourceWidth > 0, sample.isValid else { return sample }
    let kept = max(0, sourceWidth - rightPixels)
    let start = min(
      sample.width, Int((Double(kept) * Double(sample.width) / Double(sourceWidth)).rounded(.down)))
    guard start < sample.width else { return sample }
    var pixels = sample.pixels
    for row in 0..<sample.height {
      let base = row * sample.width
      for column in start..<sample.width { pixels[base + column] = 0 }
    }
    return ScrollingSample(width: sample.width, height: sample.height, pixels: pixels)
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

  /// Picks an interior row inside the shared overlap zone to place the splice
  /// seam, shifting the cut away from edge fades, shadows, and text baselines.
  static func scrollingBestSeamDepth(
    previousEdgeFrame: CGImage,
    currentFrame: CGImage,
    sharedRows: Int,
    topInset: Int,
    bottomInset: Int,
    rightCrop: Int,
    fromBottom: Bool
  ) -> Int {
    let width = currentFrame.width
    let height = currentFrame.height
    guard previousEdgeFrame.width == width, previousEdgeFrame.height == height,
      sharedRows >= 12, width > 0, height > topInset + bottomInset
    else { return 0 }
    let keptWidth = max(1, width - max(0, rightCrop))
    let minDepth = min(max(4, sharedRows / 6), sharedRows / 3)
    let maxDepth = min(sharedRows / 2, max(minDepth, sharedRows - 4))
    guard maxDepth > minDepth else { return 0 }

    let bandHeight = maxDepth - minDepth + 1
    let prevStartY =
      fromBottom
      ? height - bottomInset - 1 - maxDepth
      : topInset + minDepth
    let currStartY =
      fromBottom
      ? topInset + sharedRows - 1 - maxDepth
      : height - bottomInset - sharedRows + minDepth
    let currExtendedY = max(0, currStartY - 1)
    let currExtendedBottom = min(height, currStartY + bandHeight + 1)
    let currExtendedHeight = currExtendedBottom - currExtendedY
    guard prevStartY >= 0, prevStartY + bandHeight <= height,
      currExtendedHeight >= bandHeight
    else { return minDepth }

    guard
      let prevBand = grayscalePixels(
        previousEdgeFrame,
        rect: CGRect(x: 0, y: prevStartY, width: keptWidth, height: bandHeight)),
      let currBand = grayscalePixels(
        currentFrame,
        rect: CGRect(x: 0, y: currExtendedY, width: keptWidth, height: currExtendedHeight))
    else { return minDepth }

    let step = max(1, keptWidth / 128)
    let currOffset = currStartY - currExtendedY
    var bestDepth = minDepth
    var bestScore = Double.infinity

    for depth in minDepth...maxDepth {
      let localIndex = fromBottom ? (maxDepth - depth) : (depth - minDepth)
      let prevRowOffset = localIndex * keptWidth
      let currRowIndex = currOffset + localIndex
      let currRowOffset = currRowIndex * keptWidth
      let hasAbove = currRowIndex > 0
      let hasBelow = currRowIndex + 1 < currExtendedHeight

      var diffSum = 0
      var activitySum = 0
      var sampleCount = 0
      var column = 0
      while column < keptWidth {
        let p = Int(prevBand[prevRowOffset + column])
        let c = Int(currBand[currRowOffset + column])
        diffSum += abs(p - c)
        if column + step < keptWidth {
          activitySum += abs(c - Int(currBand[currRowOffset + column + step]))
        }
        if hasAbove {
          activitySum += abs(c - Int(currBand[(currRowIndex - 1) * keptWidth + column]))
        }
        if hasBelow {
          activitySum += abs(c - Int(currBand[(currRowIndex + 1) * keptWidth + column]))
        }
        sampleCount += 1
        column += step
      }
      guard sampleCount > 0 else { continue }
      let score = (Double(diffSum) * 4.0 + Double(activitySum)) / Double(sampleCount)
      if score < bestScore {
        bestScore = score
        bestDepth = depth
      }
    }
    return bestDepth
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

  /// A repaint (window activation, scrollbar fade) changes a few text runs
  /// while the rest of the viewport stays put. Treating that as a jump locks a
  /// capture that has only one remembered viewport, so a majority of stable
  /// tiles is enough to call the viewport stationary.
  static func scrollingSamplesAreMostlyStable(
    _ previous: ScrollingSample,
    _ current: ScrollingSample,
    contentColumns: Range<Int>? = nil,
    tolerance: Double = 4,
    minimumStableFraction: Double = 0.75
  ) -> Bool {
    guard previous.isValid, current.isValid,
      previous.width == current.width,
      previous.height == current.height
    else { return false }
    let columns = contentColumns ?? 0..<previous.width
    guard columns.lowerBound >= 0,
      columns.upperBound <= previous.width,
      !columns.isEmpty
    else { return false }
    let tiles = scrollingColumnTiles(in: columns, sampleWidth: previous.width)
    guard tiles.count >= 2 else { return false }
    let stable = tiles.filter {
      scrollingDifference(previous, current, columns: $0) <= tolerance
    }.count
    return Double(stable) / Double(tiles.count) >= minimumStableFraction
  }

  static func scrollingSamplesAreStable(
    _ previous: ScrollingSample,
    _ current: ScrollingSample,
    contentColumns: Range<Int>? = nil,
    tolerance: Double = 1.5
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
      scrollingDifference(previous, current, columns: $0) <= tolerance
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

    // Columns that repeat at a short vertical period (stripes, rules, blank
    // gutters) match equally well at several offsets and can silently append
    // the wrong slice during a fast scroll. Only use columns with
    // non-repeating detail; if none remain, pause instead of guessing.
    let informative = columns.filter {
      !scrollingColumnIsPeriodic(previous, column: $0)
    }
    guard !informative.isEmpty else { return .unmatched }
    let tiles = scrollingColumnTiles(in: informative, sampleWidth: previous.width)
    if previous.width > 32 {
      // Keep native detail where pixels actually change, instead of
      // shrinking a wide Terminal until different digits look alike.
      // Limit the expensive offset search to 32 representative columns.
      let selected: [(column: Int, bounds: Range<Int>)]
      if informative.count <= 32 {
        selected = informative.map { ($0, $0..<($0 + 1)) }
      } else {
        guard !tiles.isEmpty else { return .unmatched }
        let perTile = max(1, 32 / tiles.count)
        func movement(_ column: Int) -> Int {
          var difference = 0
          var count = 0
          var row = 0
          while row < previous.height {
            let previousPixel = previous.pixels[row * previous.width + column]
            let currentPixel = current.pixels[row * current.width + column]
            difference += abs(Int(previousPixel) - Int(currentPixel))
            count += 1
            row += 8
          }
          return count > 0 ? difference / count : 0
        }
        selected = tiles.flatMap { tile in
          tile.map { column in (column: column, difference: movement(column)) }.sorted {
            if $0.difference != $1.difference { return $0.difference > $1.difference }
            return $0.column < $1.column
          }.prefix(perTile).map(\.column).sorted().map { ($0, tile) }
        }
      }
      // A 33...63 px selection makes one tile per column, so the pick above
      // can exceed 32 and recurse forever. The follow-up search must stay
      // at or below 32 columns.
      let chosen = Array(selected.prefix(32))
      guard !chosen.isEmpty else { return .unmatched }
      func compact(_ sample: ScrollingSample) -> ScrollingSample {
        var pixels = [UInt8]()
        pixels.reserveCapacity(chosen.count * sample.height)
        for row in 0..<sample.height {
          let start = row * sample.width
          for selection in chosen { pixels.append(sample.pixels[start + selection.column]) }
        }
        return .init(width: chosen.count, height: sample.height, pixels: pixels)
      }
      let transition = scrollingTransition(previous: compact(previous), current: compact(current))
      if case .advanced(let overlap, let direction, let matched) = transition {
        let lower = chosen[matched.lowerBound].bounds.lowerBound
        let upper = chosen[matched.upperBound - 1].bounds.upperBound
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
    // Tall frames search only the correlation peaks. Checking every row
    // offset is too slow to keep a 20 fps return path in the frame queue.
    let previousPixels = previous.pixels.map(Float.init)
    let currentPixels = current.pixels.map(Float.init)
    let advances: [Int]
    if height > 240 {
      let likely = scrollingLikelyAdvances(
        previous: previousPixels,
        current: currentPixels,
        width: previous.width,
        height: height,
        minimumAdvance: minimumAdvance,
        maximumAdvance: maximumAdvance)
      advances = likely.isEmpty ? Array(minimumAdvance...maximumAdvance) : likely
    } else {
      advances = Array(minimumAdvance...maximumAdvance)
    }
    var differences = [Float](repeating: 0, count: previous.pixels.count)
    var matches: [Match] = []
    previousPixels.withUnsafeBufferPointer { lhs in
      currentPixels.withUnsafeBufferPointer { rhs in
        guard let lhsBase = lhs.baseAddress, let rhsBase = rhs.baseAddress else { return }
        for advance in advances {
          if advance.isMultiple(of: 32), Task.isCancelled { return }
          for reversed in [false, true] {
            let count = (height - advance) * previous.width
            vDSP_vsub(
              rhsBase + (reversed ? advance * previous.width : 0), 1,
              lhsBase + (reversed ? 0 : advance * previous.width), 1,
              &differences, 1, vDSP_Length(count))
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
      }
    }
    if Task.isCancelled { return .unmatched }
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

  /// True when a column carries no reliable vertical registration detail:
  /// solid gutters and short-period stripe/grid backgrounds alias at many
  /// scroll offsets. Such columns must not decide a stitch.
  static func scrollingColumnIsPeriodic(
    _ sample: ScrollingSample, column: Int
  ) -> Bool {
    guard sample.isValid, column >= 0, column < sample.width else { return true }
    var values = Set<UInt8>()
    for row in 0..<sample.height {
      values.insert(sample.pixels[row * sample.width + column])
      if values.count >= 4 { break }
    }
    guard values.count >= 4 else { return true }
    for lag in stride(from: 4, through: 32, by: 4) where lag < sample.height {
      var equal = 0
      var total = 0
      var row = 0
      let last = sample.height - lag
      while row < last {
        total += 1
        if sample.pixels[row * sample.width + column]
          == sample.pixels[(row + lag) * sample.width + column]
        {
          equal += 1
        }
        row += 4
      }
      if total > 0, Double(equal) / Double(total) >= 0.9 { return true }
    }
    return false
  }

  /// A fixed footer stays at the same viewport rows while the page behind it
  /// advances. Keeping that suffix in every new strip repeats it throughout
  /// the final image, so identify it separately from the moving overlap.
  static func scrollingFixedBottomRows(
    previous: ScrollingSample, current: ScrollingSample, overlap: Int,
    contentColumns: Range<Int>
  ) -> Int {
    scrollingFixedRows(
      previous: previous, current: current, overlap: overlap,
      contentColumns: contentColumns, fromTop: false)
  }

  static func scrollingFixedTopRows(
    previous: ScrollingSample, current: ScrollingSample, overlap: Int,
    contentColumns: Range<Int>
  ) -> Int {
    scrollingFixedRows(
      previous: previous, current: current, overlap: overlap,
      contentColumns: contentColumns, fromTop: true)
  }

  private static func scrollingFixedRows(
    previous: ScrollingSample, current: ScrollingSample, overlap: Int,
    contentColumns: Range<Int>, fromTop: Bool
  ) -> Int {
    guard previous.isValid, current.isValid,
      previous.width == current.width, previous.height == current.height,
      overlap > 0, overlap < previous.height,
      contentColumns.lowerBound >= 0, contentColumns.upperBound <= previous.width,
      !contentColumns.isEmpty
    else { return 0 }
    var rows = 0
    for index in 0..<previous.height {
      let row = fromTop ? index : previous.height - 1 - index
      let start = row * previous.width
      var maximumDifference = 0
      for column in contentColumns {
        maximumDifference = max(
          maximumDifference,
          abs(Int(previous.pixels[start + column]) - Int(current.pixels[start + column])))
      }
      guard maximumDifference <= 2 else { break }
      rows += 1
    }
    let minimumRows = max(4, min(12, previous.height / 100))
    guard rows >= minimumRows, rows < overlap else { return 0 }
    let band = fromTop ? 0..<rows : (previous.height - rows)..<previous.height
    return scrollingBandHasDetail(previous, rows: band, columns: contentColumns) ? rows : 0
  }

  /// Detects stationary rounded-corner / window-border rows at the top or
  /// bottom of a window capture, where the center scrolls while the outer
  /// corners stay stationary and differ from the straight side edge.
  static func scrollingRoundedCornerRows(
    previous: CGImage,
    current: CGImage,
    scale: CGFloat,
    fromTop: Bool,
    touchesWindowEdge: Bool
  ) -> Int {
    let width = previous.width
    let height = previous.height
    guard width >= 32, height >= 48,
      current.width == width, current.height == height
    else { return 0 }
    let maxScan = min(height / 4, max(8, Int((28 * scale).rounded())))
    let cornerSpan = min(width / 4, max(6, Int((28 * scale).rounded())))
    let bandY = fromTop ? 0 : height - maxScan
    guard
      let prevBand = grayscalePixels(
        previous, rect: CGRect(x: 0, y: bandY, width: width, height: maxScan)),
      let currBand = grayscalePixels(
        current, rect: CGRect(x: 0, y: bandY, width: width, height: maxScan)),
      let midRow = grayscalePixels(
        previous, rect: CGRect(x: 0, y: height / 2, width: width, height: 1))
    else { return 0 }

    let differenceThreshold = touchesWindowEdge ? 4 : 8
    var rows = 0
    func edgeCornerMatches(_ indices: some Sequence<Int>, offset: Int) -> Bool {
      var sawDiffering = false
      var stationaryLength = 0
      for column in indices {
        let p = Int(prevBand[offset + column])
        let c = Int(currBand[offset + column])
        guard abs(p - c) <= 3 else { break }
        stationaryLength += 1
        if abs(p - Int(midRow[column])) >= differenceThreshold {
          sawDiffering = true
        }
      }
      return sawDiffering && stationaryLength >= 1
    }
    for index in 0..<maxScan {
      let row = fromTop ? index : maxScan - 1 - index
      let offset = row * width
      let leftCorner = edgeCornerMatches(0..<cornerSpan, offset: offset)
      let rightCorner = edgeCornerMatches(
        stride(from: width - 1, through: width - cornerSpan, by: -1), offset: offset)
      let matched = touchesWindowEdge ? (leftCorner || rightCorner) : (leftCorner && rightCorner)
      guard matched else { break }
      rows += 1
    }
    return rows >= 2 ? rows : 0
  }

  /// Detects an overlay/legacy scrollbar or stationary right edge that fails
  /// to shift with the scrolling content. Returns the pixel width to crop from
  /// the right edge, or 0 when no right-edge scroller is present.
  static func scrollingRightScrollerColumns(
    previous: CGImage,
    current: CGImage,
    advance: Int,
    direction: ScrollingDirection,
    topInset: Int,
    bottomInset: Int,
    scale: CGFloat
  ) -> Int {
    let width = previous.width
    let height = previous.height
    guard width >= 32, height >= 48,
      current.width == width, current.height == height,
      advance > 0
    else { return 0 }
    let contentTop = max(0, topInset)
    let contentBottom = min(height, height - max(0, bottomInset))
    let contentHeight = contentBottom - contentTop
    let overlapRows = contentHeight - advance
    guard contentHeight >= 24, overlapRows >= 16 else { return 0 }

    let maxScan = min(width / 5, max(8, Int((28 * scale).rounded())))
    let stripRect = CGRect(x: width - maxScan, y: contentTop, width: maxScan, height: contentHeight)
    guard
      let prevStrip = grayscalePixels(previous, rect: stripRect),
      let currStrip = grayscalePixels(current, rect: stripRect)
    else { return 0 }

    let minimumMismatchRows = max(3, overlapRows / 30)
    var scrollerFlags = [Bool](repeating: false, count: maxScan)
    var contentFlags = [Bool](repeating: false, count: maxScan)

    for column in 0..<maxScan {
      var unshiftedSum = 0
      for row in 0..<contentHeight {
        let index = row * maxScan + column
        unshiftedSum += abs(Int(prevStrip[index]) - Int(currStrip[index]))
      }
      var shiftedSum = 0
      var mismatchRows = 0
      for row in 0..<overlapRows {
        let prevRow = direction == .forward ? row + advance : row
        let currRow = direction == .forward ? row : row + advance
        let diff = abs(
          Int(prevStrip[prevRow * maxScan + column]) - Int(currStrip[currRow * maxScan + column]))
        shiftedSum += diff
        if diff > 10 { mismatchRows += 1 }
      }
      let unshiftedMean = Double(unshiftedSum) / Double(contentHeight)
      let shiftedMean = Double(shiftedSum) / Double(overlapRows)
      if mismatchRows >= minimumMismatchRows && shiftedMean > 3.5
        && shiftedMean >= unshiftedMean * 0.75
      {
        scrollerFlags[column] = true
      } else if shiftedMean <= 2.5 && unshiftedMean > 5.0 {
        contentFlags[column] = true
      }
    }

    let contentStopRun = max(4, Int((8 * scale).rounded()))
    var verifiedContentRun = 0
    var scrollerStart: Int?
    var scrollerCount = 0
    for column in stride(from: maxScan - 1, through: 0, by: -1) {
      if contentFlags[column] {
        verifiedContentRun += 1
        if verifiedContentRun >= contentStopRun { break }
      } else {
        verifiedContentRun = 0
      }
      if scrollerFlags[column] {
        scrollerCount += 1
        scrollerStart = column
      }
    }
    guard scrollerCount >= 2, let start = scrollerStart else { return 0 }
    return maxScan - start
  }

  private static func grayscalePixels(_ image: CGImage, rect: CGRect) -> [UInt8]? {
    let width = Int(rect.width)
    let height = Int(rect.height)
    guard width > 0, height > 0, let cropped = image.cropping(to: rect) else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? pixels : nil
  }

  private static func scrollingBandHasDetail(
    _ sample: ScrollingSample, rows: Range<Int>, columns: Range<Int>
  ) -> Bool {
    // A stationary solid margin is not evidence of a fixed toolbar.
    var darkest: UInt8 = 255
    var lightest: UInt8 = 0
    for row in rows {
      for column in columns {
        let pixel = sample.pixels[row * sample.width + column]
        darkest = min(darkest, pixel)
        lightest = max(lightest, pixel)
      }
    }
    return Int(lightest) - Int(darkest) >= 16
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
    in columns: [Int],
    sampleWidth: Int
  ) -> [Range<Int>] {
    let tileWidth = max(1, sampleWidth / 32)
    var result: [Range<Int>] = []
    for column in columns {
      let lower = (column / tileWidth) * tileWidth
      let tile = lower..<min(sampleWidth, lower + tileWidth)
      if result.last != tile { result.append(tile) }
    }
    return result
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

  /// Offsets worth the full row check. A tall frame cannot score every row
  /// offset before the next 20 fps frame arrives. Correlation peaks include
  /// the true shift and any close alias; the row check still accepts or
  /// rejects them.
  private static func scrollingLikelyAdvances(
    previous: [Float],
    current: [Float],
    width: Int,
    height: Int,
    minimumAdvance: Int,
    maximumAdvance: Int
  ) -> [Int] {
    let padded = 1 << Int(ceil(log2(Double(max(height * 2, 2)))))
    let log2n = vDSP_Length(log2(Double(padded)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    let half = padded / 2
    var correlation = [Float](repeating: 0, count: padded)
    var previousColumn = [Float](repeating: 0, count: padded)
    var currentColumn = [Float](repeating: 0, count: padded)
    var realA = [Float](repeating: 0, count: half)
    var imagA = [Float](repeating: 0, count: half)
    var realB = [Float](repeating: 0, count: half)
    var imagB = [Float](repeating: 0, count: half)
    var realC = [Float](repeating: 0, count: half)
    var imagC = [Float](repeating: 0, count: half)
    var unpacked = [Float](repeating: 0, count: padded)

    func forward(
      _ input: [Float], real: inout [Float], imag: inout [Float]
    ) {
      input.withUnsafeBufferPointer { source in
        real.withUnsafeMutableBufferPointer { realBuffer in
          imag.withUnsafeMutableBufferPointer { imagBuffer in
            var split = DSPSplitComplex(
              realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
            source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
              vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
          }
        }
      }
    }

    var previousMean: Float = 0
    var currentMean: Float = 0
    for row in 0..<height {
      let start = row * width
      var previousSum: Float = 0
      var currentSum: Float = 0
      for column in 0..<width {
        previousSum += previous[start + column]
        currentSum += current[start + column]
      }
      previousColumn[row] = previousSum
      currentColumn[row] = currentSum
      previousMean += previousSum
      currentMean += currentSum
    }
    previousMean /= Float(height)
    currentMean /= Float(height)
    for row in 0..<height {
      previousColumn[row] -= previousMean
      currentColumn[row] -= currentMean
    }
    for row in height..<padded {
      previousColumn[row] = 0
      currentColumn[row] = 0
    }
    forward(previousColumn, real: &realA, imag: &imagA)
    forward(currentColumn, real: &realB, imag: &imagB)
    realC[0] = realA[0] * realB[0]
    imagC[0] = imagA[0] * imagB[0]
    for bin in 1..<half {
      let leftReal = realA[bin]
      let leftImag = imagA[bin]
      let rightReal = realB[bin]
      let rightImag = imagB[bin]
      realC[bin] = leftReal * rightReal + leftImag * rightImag
      imagC[bin] = leftImag * rightReal - leftReal * rightImag
    }
    unpacked.withUnsafeMutableBufferPointer { output in
      realC.withUnsafeMutableBufferPointer { realBuffer in
        imagC.withUnsafeMutableBufferPointer { imagBuffer in
          var split = DSPSplitComplex(
            realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
          vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
          output.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
          }
        }
      }
    }
    correlation = unpacked

    var best: Float = 0
    var scores: [(advance: Int, score: Float)] = []
    scores.reserveCapacity(maximumAdvance - minimumAdvance + 1)
    for advance in minimumAdvance...maximumAdvance {
      let forwardScore = correlation[advance]
      let backwardScore = correlation[padded - advance]
      let score = max(forwardScore, backwardScore)
      scores.append((advance, score))
      best = max(best, score)
    }
    guard best > 0 else { return [] }
    let cutoff = best * 0.45
    let peaks = scores.filter { $0.score >= cutoff }.sorted { $0.score > $1.score }.prefix(6)
    var selected = Set(peaks.map(\.advance))
    if let bestAdvance = peaks.first?.advance {
      for delta in -1...1 {
        let advance = bestAdvance + delta
        if advance >= minimumAdvance, advance <= maximumAdvance {
          selected.insert(advance)
        }
      }
    }
    return selected.sorted()
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

}
