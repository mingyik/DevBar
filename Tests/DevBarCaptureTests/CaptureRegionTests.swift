import CoreGraphics
import Testing

@testable import DevBarCapture

@Test func regionConvertsNegativeOriginScreenAtTwoTimesScale() throws {
  let region = try CaptureRegion(
    displayID: 7, globalRect: CGRect(x: -990, y: 160, width: 101.5, height: 80.5),
    screenFrame: CGRect(x: -1000, y: 100, width: 1000, height: 700), scale: 2)
  #expect(region.rectInPoints == CGRect(x: 10, y: 559.5, width: 101, height: 80))
  #expect(region.pixelRect == CGRect(x: 20, y: 1119, width: 202, height: 160))
}

@Test func regionClampsToStartingDisplay() throws {
  let region = try CaptureRegion(
    displayID: 1, globalRect: CGRect(x: 90, y: 20, width: 50, height: 31),
    screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
  #expect(region.pixelRect == CGRect(x: 90, y: 49, width: 10, height: 30))
}

@Test func regionRejectsOutsideOrTinySelection() {
  for rect in [
    CGRect(x: 200, y: 200, width: 10, height: 10),
    CGRect(x: 1, y: 1, width: 1, height: 1),
  ] {
    #expect(throws: CapturePrototypeError.self) {
      try CaptureRegion(
        displayID: 1, globalRect: rect,
        screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
    }
  }
}

@Test func regionHandlesDisplayAboveMainAtOneTimesScale() throws {
  let region = try CaptureRegion(
    displayID: 9, globalRect: CGRect(x: 10, y: 810, width: 81, height: 61),
    screenFrame: CGRect(x: 0, y: 800, width: 1000, height: 700), scale: 1)
  #expect(region.pixelRect == CGRect(x: 10, y: 629, width: 80, height: 60))
}

@Test func regionRejectsInvalidScaleAndNonfiniteCoordinates() {
  for scale in [CGFloat.zero, -1, .infinity, .nan] {
    #expect(throws: CapturePrototypeError.self) {
      try CaptureRegion(
        displayID: 1, globalRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: scale)
    }
  }
}
