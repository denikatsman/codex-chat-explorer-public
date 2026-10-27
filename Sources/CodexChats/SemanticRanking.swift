import Foundation

/// Reranking sees candidates from both retrieval methods, rather than losing a strong
/// semantic-only or identifier-only hit below the fused ranking's shortlist cutoff.
enum SemanticRanking {
    static func shortlist(meaning: [SemanticHit], words: [SemanticHit], fallback: [SemanticHit], limit: Int = 12) -> [SemanticHit] {
        guard limit > 0 else { return [] }
        var result = [SemanticHit](), seen = Set<String>()
        for index in 0..<max(meaning.count, words.count) {
            for ranking in [meaning, words] where index < ranking.count {
                let hit = ranking[index]
                if seen.insert(hit.passage.id).inserted { result.append(hit) }
                if result.count == limit { return result }
            }
        }
        for hit in fallback where seen.insert(hit.passage.id).inserted {
            result.append(hit); if result.count == limit { break }
        }
        return result
    }
    static func applying(_ scores: [Double], candidates: [SemanticHit], fallback: [SemanticHit], limit: Int = 80) -> [SemanticHit] {
        guard scores.count == candidates.count else { return fallback }
        let ids = Set(candidates.map { $0.passage.id })
        var ranked = [SemanticHit]()
        for (candidate, score) in zip(candidates, scores) { ranked.append(SemanticHit(passage: candidate.passage, score: score)) }
        ranked.sort { left, right in
            if left.score == right.score { return left.passage.id < right.passage.id }
            return left.score > right.score
        }
        return Array((ranked + fallback.filter { !ids.contains($0.passage.id) }).prefix(limit))
    }
}
