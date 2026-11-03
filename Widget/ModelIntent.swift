import AppIntents
import WidgetKit

/// Picker option: "All" or an exact model present in the file.
struct ModelOption: AppEntity {
    static let allID = "__all__"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    static var defaultQuery = ModelOptionQuery()

    var id: String          // display name ("Opus 5.5") or allID
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: id == Self.allID ? "All models" : LocalizedStringResource(stringLiteral: id))
    }

    static let all = ModelOption(id: allID)
    var modelName: String? { id == Self.allID ? nil : id }
}

/// Dynamic list: "All" + every model in the file, most used first.
struct ModelOptionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ModelOption] {
        identifiers.map { ModelOption(id: $0) }
    }

    func suggestedEntities() async throws -> [ModelOption] {
        let names = (try? StatsLoader.load().models.map(\.name)) ?? []
        return [ModelOption.all] + names.map { ModelOption(id: $0) }
    }

    func defaultResult() async -> ModelOption? { .all }
}

struct SelectModelIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Claude Usage"
    static var description = IntentDescription("Choose which model to show, or all of them.")

    @Parameter(title: "Model")
    var model: ModelOption?

    init() {}
    init(model: ModelOption?) { self.model = model }
}
