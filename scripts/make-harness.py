#!/usr/bin/env python3
"""Adapt the current XCTest source for command line tools without XCTest."""

from pathlib import Path
import re
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: make-harness.py TEST_SOURCE OUTPUT_SWIFT")
    source = Path(sys.argv[1]).read_text()
    suites = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
    if len(suites) != 1:
        raise SystemExit("Expected exactly one XCTestCase suite")
    suite = suites[0]
    tests = re.findall(r"^\s*func\s+(test\w+)\s*\(\s*\)\s*throws\s*\{", source, re.MULTILINE)
    declared = re.findall(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE)
    if not tests or len(tests) != len(set(tests)) or tests != declared:
        raise SystemExit("Expected unique synchronous test methods with the signature func testName() throws")
    source = re.sub(r"^\s*(?:import XCTest|@testable import RelayCore)\s*$", "", source, flags=re.MULTILINE)
    support = Path(__file__).resolve().parent.parent / "Tests/Support/Assertions.swift"
    entries = ",\n".join(f'            ("{name}", {suite}.{name})' for name in tests)
    runner = f'''
@main
struct RelayFixtureRunner {{
    static func main() {{
        let tests: [(String, ({suite}) -> () throws -> Void)] = [
{entries}
        ]
        var skipped = 0
        for (name, method) in tests {{
            let fixture = {suite}()
            let failuresBefore = assertionFailureCount
            var didSkip = false
            do {{
                try fixture.setUpWithError()
                try method(fixture)()
            }} catch let skip as XCTSkip {{
                didSkip = true
                skipped += 1
                print("SKIP \\(name): \\(skip.reason)")
            }} catch {{
                recordAssertionFailure("\\(name): \\(error)")
            }}
            do {{ try fixture.tearDownWithError() }}
            catch {{ recordAssertionFailure("\\(name) teardown: \\(error)") }}
            if assertionFailureCount == failuresBefore && !didSkip {{ print("PASS \\(name)") }}
        }}
        print("\\(tests.count - skipped) executed fixtures; \\(skipped) skipped; \\(assertionFailureCount) failures")
        exit(assertionFailureCount == 0 ? 0 : 1)
    }}
}}
'''
    Path(sys.argv[2]).write_text(support.read_text() + "\n" + source + "\n" + runner)


if __name__ == "__main__":
    main()
