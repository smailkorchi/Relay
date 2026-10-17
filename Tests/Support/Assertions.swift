// A small assertion adapter for the standalone runner; the tests remain XCTest-compatible.
import Foundation

private var assertionFailureCount = 0

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

struct XCTSkip: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

private func recordAssertionFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    assertionFailureCount += 1
    print("FAIL \(file):\(line): \(message)")
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { recordAssertionFailure("Expected true", file: file, line: line) } }
    catch { recordAssertionFailure("\(error)", file: file, line: line) }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                    file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { recordAssertionFailure("Expected false", file: file, line: line) } }
    catch { recordAssertionFailure("\(error)", file: file, line: line) }
}

func XCTAssertEqual<T: Equatable>(_ first: @autoclosure () throws -> T,
                                  _ second: @autoclosure () throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let left = try first(), right = try second()
        if left != right { recordAssertionFailure("Expected equal: \(left) vs \(right)", file: file, line: line) }
    } catch { recordAssertionFailure("\(error)", file: file, line: line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ first: T, _ second: T,
                                        file: StaticString = #filePath, line: UInt = #line) {
    if first <= second { recordAssertionFailure("Expected \(first) greater than \(second)", file: file, line: line) }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ inspect: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        recordAssertionFailure("Expected an error", file: file, line: line)
    } catch { inspect(error) }
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        recordAssertionFailure("Expected non-nil", file: file, line: line)
        throw NSError(domain: "RelayFixture", code: 1)
    }
    return value
}

func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { recordAssertionFailure("Expected non-nil", file: file, line: line) }
}

func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    recordAssertionFailure(message, file: file, line: line)
}
