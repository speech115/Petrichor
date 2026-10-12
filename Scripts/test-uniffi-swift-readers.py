#!/usr/bin/env python3
"""Exercise the actual generated private readers and zero-copy artwork, including owned Data lifetime."""
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
// Zero-copy artwork: Data must keep the Rust allocation alive after every Rust-side owner is gone.
let path = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString).sqlite").path
defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
var artwork: [Int64: Data] = [:]
weak var released: ArtworkBytes?
do {
    let database = try LibraryDatabase.open(path: path)
    var connection: OpaquePointer?
    precondition(sqlite3_open(path, &connection) == SQLITE_OK)
    let stamp = "'2026-01-01 00:00:00.000'"
    let insert = "INSERT INTO albums(id,title,normalized_title,sort_title,artwork_data,total_tracks,created_at,updated_at) VALUES" +
        [(1, "X'00FF80'"), (2, "X''"), (3, "zeroblob(2097152)"), (4, "NULL")]
        .map { "(\($0.0),'A\($0.0)','a\($0.0)','A\($0.0)',\($0.1),1,\(stamp),\(stamp))" }.joined(separator: ",")
    precondition(sqlite3_exec(connection, insert, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(connection)
    let rows = try database.albumArtworks(ids: [1, 2, 3, 4], thumbnail: false)
    // Foundation copies tiny Data inline and frees at once, so watch the 2 MiB cover.
    released = rows.first { $0.id == 3 }?.bytes
    for row in rows { precondition(row.album); artwork[row.id] = row.bytes.data }
}
let churn = (0..<12).map { _ in Data(repeating: 77, count: 2 * 1024 * 1024) }
precondition(released != nil && churn.count == 12)
precondition(artwork[1] == Data([0, 255, 128]) && artwork[2] == Data() && artwork[4] == nil)
precondition(artwork[3]?.count == 2097152 && artwork[3]?.allSatisfy { $0 == 0 } == true)
var copy = artwork[1]!
copy[0] = 9
precondition(artwork[1] == Data([0, 255, 128]) && copy == Data([9, 255, 128]))
artwork.removeAll()
precondition(released == nil, "Releasing the Data must free the Rust artwork")
print("Swift UniFFI reader boundary and owned-lifetime checks passed")
'''
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='petrichor-readers-') as temporary:
    source = Path(temporary) / 'main.swift'
    artwork = (root/'Core/LibraryStorage/ArtworkBytesData.swift').read_text().replace('import PetrichorCore\n', '')
    source.write_text((root/'rust/build/swift/petrichor_core.swift').read_text() + artwork + 'import SQLite3\n' + TESTS)
    executable = Path(temporary) / 'readers'
    command = ['swiftc', '-O', '-I', str(root/'rust/build/headers'), str(source), str(root/'rust/build/PetrichorCoreFFI.xcframework/macos-arm64_x86_64/libpetrichor_core.a'), '-lsqlite3', '-o', str(executable)]
    if args.sanitize:
        command += ['-sanitize=address']
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
