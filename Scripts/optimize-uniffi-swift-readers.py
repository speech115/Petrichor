#!/usr/bin/env python3
"""Optimize pinned UniFFI 0.32 Swift readers without changing the wire format.

Fail closed when generator templates change. Returned strings and Data own their
storage; the borrowed RustBuffer is freed by lift even on a decoding error.
"""
import argparse
from pathlib import Path

INT_OLD = 'var value: T = 0\n    let _ = withUnsafeMutableBytes(of: &value, { reader.data.copyBytes(to: $0, from: range)})'
INT_NEW = 'let value: T = reader.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: range.lowerBound, as: T.self) }'
STRING_OLD = 'return String(decoding: try readBytes(&buf, count: Int(len)), as: UTF8.self)'
STRING_NEW = '''guard len >= 0, Int(len) <= buf.data.count - buf.offset else {
            throw UniffiInternalError.bufferOverflow
        }
        let range = buf.offset..<(buf.offset + Int(len))
        let value = buf.data.withUnsafeBytes { raw in
            String(decoding: raw.bindMemory(to: UInt8.self)[range], as: UTF8.self)
        }
        buf.offset = range.upperBound
        return value'''
DATA_OLD = 'return Data(try readBytes(&buf, count: Int(len)))'
DATA_NEW = '''guard len >= 0, Int(len) <= buf.data.count - buf.offset else {
            throw UniffiInternalError.bufferOverflow
        }
        let range = buf.offset..<(buf.offset + Int(len))
        let value = buf.data.subdata(in: range)
        buf.offset = range.upperBound
        return value'''
LIFT_OLD = '''var reader = createReader(data: Data(rustBuffer: buf))
        let value = try read(from: &reader)
        if hasRemaining(reader) {
            throw UniffiInternalError.incompleteData
        }
        buf.deallocate()
        return value'''
LIFT_NEW = '''defer { buf.deallocate() }
        var reader = createReader(data: Data(rustBuffer: buf))
        let value = try read(from: &reader)
        if hasRemaining(reader) {
            throw UniffiInternalError.incompleteData
        }
        return value'''

def optimize(source):
    for before, after in [(INT_OLD, INT_NEW), (STRING_OLD, STRING_NEW), (DATA_OLD, DATA_NEW), (LIFT_OLD, LIFT_NEW)]:
        if source.count(before) != 1:
            raise RuntimeError('UniFFI Swift reader template changed; review the optimizer before building')
        source = source.replace(before, after)
    return source

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bindings', type=Path)
    args = parser.parse_args()
    args.bindings.write_text(optimize(args.bindings.read_text()))
