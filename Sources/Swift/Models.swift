import AppKit
import Foundation

public struct DeviceInfo: Codable, Identifiable {
    public var id: String { udid }
    public let udid: String
    public let name: String?
    public let product: String?
    public let version: String?
    public let buildVersion: String?
    public let language: String?
    public let locale: String?
    public var connected: Bool = true

    enum CodingKeys: String, CodingKey {
        case udid, name, product, version, buildVersion, language, locale
    }

    public init(
        udid: String,
        name: String? = nil,
        product: String? = nil,
        version: String? = nil,
        buildVersion: String? = nil,
        language: String? = nil,
        locale: String? = nil,
        connected: Bool = true
    ) {
        self.udid = udid
        self.name = name
        self.product = product
        self.version = version
        self.buildVersion = buildVersion
        self.language = language
        self.locale = locale
        self.connected = connected
    }
}

public struct CardItem: Identifiable, Hashable {
    public let id: String // card hash
    public var label: String
    public var isSelected: Bool
    public var customImageURL: URL?
    public var dateAdded: Date

    public init(
        id: String,
        label: String = "",
        isSelected: Bool = true,
        customImageURL: URL? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.label = label.isEmpty ? "Card \(id.prefix(8))" : label
        self.isSelected = isSelected
        self.customImageURL = customImageURL
        self.dateAdded = dateAdded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id
    }
}

public enum LogLevel: String {
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARN"
    case error = "ERROR"

    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    public init(level: LogLevel = .info, message: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

public enum NavigationTab: String, CaseIterable, Identifiable {
    case cards = "Wallet Cards"
    case logs = "Activity Console"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .cards: return "creditcard.fill"
        case .logs: return "terminal.fill"
        }
    }
}
