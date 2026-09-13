import Foundation

public struct PersonalArea: Sendable {
    public let id:String
    public let name:String
    public let kind:String
    public let updated:String
    public let claims:[String]
    public let sources:[String]
}
public struct PersonalLink: Sendable { public let from:String; public let to:String; public let kind:String }
public struct PersonalProjection: Sendable {
    public let areas:[PersonalArea]
    public let links:[PersonalLink]
    public let receipt:String
    public let quality:String
    public let generated:String
    public let grants:[String]
    public static func parse(_ object:[String:Any]) throws -> PersonalProjection {
        guard object["contract"] as? String == "context-pack.v1", object["deployment_id"] as? String == "personal" else { throw ProjectionError.wrongDeployment }
        let entities=(object["entities"] as? [[String:Any]] ?? []).prefix(24)
        let claims=object["claims"] as? [[String:Any]] ?? []
        let evidence=object["evidence"] as? [[String:Any]] ?? []
        let kinds:Set<String>=["area","goal","person","thread","event","responsibility","drift"]
        let areas=entities.compactMap { entity -> PersonalArea? in
            guard let id=entity["entity_id"] as? String, let kind=entity["entity_type"] as? String, kinds.contains(kind) else {return nil}
            let selected=claims.filter {$0["entity_id"] as? String == id}.prefix(8)
            let ids=Set(selected.flatMap {$0["evidence_ids"] as? [String] ?? []})
            let sources=evidence.filter {ids.contains($0["evidence_id"] as? String ?? "")}.prefix(8).compactMap {$0["source_uri"] as? String}
            let statements=selected.compactMap { c -> String? in
                guard let predicate=c["predicate"] as? String else { return nil }
                // Render only known typed scalar fields, never arbitrary payloads.
                let structured=c["value"] as? [String:Any]
                let fields=["label","text","summary","description","status","state","due_at","target_date"].compactMap { key -> String? in
                    guard let string=structured?[key] as? String else { return nil }
                    return "\(key): \(String(string.prefix(350)))"
                }
                let value=(c["value"] as? String) ?? (c["value"] as? NSNumber)?.stringValue ?? (fields.isEmpty ? nil : fields.joined(separator:" · "))
                guard let value else { return nil }
                return "\(predicate): \(String(value.prefix(500))) [\(c["status"] as? String ?? "unknown")]"
            }
            return PersonalArea(id:id,name:String(((entity["display_name"] as? String) ?? (entity["slug"] as? String) ?? "Unnamed area").prefix(180)),kind:kind,updated:entity["updated_at"] as? String ?? "Unknown",claims:statements,sources:sources)
        }
        let ids=Set(areas.map(\.id))
        let links=(object["relationships"] as? [[String:Any]] ?? []).prefix(96).compactMap { item -> PersonalLink? in
            guard let from=item["source_entity_id"] as? String, let to=item["target_entity_id"] as? String, ids.contains(from), ids.contains(to) else {return nil}
            return PersonalLink(from:from,to:to,kind:String((item["relationship_type"] as? String ?? "related").prefix(80)))
        }
        let q=object["quality"] as? [String:Any] ?? [:]
        let quality="Grounding: \(q["grounding"] as? String ?? "unknown") · fresh sources: \(q["fresh_sources"] as? Int ?? 0) · stale: \(q["stale_sources"] as? Int ?? 0) · unknown: \(q["unknown_freshness_sources"] as? Int ?? 0) · conflicts: \(q["conflicts"] as? Int ?? 0)\n\((q["truncated"] as? Bool == true) ? "Partial selection" : "Bounded query result, not a complete life inventory") · \((object["gaps"] as? [Any] ?? []).count) reported gaps"
        let scope=object["scope"] as? [String:Any] ?? [:]
        return PersonalProjection(areas:areas,links:links,receipt:object["pack_id"] as? String ?? "Unavailable",quality:quality,generated:object["generated_at"] as? String ?? "Unknown",grants:scope["allowed_privacy"] as? [String] ?? [])
    }
}
public enum ProjectionError: LocalizedError {
    case wrongDeployment, unavailable, tooLarge, rejected(Int)
    public var errorDescription:String? {
        switch self {
        case .wrongDeployment:return "The response is not a Personal context-pack.v1 projection. No content was shown."
        case .unavailable:return "The local Personal kernel does not advertise the required read contract."
        case .tooLarge:return "The response exceeded this view’s size limit. Try a narrower question."
        case .rejected(let code):return code==401 || code==403 ? "A scoped Personal read credential is required. The kernel has not authorized this read." : "The local kernel returned HTTP \(code). No context was loaded."
        }
    }
}
