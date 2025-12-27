import Foundation

public enum BackupMode: String, Codable, Sendable {
    case full
    case smartIncremental
    case mirror
}

public enum BackupSource: Codable, Sendable, Hashable {
    case photos
    case folder(url: URL)
}

public struct BackupProfile: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var mode: BackupMode
    public var sources: [BackupSource]
    public var folderDestination: URL?

    public init(
        id: String = UUID().uuidString,
        name: String,
        mode: BackupMode = .smartIncremental,
        sources: [BackupSource],
        folderDestination: URL?
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.sources = sources
        self.folderDestination = folderDestination
    }
}

