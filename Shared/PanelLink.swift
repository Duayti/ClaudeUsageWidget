import Foundation

/// Link from the widget to the window: `claudeusage://panel` or `claudeusage://panel?model=Opus%205.5`.
/// The scheme is registered in App/Info.plist (CFBundleURLTypes).
enum PanelLink {
    static let scheme = "claudeusage"
    static let host = "panel"
    static let modelParameter = "model"

    struct Request: Equatable, Sendable {
        /// nil = all models.
        var model: String?
    }

    static func url(model: String?) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        if let model, !model.isEmpty { c.queryItems = [URLQueryItem(name: modelParameter, value: model)] }
        return c.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// nil if the URL is not a panel link.
    static func request(from url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let model = c.queryItems?.first { $0.name == modelParameter }?.value
        return Request(model: (model?.isEmpty ?? true) ? nil : model)
    }
}
