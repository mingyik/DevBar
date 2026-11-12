import Darwin
import Foundation

@MainActor enum MemoryBudget {
  static var critical = false
  /// Free + inactive + speculative pages are an estimate, not an allocation guarantee.
  static func allows(bytes: Int) -> Bool {
    guard !critical, bytes >= 0 else { return false }
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return false }
    let pages =
      UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return false }
    let available = pages * UInt64(pageSize)
    return permits(
      incoming: UInt64(bytes), available: available, total: ProcessInfo.processInfo.physicalMemory)
  }
  nonisolated static func permits(incoming: UInt64, available: UInt64, total: UInt64) -> Bool {
    let reserve = max(256 * 1024 * 1024, total / 32)
    guard available > reserve else { return false }
    // Leave most available RAM for other applications and allow for parsing/rendering copies.
    return incoming <= (available - reserve) / 48
  }
}
