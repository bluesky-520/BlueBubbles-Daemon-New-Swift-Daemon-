import NIOCore
import Vapor

/// GET /events - Server-Sent Events for real-time updates (contacts_updated, new_message).
func eventsRoutes(_ app: Application, contactsController: ContactsController, sentMessageStore: SentMessageStore, incomingMessageStore: IncomingMessageStore) throws {
    app.get("events") { req async throws -> Response in
        logger.info("GET /events - Establishing SSE connection")

        let response = Response()
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
                    _ = writer.write(.buffer(ByteBuffer(string: connectEvent)))

                    var lastContactsSync = contactsController.getLastContactsChangeTime()

                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 500_000_000)

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
                                _ = writer.write(.buffer(ByteBuffer(string: event)))
                            }
                            lastContactsSync = current
                        }

                        for message in sentMessageStore.takePendingForSSE() {
                            if let jsonData = try? JSONEncoder().encode(message),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                let event = "event: new_message\ndata: \(jsonString)\n\n"
                                _ = writer.write(.buffer(ByteBuffer(string: event)))
                            }
                        }
                        for message in incomingMessageStore.takePendingForSSE() {
                            if let jsonData = try? JSONEncoder().encode(message),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                let event = "event: new_message\ndata: \(jsonString)\n\n"
                                _ = writer.write(.buffer(ByteBuffer(string: event)))
                            }
                        }
                    }
                } catch {
                    logger.error("SSE stream error: \(error.localizedDescription)")
                    _ = writer.write(.end)
                }
            }
        }
        return response
    }
}
