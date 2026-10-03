import Foundation
import LavaSecKit

/// Shares production hostname validation without exposing filter mutation authority.
@objc(LavaReviewDomainValidator)
final class ReviewDomainValidator: NSObject {
    @objc static func normalize(_ input: String) -> String? {
        try? DomainName.normalize(input)
    }
}
