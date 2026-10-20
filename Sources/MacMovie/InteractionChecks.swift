import AppKit

enum InteractionChecks {
    @MainActor static func run() async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw SourceError.invalid("INTERACTION CHECK FAILED: " + message) }
        }
        func settled(_ model: Library) async throws {
            for _ in 0..<200 {
                if !model.loading && !model.loadingMore { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw SourceError.invalid("分页状态等待超时")
        }
        let suite = "local.macmovie.interaction-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        let third = URL(string: "https://example.com/third")!
        let reset = URL(string: "https://example.com/reset")!
        func movie(_ id: String) -> Movie { Movie(id: id, title: id, poster: nil, remark: "") }
        var requests: [URL: Int] = [:]
        let model = Library(defaults: defaults, pageLoader: { url in
            requests[url, default: 0] += 1
            // Deliberately ignore cancellation: the generation guard must reject stale results.
            try? await Task.sleep(nanoseconds: 30_000_000)
            if url == first { return CatalogPage(movies: [movie("a"), movie("b")], next: second, pageCount: 3) }
            if url == second { return CatalogPage(movies: [movie("b"), movie("c")], next: third, pageNumber: 2, pageCount: 3) }
            if url == third {
                if requests[url] == 1 { throw SourceError.invalid("模拟下一页失败") }
                return CatalogPage(movies: [movie("d")], pageNumber: 3, pageCount: 3)
            }
            return CatalogPage(movies: [movie("reset")])
        })
        model.load(first); try await settled(model)
        model.loadMore(); model.loadMore(); try await settled(model)
        try check(requests[second] == 1, "防止重复请求下一页")
        try check(model.movies.map(\.id) == ["a", "b", "c"] && model.currentURL == first, "追加去重并保留当前滚动目录")
        model.loadMore(); try await settled(model)
        try check(model.loadMoreError != nil && model.movies.count == 3 && model.page.next == third, "追加失败保留内容和重试地址")
        model.loadMore(); try await settled(model)
        try check(model.loadMoreError == nil && model.movies.map(\.id) == ["a", "b", "c", "d"] && model.page.next == nil, "重试成功及末页停止")
        model.loadMore()
        try check(!model.loadingMore && requests[third] == 2, "末页不重复请求")
        model.load(first); try await settled(model)
        model.loadMore(); model.load(reset); try await settled(model)
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(model.movies.map(\.id) == ["reset"] && model.page.next == nil, "切换目录后丢弃旧追加结果")
        try check(Theme.branded("北觅影视 · 北觅") == "摸鱼视界 · 摸鱼视界", "动态字段统一应用名称")
        print("PASS: 7 infinite-scroll and branding checks")
    }
}
