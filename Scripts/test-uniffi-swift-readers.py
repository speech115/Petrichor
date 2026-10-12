#!/usr/bin/env python3
"""Exercise the actual generated private readers, including owned Data lifetime."""
import argparse
import subprocess
import tempfile
from pathlib import Path

TESTS = r'''
func encoded(_ bytes: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    writeInt(&output, Int32(bytes.count))
    output.append(contentsOf: bytes)
    return output
}
func expectFailure(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected a decoding error") } catch {}
}
var integerReader = createReader(data: Data([99, 1, 2, 3, 4, 5, 6, 7, 8]))
integerReader.offset = 1
let integer: UInt64 = try readInt(&integerReader)
precondition(integer == 0x0102030405060708 && integerReader.offset == 9)
expectFailure { let _: UInt8 = try readInt(&integerReader) }
for bytes in [[], [0, 128, 255, 195, 169], Array(repeating: UInt8(42), count: 2 * 1024 * 1024)] {
    let buffer = RustBuffer(bytes: encoded(bytes))
    let owned = try FfiConverterData.lift(buffer)
    // lift has already freed its source RustBuffer. Force allocation/reuse.
    let churn = (0..<12).map { _ in Data(repeating: 77, count: max(bytes.count, 1)) }
    precondition(owned == Data(bytes) && churn.count == 12)
    var stringReader = createReader(data: Data(encoded(bytes)))
    let decoded = try FfiConverterString.read(from: &stringReader)
    precondition(decoded == String(decoding: bytes, as: UTF8.self))
}
for bytes in ([[], [0, 0, 0], [255, 255, 255, 255], [0, 0, 0, 2, 1], [0, 0, 0, 0, 1]] as [[UInt8]]) {
    expectFailure { _ = try FfiConverterData.lift(RustBuffer(bytes: bytes)) }
}
for bytes in ([[255, 255, 255, 255], [0, 0, 0, 2, 1]] as [[UInt8]]) {
    var reader = createReader(data: Data(bytes))
    expectFailure { _ = try FfiConverterString.read(from: &reader) }
}
print("Swift UniFFI reader boundary and owned-lifetime checks passed")
'''
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='petrichor-readers-') as temporary:
    source = Path(temporary) / 'main.swift'
    source.write_text((root/'rust/build/swift/petrichor_core.swift').read_text() + TESTS)
    executable = Path(temporary) / 'readers'
    command = ['swiftc', '-O', '-I', str(root/'rust/build/headers'), str(source), str(root/'rust/build/PetrichorCoreFFI.xcframework/macos-arm64_x86_64/libpetrichor_core.a'), '-lsqlite3', '-o', str(executable)]
    if args.sanitize:
        command += ['-sanitize=address']
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
