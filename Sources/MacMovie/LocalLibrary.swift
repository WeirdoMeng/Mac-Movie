import Foundation

struct WatchRecord: Identifiable, Codable, Equatable {
    var id: String { movie.id }
    let movie: Movie
    let episode: Episode
    var position: Double
    var duration: Double
    var updatedAt: Date
    var completed: Bool { duration > 0 && duration - position < 15 }
    var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

struct PlayerSettings: Codable, Equatable {
    var autoNext = true
    var rate: Float = 1
    var volume: Float = 0.8
    var muted = false
}

struct SavedLibrary: Codable {
    var favorites: [Movie] = []
    var history: [WatchRecord] = []
    var settings = PlayerSettings()
}

final class LocalLibrary {
    static let key = "macmovie.library.v1"
    private let defaults: UserDefaults
    private(set) var data: SavedLibrary
    private(set) var readError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let bytes = defaults.data(forKey: Self.key) {
            do { data = try JSONDecoder().decode(SavedLibrary.self, from: bytes) }
            catch {
                data = SavedLibrary()
                readError = "本地观影记录无法读取，原数据已保留；新操作会写入新的记录。"
                defaults.set(bytes, forKey: Self.key + ".recovery")
            }
        } else { data = SavedLibrary() }
    }

    func save(_ data: SavedLibrary) throws {
        let bytes = try JSONEncoder().encode(data)
        self.data = data
        defaults.set(bytes, forKey: Self.key)
    }
}

enum PlaybackPolicy {
    static func ordered(_ episodes: [Episode], line: String) -> [Episode] {
        episodes.filter { $0.line == line }.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    static func adjacent(to episode: Episode, in episodes: [Episode], offset: Int) -> Episode? {
        let list = ordered(episodes, line: episode.line)
        guard let index = list.firstIndex(where: { $0.id == episode.id }), list.indices.contains(index + offset) else { return nil }
        return list[index + offset]
    }

    static func resumePosition(_ record: WatchRecord?, episode: Episode) -> Double {
        guard let record, record.episode.id == episode.id, !record.completed, record.position.isFinite else { return 0 }
        return max(0, record.position)
    }

    static func equivalent(_ episode: Episode, line: String, episodes: [Episode]) -> Episode? {
        let number = episode.url.deletingPathExtension().lastPathComponent.split(separator: "-").last
        return ordered(episodes, line: line).first { $0.url.deletingPathExtension().lastPathComponent.split(separator: "-").last == number }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct BrowseSection: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let path: String?

    static let all: [BrowseSection] = [
        .init(id: "home", title: "发现", icon: "sparkles", path: "/"),
        .init(id: "latest", title: "最近更新", icon: "clock.arrow.circlepath", path: "/map/"),
        .init(id: "rank", title: "排行榜", icon: "chart.bar.fill", path: "/label/rank/"),
        .init(id: "favorites", title: "我的收藏", icon: "heart", path: nil),
        .init(id: "history", title: "观看历史", icon: "clock", path: nil),
        .init(id: "1", title: "电影", icon: "film", path: "/vodshow/1-----------.html"),
        .init(id: "2", title: "连续剧", icon: "tv", path: "/vodshow/2-----------.html"),
        .init(id: "3", title: "综艺", icon: "mic", path: "/vodshow/3-----------.html"),
        .init(id: "4", title: "动漫", icon: "play.square", path: "/vodshow/4-----------.html"),
        .init(id: "20", title: "纪录片", icon: "globe.asia.australia", path: "/vodshow/20-----------.html"),
        .init(id: "35", title: "动画片", icon: "wand.and.stars", path: "/vodshow/35-----------.html"),
        .init(id: "21", title: "短剧", icon: "rectangle.stack", path: "/vodshow/21-----------.html")
    ]
}
