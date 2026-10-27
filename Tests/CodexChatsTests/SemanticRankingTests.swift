import XCTest
@testable import CodexChats

final class SemanticRankingTests: XCTestCase {
    private func hit(_ id: String) -> SemanticHit {
        SemanticHit(passage: SemanticPassage(id:id,chatID:id,itemID:id,turnID:"turn",ordinal:1,role:"ASSISTANT",phase:"final_answer",text:id,context:id,createdAt:nil,sourceDigest:id),score:1)
    }
    func testRerankerPoolIncludesComplementaryMeaningAndIdentifierCandidates() {
        let meaning = [hit("semantic-answer"),hit("shared"),hit("paraphrase")]
        let words = [hit("exact-path"),hit("shared"),hit("identifier")]
        let result = SemanticRanking.shortlist(meaning:meaning,words:words,fallback:[hit("fused")],limit:5)
        XCTAssertEqual(result.map { $0.passage.id },["semantic-answer","exact-path","shared","paraphrase","identifier"])
        XCTAssertTrue(SemanticRanking.shortlist(meaning:meaning,words:words,fallback:[],limit:0).isEmpty)
    }
    func testScoredCandidatesArePromotedWithoutLosingOrDuplicatingRemainingSources() {
        let candidates = [hit("semantic"),hit("identifier")]
        let result = SemanticRanking.applying([0.2,0.9],candidates:candidates,fallback:[hit("ordinary"),hit("semantic"),hit("tail")])
        XCTAssertEqual(result.map { $0.passage.id },["identifier","semantic","ordinary","tail"])
        XCTAssertEqual(result[0].score,0.9)
        XCTAssertEqual(SemanticRanking.applying([],candidates:candidates,fallback:[hit("unchanged")]).first?.passage.id,"unchanged")
    }
}
