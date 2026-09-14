import Foundation
import AtlasCore

/// Generated UI fixtures only. Normal launches never install this loader.
enum PersonalVerification {
    static func loader(root:URL)->(String,String) async throws -> PersonalProjection {
        return {query,_ in
            if query.lowercased().contains("slow") {try await Task.sleep(nanoseconds:2_000_000_000)}
            if query.lowercased().contains("error") {throw ProjectionError.rejected(401)}
            let empty=query.lowercased().contains("empty")
            let entities:[[String:Any]]=[
                ["entity_id":"learning","entity_type":"area","display_name":"Learning","updated_at":"Today"],
                ["entity_id":"course","entity_type":"goal","display_name":"Finish the design course","updated_at":"Today"],
                ["entity_id":"practice","entity_type":"responsibility","display_name":"Weekly practice","updated_at":"Yesterday"],
                ["entity_id":"studio","entity_type":"area","display_name":"Studio projects","updated_at":"Yesterday"],
                ["entity_id":"atlas","entity_type":"goal","display_name":"Build a small explorer","updated_at":"Today"],
                ["entity_id":"review","entity_type":"responsibility","display_name":"Friday review","updated_at":"Today"]
            ]
            let relationships:[[String:Any]]=[
                ["source_entity_id":"learning","target_entity_id":"course","relationship_type":"supports"],
                ["source_entity_id":"course","target_entity_id":"practice","relationship_type":"advanced_by"],
                ["source_entity_id":"studio","target_entity_id":"atlas","relationship_type":"contains"],
                ["source_entity_id":"atlas","target_entity_id":"practice","relationship_type":"informed_by"],
                ["source_entity_id":"atlas","target_entity_id":"review","relationship_type":"reviewed_in"]
            ]
            return try PersonalProjection.parse([
                "contract":"context-pack.v1","deployment_id":"personal","pack_id":"generated-ui-verification","generated_at":"Generated for this verification session",
                "entities":empty ? []:entities,"relationships":empty ? []:relationships,
                "claims":[
                    ["entity_id":"course","predicate":"next step","value":"Complete the typography lesson and make one small study.","status":"supported","evidence_ids":["note"]],
                    ["entity_id":"learning","predicate":"focus","value":"Practice by building a small, useful thing every week.","status":"supported","evidence_ids":["note"]],
                    ["entity_id":"atlas","predicate":"next step","value":"Connect the map to the evidence behind each result.","status":"supported","evidence_ids":["note"]]
                ],
                "evidence":[["evidence_id":"note","source_uri":root.appendingPathComponent("Fixture0.swift").absoluteString]],
                "scope":["allowed_privacy":["public"]],
                "quality":["grounding":"supported","fresh_sources":1,"conflicts":0,"truncated":false]
            ])
        }
    }
}
