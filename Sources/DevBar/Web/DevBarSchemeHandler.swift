import Foundation
import WebKit

final class DevBarSchemeHandler: NSObject, WKURLSchemeHandler {
  let root: URL
  private var stopped: Set<ObjectIdentifier> = []
  private let lock = NSLock()

  init(root: URL) {
    self.root = root
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    let id = ObjectIdentifier(task)
    guard let url = task.request.url, let file = WebFileMap.file(for: url, root: root) else {
      fail(task, status: 403)
      return
    }
    guard let data = try? Data(contentsOf: file), FileManager.default.fileExists(atPath: file.path)
    else {
      fail(task, status: 404)
      return
    }
    if isStopped(id) { return }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": WebFileMap.mimeType(for: file),
          "Content-Security-Policy": DevBarCSP.header,
          "Content-Length": String(data.count),
          "Cache-Control": "no-store",
        ]
      )
    else {
      fail(task, status: 500)
      return
    }
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    lock.lock()
    stopped.insert(ObjectIdentifier(task))
    lock.unlock()
  }

  private func isStopped(_ id: ObjectIdentifier) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped.contains(id)
  }

  private func fail(_ task: any WKURLSchemeTask, status: Int) {
    if isStopped(ObjectIdentifier(task)) { return }
    let url = task.request.url ?? URL(string: "devbar://app/")!
    if let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Security-Policy": DevBarCSP.header
      ])
    {
      task.didReceive(response)
    }
    task.didFinish()
  }
}
