import Foundation

extension Bundle {
    /// Snapok's resource bundle. The packaged app keeps it in Contents/Resources, where `Bundle.module` doesn't look.
    static let snapokResources: Bundle = Bundle.main.url(forResource: "Snapok_Snapok", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? .module
}
