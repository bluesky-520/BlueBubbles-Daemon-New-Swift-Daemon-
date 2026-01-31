import NIOCore
import Vapor

func contactsRoutes(_ app: Application, contactsController: ContactsController) throws {
    app.get("contacts") { req async throws -> [ContactResponse] in
        let limit = req.query[Int.self, at: "limit"]
        let offset = req.query[Int.self, at: "offset"]
        let extraProperties = req.query[String.self, at: "extraProperties"]
            .map { raw in
                raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } ?? []
        return try await contactsController.list(
            on: req.application,
            limit: limit,
            offset: offset,
            extraProperties: extraProperties
        )
    }

    app.get("contacts", "vcf") { req async throws -> String in
        return try await contactsController.vcfString(on: req.application)
    }

    /// GET /contacts/changed - Returns last contacts change timestamp (for polling when SSE /events fails).
    /// Bridge can poll this to detect address book updates without relying on SSE.
    app.get("contacts", "changed") { req -> Response in
        let timestamp = Int64(contactsController.getLastContactsChangeTime().timeIntervalSince1970)
        let body = "{\"lastChanged\":\(timestamp)}\n"
        var response = Response(status: .ok)
        response.headers.contentType = .json
        response.body = .init(buffer: ByteBuffer(string: body))
        return response
    }
}
