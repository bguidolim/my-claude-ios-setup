import Testing

@testable import mcs

@Test func mcsPackageBuilds() {
    // Verifies the package compiles and the test target can link against mcs
    #expect(Bool(true))
}

@Test("MCSVersion.current is valid semantic version")
func mcsVersionIsValidSemver() {
    let version = MCSVersion.current
    let parts = version.split(separator: ".")
    #expect(parts.count == 3, "Expected 3 dot-separated components, got \(parts.count)")
    for part in parts {
        #expect(Int(part) != nil, "'\(part)' is not a valid integer component")
    }
}
