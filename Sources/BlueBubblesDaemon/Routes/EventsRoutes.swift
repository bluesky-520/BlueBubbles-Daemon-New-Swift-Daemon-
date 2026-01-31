import NIOCore
import Vapor

/// GET /events - Server-Sent Events for real-time updates (e.g. contacts_updated).
/// Clients can subscribe to receive address book sync notifications.
func eventsRoutes(_ app: Application, contactsController: ContactsController) throws {
    app.get("events") { req async throws -> Response in
        logger.info("GET /events - Establishing SSE connection")

        var response = Response()
        response.status = .ok
        response.headers.contentType = HTTPMediaType(type: "text", subType: "event-stream")
        response.headers.add(name: "Cache-Control", value: "no-cache")
        response.headers.add(name: "Connection", value: "keep-alive")
        response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
        response.headers.add(name: "Access-Control-Allow-Headers", value: "Cache-Control")

        response.body = .init { writer in
            Task {
                do {
                    let connectEvent = "event: connected\ndata: {\"status\": \"connected\"}\n\n"
                    try await writer.write(.buffer(ByteBuffer(string: connectEvent)))

                    var lastContactsSync = contactsController.getLastContactsChangeTime()

                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 2_000_000_000)

                        let current = contactsController.getLastContactsChangeTime()
                        if current > lastContactsSync {
                            logger.info("SSE: Contacts updated")
                            let contactEventData: [String: Any] = [
                                "type": "contacts_updated",
                                "timestamp": Int64(current.timeIntervalSince1970)
                            ]
                            if let jsonData = try? JSONSerialization.data(withJSONObject: contactEventData),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                let event = "event: contacts_updated\ndata: \(jsonString)\n\n"
                                try await writer.write(.buffer(ByteBuffer(string: event)))
                            }
                            lastContactsSync = current
                        }
                    }
                } catch {
                    logger.error("SSE stream error: \(error.localizedDescription)")
                    try? await writer.write(.end)
                }
            }
        }
        return response
    }
}
