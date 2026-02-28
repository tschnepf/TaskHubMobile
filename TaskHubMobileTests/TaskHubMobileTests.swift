import Testing
import Foundation
import SwiftData
@testable import TaskHubMobile

struct MobileTaskDecodingTests {

    @Test("Decode summary list")
    func decodeSummary() async throws {
        let json = """
        [
          {"id":"1","title":"A","is_completed":false,"due_at":"2026-02-24T22:04:50Z","updated_at":"2026-02-24T22:04:50Z"},
          {"id":"2","title":"B","is_completed":true,"due_at":null,"updated_at":"2026-02-24T22:04:50Z"}
        ]
        """.data(using: .utf8)!
        let decoder = JSONDecoder.mobileRFC3339()
        let arr = try decoder.decode([MobileTaskSummaryDTO].self, from: json)
        #expect(arr.count == 2)
        #expect(arr[0].id == "1")
        #expect(arr[1].is_completed == true)
    }

    @Test("Decode detail payload (GET/PATCH)")
    func decodeDetail() async throws {
        let json = """
        {
          "id":"1",
          "title":"A",
          "description":null,
          "notes":null,
          "attachments":null,
          "intent":"task",
          "area":"personal",
          "project":"a1b2c3",
          "status":"open",
          "priority":3,
          "due_at":"2026-02-24T22:04:50Z",
          "recurrence":"none",
          "completed_at":null,
          "position":1,
          "created_at":"2026-02-24T22:04:50Z",
          "updated_at":"2026-02-24T22:04:50Z",
          "is_completed":false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder.mobileRFC3339()
        let item = try decoder.decode(MobileTaskDetailDTO.self, from: json)
        #expect(item.id == "1")
        #expect(item.projectId == "a1b2c3")
        #expect(item.is_completed == false)
        #expect(item.priority == 3)
    }

    @Test("Decode error envelope")
    func decodeErrorEnvelope() async throws {
        let json = """
        {"error":{"code":"bad_request","message":"oops","details":{}},"request_id":"r123"}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(APIErrorEnvelope.self, from: json)
        #expect(env.error.code == "bad_request")
        #expect(env.request_id == "r123")
    }

    @Test("Decode summary with project and project_name")
    func decodeSummaryProjectFields() async throws {
        let json = """
        [{
          "id":"1","title":"A","is_completed":false,
          "due_at":"2026-02-24T22:04:50Z","updated_at":"2026-02-24T22:04:50Z",
          "project":"abc-uuid","project_name":"ADC"
        }]
        """.data(using: .utf8)!
        let decoder = JSONDecoder.mobileRFC3339()
        let arr = try decoder.decode([MobileTaskSummaryDTO].self, from: json)
        #expect(arr.first?.projectId == "abc-uuid")
        #expect(arr.first?.projectName == "ADC")
    }

    @Test("Decode detail with project and project_name")
    func decodeDetailProjectFields() async throws {
        let json = """
        {
          "id":"1","title":"A","is_completed":false,
          "due_at":"2026-02-24T22:04:50Z","updated_at":"2026-02-24T22:04:50Z",
          "project":"abc-uuid","project_name":"ADC"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder.mobileRFC3339()
        let item = try decoder.decode(MobileTaskDetailDTO.self, from: json)
        #expect(item.projectId == "abc-uuid")
        #expect(item.projectName == "ADC")
    }
}

struct WorldConsolidationTests {

    @MainActor
    @Test("AppConfig persists and reloads baseURL")
    func appConfigPersistsBaseURL() async throws {
        let url = try #require(URL(string: "https://example.taskhub.local"))
        let config = AppConfig()
        config.resetAll()
        config.setBaseURL(url)

        let reloaded = AppConfig()
        #expect(reloaded.baseURL == url)

        reloaded.resetAll()
    }

    @Test("Server base URL canonicalizes API-suffixed URLs")
    func canonicalizesAPISuffixedBaseURL() async throws {
        let input = try #require(URL(string: "https://example.taskhub.local/api"))
        let canonical = try #require(ServerBootstrap.canonicalBaseURL(input))
        #expect(canonical.absoluteString == "https://example.taskhub.local")
    }

    @MainActor
    @Test("DefaultAppEnvironment wires core services once")
    func defaultEnvironmentWiring() async throws {
        let schema = Schema([TaskItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let env = DefaultAppEnvironment(modelContainer: container)
        #expect(env.modelContainer === container)
        #expect(env.appConfig.baseURL == nil)
        #expect(env.syncController.lastSync == nil)
    }

    @MainActor
    @Test("SyncController conforms to Syncing protocol")
    func syncControllerConformsToSyncing() async throws {
        let schema = Schema([TaskItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let appConfig = AppConfig()
        appConfig.resetAll()
        let authStore = AuthStore()
        let controller = SyncController(container: container, appConfig: appConfig, authStore: authStore)

        let syncing: Syncing = controller
        syncing.stopLiveSyncLoop()
        #expect(controller.lastSync == nil)
        #expect(controller.nextAllowedSync == nil)
        #expect(controller.lastError == nil)
    }
}
